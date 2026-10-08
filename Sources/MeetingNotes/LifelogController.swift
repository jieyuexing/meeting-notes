import AVFoundation
import AppKit
import Foundation
import Observation

/// Fork: always-on ("lifelog") mode. Records the microphone continuously in
/// segments, transcribes each closed segment with the shared final
/// transcription entry, and writes one digest per day.
///
/// It never touches `MeetingStore`: no meeting pointer, recovery prompt,
/// Today list entry, live preview, per-segment summary, translation, calendar
/// title, Codex thread, sync or hook. A meeting recording always wins: the
/// current segment is closed when a meeting capture starts, and a new one
/// begins after the meeting ends.
@MainActor
@Observable
final class LifelogController {
  typealias Transcribe = @Sendable (_ microphone: URL, _ system: URL) async throws -> [TranscriptTurn]

  enum Phase: Equatable {
    case off
    case recording
    case yieldingToMeeting
    case sleeping
    case displayPaused
    /// Capture could not start or its file writer failed.
    case retrying(String)
    /// A setting prevents recording until the user changes it.
    case blocked(String)
  }

  struct DayStats: Equatable {
    var completeSegments = 0
    var emptySegments = 0
    var failedSegments = 0
    var pendingSegments = 0
    var silentSegmentsDiscarded = 0
    var characters = 0
    var screenTextComplete = 0
    var screenTextPending = 0
    var screenTextFailed = 0
  }

  static let retryInterval: TimeInterval = 30
  static let interruptionRestartDelay: TimeInterval = 2
  static let screenLimitMessage = "Screen storage limit reached. Increase the limit or move recordings manually."
  /// A capacity pause resumes once screen storage is below this share of the limit.
  static let screenResumeFraction = 0.9

  private(set) var phase: Phase = .off
  private(set) var settings: LifelogSettings
  private(set) var todayStats = DayStats()
  private(set) var segmentStartedAt: Date?
  private(set) var lastError: String?
  private(set) var digestStatusText = ""
  private(set) var digestRunning = false
  /// Incremented whenever a segment's screen text changes, for Today rows.
  private(set) var screenTextRevision = 0
  /// Older segments with videos but no screen-text state; converted on request only.
  private(set) var legacyScreenSegments = 0

  private let defaults: UserDefaults
  private let unified: (any UnifiedSegmentCapturing)?
  private var displayCheckTask: Task<Void, Never>?
  private var capturedDisplayIDs: [UInt32] = []
  private var t3Epoch = 0
  private let displayGate: DisplayCaptureGate
  private var closingTask: Task<Void, Never>?
  private var mediaStartTask: Task<Void, Error>?
  private var starting = false
  private var captureEpoch = 0
  private(set) var screenBytes: Int64 = 0
  private(set) var t3Snapshot = T3ActivityCollector.Snapshot(enabledAt: Date())
  private(set) var t3State: T3ActivityCollector.State = .stopped
  private var t3Collector: T3ActivityCollector?
  private var t3ConfigurationKey = ""
  private var t3ShutdownTask: Task<Void, Never>?
  private var t3UpdateTask: Task<Void, Never>?
  private var distributedObservers: [NSObjectProtocol] = []
  private var usesUnified: Bool { settings.unifiedMedia && unified != nil }
  private let capture: LifelogCapture
  private let transcribe: Transcribe
  private let extractScreenText: LifelogScreenTextJob.Extract
  private let requestAccess: @Sendable () async -> Bool
  private let transcriptionBlocker: () -> String?
  private let digestRequest: (LifelogSettings) -> LifelogDigest.Request?
  private let reservedRoots: () -> [URL]
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let notesLanguage: () -> MeetingNotesLanguage
  private let activity = RecordingActivityMonitor()
  private let wakeLock = RecordingWakeLock()
  private var current: (segment: LifelogSegment, folder: URL)?
  private var meetingActive = false
  private var asleep = false
  private var shuttingDown = false
  private var nextRetryAt: Date?
  private var startTask: Task<Void, Never>?
  private var queue: [URL] = []
  private var queueTask: Task<Void, Never>?
  /// Screen text runs in its own serial queue: it is always local, needs no
  /// transcription lock and must not wait behind ASR (or block it).
  private var screenQueue: [URL] = []
  private var screenTask: Task<Void, Never>?
  private var loopTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  init(
    defaults: UserDefaults = .standard,
    capture: LifelogCapture = LifelogRecorder(),
    unified: (any UnifiedSegmentCapturing)? = nil,
    displayGate: DisplayCaptureGate = DisplayCaptureGate(),
    transcribe: @escaping Transcribe,
    requestAccess: @escaping @Sendable () async -> Bool = {
      await AVCaptureDevice.requestAccess(for: .audio)
    },
    transcriptionBlocker: @escaping () -> String? = {
      // Always-on audio must stay on this Mac.
      TranscriptionEngineSettingsStore.load() == .openAI
        ? "Always-on recording needs an on-device transcription engine; OpenAI is selected."
        : nil
    },
    digestRequest: @escaping (LifelogSettings) -> LifelogDigest.Request? = {
      $0.digestBackendSettings.map(LifelogDigest.request(for:))
    },
    reservedRoots: @escaping () -> [URL],
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .autoupdatingCurrent,
    notesLanguage: @escaping () -> MeetingNotesLanguage = { MeetingNotesLanguageStore.load() },
    extractScreenText: @escaping LifelogScreenTextJob.Extract = LifelogScreenTextJob.defaultExtract
  ) {
    self.defaults = defaults
    self.capture = capture
    self.unified = unified
    self.displayGate = displayGate
    self.transcribe = transcribe
    self.requestAccess = requestAccess
    self.transcriptionBlocker = transcriptionBlocker
    self.digestRequest = digestRequest
    self.reservedRoots = reservedRoots
    self.now = now
    self.calendar = calendar
    self.notesLanguage = notesLanguage
    self.extractScreenText = extractScreenText
    settings = LifelogSettingsStore.load(from: defaults)
    if unified != nil, let cached = T3ActivityCollector.cachedSnapshot(root: settings.rootURL, includeText: settings.t3IncludeText) {
      t3Snapshot = cached
    }
    let activity = activity
    capture.onSamples = { samples in activity.observe(samples, at: now()) }
    unified?.onSamples = { samples in activity.observe(samples, at: now()) }
    unified?.onFailure = { [weak self] root, error in
      Task { @MainActor in
        guard let self, let current = self.current,
          current.segment.screenRelativeFolder.map({ self.store.root.appending(path: $0) }) == root else { return }
        self.lastError = error
        self.endSegment(reason: .stopped, restart: false, mediaFailure: error)
        self.phase = .retrying(error)
        self.nextRetryAt = now() + Self.retryInterval
      }
    }
    capture.onWriteFailure = { [weak self] url, error in
      Task { @MainActor in self?.handleWriteFailure(at: url, error: error) }
    }
    capture.onInterruption = { [weak self] in
      Task { @MainActor in self?.handleInterruption() }
    }
  }

  var store: LifelogStore { LifelogStore(root: settings.rootURL, calendar: calendar) }

  var statusText: String {
    statusText(language: .system)
  }

  func statusText(language: UILanguage) -> String {
    func ui(_ key: String) -> String { UIStrings.string(key, language: language) }
    return switch phase {
    case .off: ui("Off")
    case .recording: ui("Recording · Mac stays awake")
    case .yieldingToMeeting: ui("Paused while a meeting is recorded")
    case .sleeping: ui("Paused while the Mac sleeps")
    case .displayPaused: ui("Paused · unlock and wake a display to record")
    case .retrying(let reason): String(format: ui("Waiting to retry capture: %@"), UIStrings.resolve(reason, language: language))
    case .blocked(let reason): UIStrings.resolve(reason, language: language)
    }
  }

  /// Recovers segments left by an earlier run and starts capture when enabled.
  func activate(observeSystem: Bool = true) {
    if validateRoot() {
      for folder in store.pendingFolders() where !queue.contains(folder) { enqueue(folder) }
      recoverScreenText()
    }
    if observeSystem {
      let notifications = NSWorkspace.shared.notificationCenter
      observers.append(
        notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main)
        { [weak self] _ in
          MainActor.assumeIsolated { self?.systemWillSleep() }
        })
      observers.append(
        notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main)
        { [weak self] _ in
          Task { @MainActor in await self?.systemDidWake() }
        })
      observers.append(NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } })
      for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
        observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.pauseDisplays(session: name == NSWorkspace.sessionDidResignActiveNotification) }
        })
      }
      for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in await self?.resumeDisplays(session: name == NSWorkspace.sessionDidBecomeActiveNotification) }
        })
      }
      // macOS has no public lock-specific notification. Keep these defensive
      // signals separate from the documented session/screen sleep API.
      let distributed = DistributedNotificationCenter.default()
      for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
        distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in
            if locked { self?.pauseDisplays(session: true) }
            else { await self?.resumeDisplays(session: true) }
          }
        })
      }
      startLoop()
    }
    refreshStats()
    if settings.enabled {
      if settings.enabledAt == nil { settings.enabledAt = now(); LifelogSettingsStore.save(settings, to: defaults) }
      startInBackground()
    }
    Task { await updateT3() }
  }

  func setEnabled(_ enabled: Bool) async {
    if enabled, !settings.enabled || settings.enabledAt == nil { settings.enabledAt = now() }
    settings.enabled = enabled
    LifelogSettingsStore.save(settings, to: defaults)
    await updateT3()
    if enabled {
      await startCapturing()
    } else {
      nextRetryAt = nil
      endSegment(reason: .stopped, restart: false)
      phase = .off
    }
  }

  func updateSettings(_ updated: LifelogSettings) async {
    if let error = LifelogSettings.rootError(updated.rootPath, reserved: reservedRoots()) {
      lastError = error
      return
    }
    let previous = settings
    let changingRoot = previous.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
      != updated.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    if changingRoot {
      do {
        // Include current/start and the in-flight queue task, not just the queued URLs.
        guard !settings.enabled, !starting, closingTask == nil, current == nil, startTask == nil, queueTask == nil, queue.isEmpty,
          screenTask == nil, screenQueue.isEmpty, try !store.hasUnfinishedSegments() else {
          lastError = "Stop recording and drain pending/failed segments before changing the archive root."
          return
        }
      } catch {
        lastError = "Cannot verify the old archive; drain it before changing roots: \(error.localizedDescription)"
        return
      }
    }
    if changingRoot { lastError = nil }
    if previous.unifiedMedia != updated.unifiedMedia || previous.allDisplays != updated.allDisplays {
      endSegment(reason: .stopped, restart: false)
      await waitForCaptureClose()
    }
    var updated = updated
    updated.enabledAt = settings.enabledAt
    settings = updated
    LifelogSettingsStore.save(updated, to: defaults)
    if changingRoot {
      for folder in store.pendingFolders() where !queue.contains(folder) { enqueue(folder) }
      recoverScreenText()
    }
    await setEnabled(updated.enabled)
  }

  /// Stop admission immediately. The app delegate awaits media and T3 cleanup;
  /// pending transcripts are recovered on next launch without waiting for ASR.
  func shutdown() {
    shuttingDown = true
    t3UpdateTask?.cancel()
    if t3ShutdownTask == nil { t3ShutdownTask = Task { await t3Collector?.stop() } }
    displayCheckTask?.cancel()
    loopTask?.cancel()
    startTask?.cancel()
    nextRetryAt = nil
    endSegment(reason: .stopped, restart: false)
    queueTask?.cancel()
    // Never awaited on quit: interrupted screen text stays pending and
    // restarts from the beginning on the next launch.
    screenTask?.cancel()
    phase = .off
  }

  @discardableResult
  private func validateRoot() -> Bool {
    guard let error = LifelogSettings.rootError(settings.rootPath, reserved: reservedRoots()) else {
      return true
    }
    lastError = error
    phase = .blocked(error)
    return false
  }

  func meetingCaptureWillStart() {
    meetingActive = true
    nextRetryAt = nil
    endSegment(reason: .meeting, restart: false)
    if settings.enabled { phase = .yieldingToMeeting }
  }

  func meetingCaptureDidEnd() async {
    guard meetingActive else { return }
    meetingActive = false
    if settings.enabled { await startCapturing() }
  }

  /// A pause spanning sleep would stitch two different times into one WAV,
  /// so sleep closes the segment and wake starts a fresh one.
  func systemWillSleep() {
    asleep = true
    displayGate.systemWillSleep()
    endSegment(reason: .sleep, restart: false)
    if settings.enabled, !meetingActive { phase = .sleeping }
  }

  func systemDidWake() async {
    asleep = false
    displayGate.systemDidWake()
    guard settings.enabled, !meetingActive else { return }
    await startCapturing()
  }

  /// Once per second: closes the segment when the policy says so, and
  /// retries a microphone that could not be opened.
  func tick() {
    guard !shuttingDown else { return }
    if let error = LifelogSettings.rootError(settings.rootPath, reserved: reservedRoots()) {
      endSegment(reason: .stopped, restart: false)
      phase = .blocked(error)
      return
    }
    let time = now()
    if usesUnified, current != nil {
      if displayCheckTask == nil {
        let epoch = captureEpoch
        displayCheckTask = Task { [weak self] in
          guard let self else { return }
          defer { self.displayCheckTask = nil }
          let state = await self.displayGate.recheck()
          guard epoch == self.captureEpoch, self.current != nil, !Task.isCancelled else { return }
          if state != .ready {
            self.endSegment(reason: .sleep, restart: false)
            self.phase = .displayPaused
          } else if self.settings.allDisplays && self.capturedDisplayIDs != self.displayGate.awakeDisplayIDs {
            self.endSegment(reason: .deviceChange, restart: true)
          }
        }
      }
      do {
        screenBytes = try screenStorageBytes()
        if screenBytes >= Int64(settings.screenCapacityGB) * 1_000_000_000 {
          endSegment(reason: .stopped, restart: false)
          phase = .blocked(Self.screenLimitMessage)
          return
        }
      } catch {
        endSegment(reason: .stopped, restart: false)
        phase = .blocked("Cannot inspect screen storage: " + error.localizedDescription)
        return
      }
    }
    switch phase {
    case .recording:
      guard let current else { return }
      let policy = LifelogSegmentPolicy(
        silenceThreshold: settings.silenceThreshold,
        maximumDuration: settings.maximumSegmentDuration)
      switch policy.decide(
        segmentStartedAt: current.segment.startedAt, now: time,
        hadSound: hadSound(since: current.segment.startedAt, at: time),
        quietForThreshold: activity.isQuiet(for: settings.silenceThreshold, at: time),
        calendar: calendar)
      {
      case .keep: break
      case .cut(let reason): endSegment(reason: reason, restart: true)
      case .discardSilence: endSegment(reason: .silence, restart: true)
      }
    case .displayPaused:
      if startTask == nil { startInBackground() }
    case .retrying:
      guard let nextRetryAt, time >= nextRetryAt, startTask == nil else { return }
      self.nextRetryAt = nil
      startInBackground()
    case .blocked(let reason) where reason == Self.screenLimitMessage:
      // Screen text deletes videos, so a capacity pause can end by itself.
      guard settings.enabled, usesUnified, startTask == nil, let bytes = try? screenStorageBytes() else { return }
      screenBytes = bytes
      if Double(bytes) < Double(settings.screenCapacityGB) * 1_000_000_000 * Self.screenResumeFraction {
        startInBackground()
      }
    default:
      break
    }
  }

  func runDueDigests() async {
    guard !shuttingDown, validateRoot(), !digestRunning, digestRequest(settings) != nil else { return }
    let store = self.store
    let currentFolder = current?.folder
    let due = LifelogDigestSchedule.dueDays(
      now: now(), minuteOfDay: settings.digestMinuteOfDay, calendar: calendar,
      run: { store.digestRun(day: $0, label: nil) },
      transcribedCount: { day in store.segments(on: day).filter { LifelogDigest.isDigestible($0.segment) }.count },
      pendingCount: { day in
        store.segments(on: day).filter { LifelogDigest.isWaiting($0.segment) || $0.folder == currentFolder }.count
      })
    for day in due { await generateDigest(day: day) }
  }

  /// Also used by the "Generate now" button. A failure is reported but never
  /// affects the transcripts.
  func generateDigest(day: String) async {
    guard !shuttingDown, validateRoot(), !digestRunning else { return }
    guard let request = digestRequest(settings) else {
      digestStatusText = "No digest: set a digest command first."
      return
    }
    digestRunning = true
    defer { digestRunning = false }
    digestStatusText = "Generating the digest for \(day)…"
    do {
      let run = try await LifelogDigest.generate(
        store: store, day: day, label: nil, chunkCharacters: settings.digestChunkCharacters,
        language: notesLanguage(), request: request, backendDescription: backendDescription,
        now: now)
      switch run.status {
      case .complete:
        digestStatusText = "Digest for \(day) saved (\(Int(run.durationSeconds.rounded())) s)."
      case .skipped:
        digestStatusText = "No transcripts for \(day) yet."
      case .failed:
        digestStatusText = "Digest for \(day) failed: \(run.error ?? "unknown error")"
      }
    } catch {
      digestStatusText = "Digest for \(day) failed: \(error.localizedDescription)"
    }
  }

  func retryFailedSegments() {
    guard validateRoot(), !shuttingDown else { return }
    for day in store.days() {
      for item in store.segments(on: day) where item.segment.status == .failed {
        guard !queue.contains(item.folder) else { continue }
        var segment = item.segment
        segment.status = .pending
        do {
          try store.saveKeepingScreen(segment, in: item.folder)
          enqueue(item.folder)
        } catch { lastError = error.localizedDescription }
      }
      // A manual retry is not limited by the launch-recovery attempt count.
      for item in store.segments(on: day) where item.segment.screenText?.status == .failed {
        guard !screenQueue.contains(item.folder) else { continue }
        do {
          try store.update(in: item.folder) { $0.screenText?.status = .pending }
          enqueueScreen(item.folder)
        } catch { lastError = error.localizedDescription }
      }
    }
  }

  /// Explicit conversion of segments recorded before screen text existed.
  /// Launch recovery never touches them, so deploying cannot silently delete
  /// earlier videos.
  func convertLegacyScreenVideos() {
    guard validateRoot(), !shuttingDown else { return }
    for folder in store.legacyScreenFolders(excluding: current?.folder) {
      do {
        try store.update(in: folder) { $0.screenText = .pending }
        enqueueScreen(folder)
      } catch { lastError = error.localizedDescription }
    }
    legacyScreenSegments = store.legacyScreenFolders(excluding: current?.folder).count
  }

  func waitForTranscriptions() async {
    await waitForCaptureClose()
    while let queueTask { await queueTask.value }
  }

  func waitForScreenText() async {
    while let screenTask { await screenTask.value }
  }

  func waitForStart() async {
    while let startTask { await startTask.value }
  }

  // MARK: - Capture

  private enum StartCheck {
    /// Nothing to start: off, in a meeting, asleep or already recording.
    case skip
    case go
    case blocked(String)
  }

  private func startInBackground() {
    guard startTask == nil else { return }
    startTask = Task { [weak self] in
      await self?.startCapturing()
      self?.startTask = nil
    }
  }

  private func startCapturing() async {
    guard !starting else { return }
    starting = true
    defer { starting = false }
    await waitForCaptureClose()
    captureEpoch += 1
    let epoch = captureEpoch
    switch await startCheck() {
    case .skip: return
    case .blocked(let reason): phase = .blocked(reason); return
    case .go: break
    }
    guard epoch == captureEpoch else { return }
    do {
      let started = now()
      var created = try store.createSegment(id: UUID(), startedAt: started)
      let clock = CaptureClock()
      clock.start()
      if usesUnified {
        created.segment.screenRelativeFolder = "screen/\(store.dayKey(started))/\(created.segment.id.uuidString.lowercased())"
        // Set at creation so even a crashed segment is recognised on recovery.
        created.segment.screenText = .pending
        try store.save(created.segment, in: created.folder)
      }
      current = created
      capture.align(to: clock)
      try capture.start(writingTo: store.audioURL(in: created.folder),
        preferredDeviceUID: MicrophoneSettingsStore.preferredDeviceUID(from: defaults))
      if let relative = created.segment.screenRelativeFolder, let unified {
        let segment = UnifiedCaptureSegment(root: store.root.appending(path: relative), startedAt: started,
          displayPolicy: settings.allDisplays ? .allDisplays : .mainDisplay,
          systemAudioURL: store.systemAudioURL(in: created.folder))
        let task = Task {
          guard epoch == self.captureEpoch else { throw CancellationError() }
          try await unified.start(segment: segment, clock: clock)
        }
        mediaStartTask = task
        do { try await task.value } catch {
          mediaStartTask = nil
          if epoch == captureEpoch { throw error }
          return
        }
        mediaStartTask = nil
      }
      guard epoch == captureEpoch, current?.folder == created.folder else { return }
      segmentStartedAt = started
      nextRetryAt = nil
      phase = .recording
      wakeLock.acquire()
    } catch {
      // Preserve partially opened files; a permission or encoder failure is
      // never represented as silence and never queues unfinished writers.
      endSegment(reason: .stopped, restart: false, mediaFailure: error.localizedDescription)
      phase = .retrying(error.localizedDescription)
      nextRetryAt = now() + Self.retryInterval
    }
    refreshStats()
  }

  private func startCheck() async -> StartCheck {
    guard settingsAllowCapture() else { return .skip }
    if let error = LifelogSettings.rootError(settings.rootPath, reserved: reservedRoots()) {
      return .blocked(error)
    }
    if let blocker = transcriptionBlocker() { return .blocked(blocker) }
    if usesUnified {
      guard await displayGate.recheck() == .ready else { phase = .displayPaused; return .skip }
      capturedDisplayIDs = displayGate.awakeDisplayIDs
      do {
        screenBytes = try screenStorageBytes()
        if screenBytes >= Int64(settings.screenCapacityGB) * 1_000_000_000 {
          return .blocked(Self.screenLimitMessage)
        }
      } catch { return .blocked("Cannot inspect screen storage: " + error.localizedDescription) }
    }
    guard await requestAccess() else { return .blocked("Microphone access was denied.") }
    // Settings, a meeting or sleep may have changed while access was pending.
    return settingsAllowCapture() ? .go : .skip
  }

  private func settingsAllowCapture() -> Bool {
    if shuttingDown || !settings.enabled {
      phase = .off
      return false
    }
    if meetingActive {
      phase = .yieldingToMeeting
      return false
    }
    if asleep {
      phase = .sleeping
      return false
    }
    if current != nil {
      phase = .recording
      return false
    }
    return true
  }

  /// Closes the current segment. `restart` rotates into a new file without
  /// stopping the engine, so rotation does not intentionally restart capture. OS scheduling and device gaps are unbounded.
  private func endSegment(reason: LifelogCutReason, restart: Bool, mediaFailure: String? = nil) {
    captureEpoch += 1
    unified?.suspendImmediately()
    guard let closing = current else { return }
    if closing.segment.screenRelativeFolder != nil {
      closeUnified(closing, reason: reason, restart: restart, failure: mediaFailure)
      return
    }
    let store = LifelogStore(root: closing.folder.deletingLastPathComponent().deletingLastPathComponent(), calendar: calendar)
    let ended = now()
    var next: (segment: LifelogSegment, folder: URL)?
    var result: LifelogCaptureResult?
    var captureFailure: String?
    do {
      if restart {
        let created = try store.createSegment(id: UUID(), startedAt: ended)
        do { result = try capture.rotate(to: store.audioURL(in: created.folder)) } catch {
          try? FileManager.default.removeItem(at: created.folder)
          throw error
        }
        next = created
      } else {
        result = try capture.stop()
      }
    } catch {
      captureFailure = error.localizedDescription
      result = try? capture.stop()
      phase = .retrying(error.localizedDescription)
      nextRetryAt = ended + Self.retryInterval
    }
    current = next
    segmentStartedAt = next?.segment.startedAt
    if next == nil { wakeLock.release() }
    let failure = result?.writeError ?? captureFailure ?? (result == nil ? "Capture returned no closed audio file." : nil)
    if let failure { lastError = "Audio write failed: " + failure }

    var segment = closing.segment
    segment.endedAt = ended
    segment.closeReason = reason
    segment.audioSeconds = result?.seconds ?? ended.timeIntervalSince(segment.startedAt)
    do {
      if let error = failure {
        segment.status = .failed
        segment.error = "Audio capture/write error: " + error
        try store.save(segment, in: closing.folder)
      } else if try WavFile.checkedMeaningfulSignal(at: store.audioURL(in: closing.folder)) {
        segment.status = .pending
        try store.save(segment, in: closing.folder)
        enqueue(closing.folder)
      } else {
        try store.discardSilentSegment(segment, in: closing.folder, seconds: segment.audioSeconds ?? 0)
      }
    } catch {
      lastError = "Segment could not be saved: \(error.localizedDescription)"
      try? store.markFailed(segment, in: closing.folder, error: error, startedAt: ended)
    }
    refreshStats()
  }

  func waitForT3Stop() async { await t3ShutdownTask?.value }

  func waitForCaptureClose() async {
    while let closingTask { await closingTask.value }
  }

  private func closeUnified(_ closing: (segment: LifelogSegment, folder: URL),
    reason: LifelogCutReason, restart: Bool, failure: String?) {
    current = nil
    segmentStartedAt = nil
    wakeLock.release()
    let ended = now()
    var audioResult: LifelogCaptureResult?
    var closeError = failure
    do { audioResult = try capture.stop() } catch { closeError = closeError ?? error.localizedDescription }
    let start = mediaStartTask
    let rootStore = store
    // Admission and mic close have already happened synchronously above.
    // No replacement generation can start until this task has drained.
    closingTask = Task {
      do { try await start?.value } catch { closeError = closeError ?? "Capture interrupted during start: " + error.localizedDescription }
      var segment = closing.segment
      segment.endedAt = ended
      segment.closeReason = reason
      segment.audioSeconds = audioResult?.seconds ?? ended.timeIntervalSince(segment.startedAt)
      do {
        segment.media = try await unified?.stop()
        let error = closeError ?? audioResult?.writeError ?? segment.media?.failure
        if let error {
          segment.status = .failed; segment.error = error
          lastError = error
          try rootStore.saveKeepingScreen(segment, in: closing.folder)
        } else {
          // Keep even a silent desktop segment: screen artifacts have their
          // own root and never enter discardSilentSegment.
          segment.status = .pending
          try rootStore.saveKeepingScreen(segment, in: closing.folder)
          if !shuttingDown { enqueue(closing.folder) }
        }
      } catch {
        lastError = error.localizedDescription
        try? rootStore.markFailed(segment, in: closing.folder, error: error, startedAt: ended)
      }
      // Every writer has finished. Screen text is independent of speech and
      // of audio failures; an unreadable video fails on its own and is kept.
      if !shuttingDown { enqueueScreen(closing.folder) }
      closingTask = nil
      refreshStats()
      if restart, !shuttingDown { startInBackground() }
    }
  }

  func pauseDisplays(session: Bool = false) {
    if session { displayGate.sessionDidResignActive() } else { displayGate.screensDidSleep() }
    guard usesUnified else { return }
    endSegment(reason: .sleep, restart: false)
    if settings.enabled, !meetingActive { phase = .displayPaused }
  }

  func resumeDisplays(session: Bool = false) async {
    if session { displayGate.sessionDidBecomeActive() } else { displayGate.screensDidWake() }
    if settings.enabled { await startCapturing() }
  }

  private func screenStorageBytes() throws -> Int64 {
    let root = store.root.appending(path: "screen")
    guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
    var failure: Error?
    let walker = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      errorHandler: { _, error in failure = error; return false })
    var bytes: Int64 = 0
    while let url = walker?.nextObject() as? URL {
      let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if info.isRegularFile == true { bytes += Int64(info.fileSize ?? 0) }
    }
    if let failure { throw failure }
    return bytes
  }

  private func updateT3() async {
    // Only the production controller (with a media component) polls T3. Tests
    // and historical mic-only callers cannot accidentally contact the service.
    guard unified != nil, validateRoot() else { return }
    t3Epoch += 1
    let epoch = t3Epoch
    let key = "\(settings.rootURL.path)|\(settings.t3ctlPath)|\(settings.t3IncludeText)"
    if !settings.enabled || !settings.t3Enabled || shuttingDown || key != t3ConfigurationKey {
      t3UpdateTask?.cancel(); t3UpdateTask = nil
      await t3Collector?.stop()
      guard epoch == t3Epoch else { return }
      t3Collector = nil; t3State = .stopped
    }
    if key != t3ConfigurationKey {
      t3Snapshot = T3ActivityCollector.cachedSnapshot(root: settings.rootURL, includeText: settings.t3IncludeText)
        ?? .init(enabledAt: settings.enabledAt ?? now())
    }
    t3ConfigurationKey = key
    guard t3Collector == nil else { return }
    let collector = T3ActivityCollector(configuration: .init(root: settings.rootURL,
      enabledAt: settings.enabledAt ?? now(), t3ctlURL: URL(fileURLWithPath: (settings.t3ctlPath as NSString).expandingTildeInPath),
      mode: settings.t3IncludeText ? .includeText : .metadata))
    t3Snapshot = await collector.currentSnapshot()
    guard epoch == t3Epoch else { return }
    guard settings.enabled, settings.t3Enabled, !shuttingDown else { return }
    t3Collector = collector
    await collector.start()
    t3UpdateTask = Task { [weak self] in
      while !Task.isCancelled {
        let snapshot = await collector.currentSnapshot()
        let state = await collector.state
        guard !Task.isCancelled else { return }
        self?.t3Snapshot = snapshot; self?.t3State = state
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  /// Meaningful signal at or after `start`. The monitor only answers "quiet
  /// for at least d", so ask for a hair more than the elapsed time.
  private func hadSound(since start: Date, at time: Date) -> Bool {
    !activity.isQuiet(for: time.timeIntervalSince(start) + 0.001, at: time)
  }

  private func handleWriteFailure(at url: URL, error: String) {
    // A notification queued before rotation/stop must not stop a newer segment.
    guard let current, store.audioURL(in: current.folder) == url else { return }
    endSegment(reason: .stopped, restart: false)
    lastError = "Audio write failed: " + error
    phase = .retrying("Audio write failed: " + error)
    nextRetryAt = now() + Self.retryInterval
  }

  private func handleInterruption() {
    guard current != nil else { return }
    endSegment(reason: .deviceChange, restart: false)
    phase = .retrying("The microphone configuration changed.")
    nextRetryAt = now() + Self.interruptionRestartDelay
  }

  // MARK: - Transcription

  private func enqueue(_ folder: URL) {
    queue.append(folder)
    drainInBackground()
  }

  private func drainInBackground() {
    guard queueTask == nil, !queue.isEmpty else { return }
    queueTask = Task { [weak self] in
      await self?.drainQueue()
      self?.queueTask = nil
    }
  }

  private func drainQueue() async {
    while !shuttingDown, !Task.isCancelled, let folder = queue.first {
      if let blocker = transcriptionBlocker() {
        // Keep the audio and the queue; the periodic loop tries again.
        lastError = blocker
        return
      }
      queue.removeFirst()
      await transcribeSegment(at: folder)
    }
  }

  private func transcribeSegment(at folder: URL) async {
    let store = LifelogStore(root: folder.deletingLastPathComponent().deletingLastPathComponent(), calendar: calendar)
    guard LifelogSettings.rootError(store.root.path, reserved: reservedRoots()) == nil else { return }
    guard var segment = try? store.load(folder: folder) else { return }
    let audio = store.audioURL(in: folder)
    let started = now()
    do {
      if segment.status == .recording || (segment.closeReason == .recovered && segment.endedAt == nil) {
        segment.closeReason = .recovered
        // Header repair errors are failures; preserve the original audio.
        try WavFile.repairLifelogHeader(at: audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.intValue else {
          throw CocoaError(.fileReadCorruptFile)
        }
        let seconds = Double(max(0, bytes - 44) / MemoryLayout<Int16>.size) / Double(WavFile.sampleRate)
        segment.status = .pending
        segment.closeReason = .recovered
        segment.audioSeconds = seconds
        segment.endedAt = segment.startedAt + seconds
      }
      // Only a successful validated read can establish silence. The shared final
      // engine uses the throwing check again under its lock; EVERY error from
      // it propagates, so a later read failure can never become empty.
      let system = store.systemAudioURL(in: folder)
      if segment.closeReason == .recovered, FileManager.default.fileExists(atPath: system.path) {
        try WavFile.repairLifelogHeader(at: system)
      }
      let micSignal = try WavFile.checkedMeaningfulSignal(at: audio)
      let systemSignal = FileManager.default.fileExists(atPath: system.path)
        ? try WavFile.checkedMeaningfulSignal(at: system) : false
      let turns = micSignal || systemSignal ? try await transcribe(audio, system) : []
      try store.complete(
        segment, in: folder, turns: turns, transcriptionStartedAt: started, transcribedAt: now(),
        deleteAudio: !AudioRetentionSettingsStore.load(from: defaults))
    } catch is CancellationError {
      return
    } catch {
      lastError = "Transcription failed: \(error.localizedDescription)"
      try? store.markFailed(segment, in: folder, error: error, startedAt: started)
    }
    refreshStats()
  }

  // MARK: - Screen text

  private func recoverScreenText() {
    for folder in store.screenTextRecoveryFolders(excluding: current?.folder) { enqueueScreen(folder) }
    legacyScreenSegments = store.legacyScreenFolders(excluding: current?.folder).count
  }

  private func enqueueScreen(_ folder: URL) {
    guard !screenQueue.contains(folder) else { return }
    screenQueue.append(folder)
    guard screenTask == nil, !shuttingDown else { return }
    screenTask = Task(priority: .utility) { [weak self] in
      await self?.drainScreenQueue()
      self?.screenTask = nil
    }
  }

  private func drainScreenQueue() async {
    while !shuttingDown, !Task.isCancelled, let folder = screenQueue.first {
      screenQueue.removeFirst()
      let store = LifelogStore(root: folder.deletingLastPathComponent().deletingLastPathComponent(), calendar: calendar)
      guard LifelogSettings.rootError(store.root.path, reserved: reservedRoots()) == nil else { continue }
      let outcome = await LifelogScreenTextJob.run(store: store, folder: folder,
        deleteVideos: settings.screenTextDeletesVideo, extract: extractScreenText, now: now)
      if case .failed(let message) = outcome { lastError = "Screen text failed: " + message }
      screenTextRevision += 1
      refreshStats()
    }
  }

  // MARK: - Housekeeping

  private func startLoop() {
    displayCheckTask?.cancel()
    loopTask?.cancel()
    loopTask = Task { [weak self] in
      var seconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        self.tick()
        seconds += 1
        guard seconds % 60 == 0 else { continue }
        self.drainInBackground()
        // Never awaited here: a long digest must not stop segment cuts.
        Task { await self.runDueDigests() }
      }
    }
  }

  private var backendDescription: String {
    switch settings.digestBackend {
    case .codex: return "Codex"
    case .off: return "Off"
    case .command:
      let program = settings.digestCommand.split(separator: " ").first.map(String.init) ?? ""
      return "Command \(URL(fileURLWithPath: program).lastPathComponent)"
    }
  }

  private func refreshStats() {
    if unified != nil, LifelogSettings.rootError(settings.rootPath, reserved: reservedRoots()) == nil {
      do { screenBytes = try screenStorageBytes() }
      catch { lastError = "Cannot inspect screen storage: " + error.localizedDescription }
    }
    let store = self.store
    let day = store.dayKey(now())
    var stats = DayStats()
    for item in store.segments(on: day) {
      switch item.segment.status {
      case .complete:
        stats.completeSegments += 1
        stats.characters += item.segment.characterCount ?? 0
      case .empty: stats.emptySegments += 1
      case .failed: stats.failedSegments += 1
      case .pending: stats.pendingSegments += 1
      case .recording: break
      }
      switch item.segment.screenText?.status {
      case .complete: stats.screenTextComplete += 1
      case .pending where item.folder != current?.folder: stats.screenTextPending += 1
      case .failed: stats.screenTextFailed += 1
      default: break
      }
    }
    stats.silentSegmentsDiscarded = store.dayStats(day).silentSegmentsDiscarded
    todayStats = stats
  }
}
