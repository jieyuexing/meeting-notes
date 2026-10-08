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
    /// Capture could not start (for example the USB microphone is unplugged).
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
  }

  static let retryInterval: TimeInterval = 30
  static let interruptionRestartDelay: TimeInterval = 2

  private(set) var phase: Phase = .off
  private(set) var settings: LifelogSettings
  private(set) var todayStats = DayStats()
  private(set) var segmentStartedAt: Date?
  private(set) var lastError: String?
  private(set) var digestStatusText = ""
  private(set) var digestRunning = false

  private let defaults: UserDefaults
  private let capture: LifelogCapture
  private let transcribe: Transcribe
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
  private var loopTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  init(
    defaults: UserDefaults = .standard,
    capture: LifelogCapture = LifelogRecorder(),
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
    notesLanguage: @escaping () -> MeetingNotesLanguage = { MeetingNotesLanguageStore.load() }
  ) {
    self.defaults = defaults
    self.capture = capture
    self.transcribe = transcribe
    self.requestAccess = requestAccess
    self.transcriptionBlocker = transcriptionBlocker
    self.digestRequest = digestRequest
    self.reservedRoots = reservedRoots
    self.now = now
    self.calendar = calendar
    self.notesLanguage = notesLanguage
    settings = LifelogSettingsStore.load(from: defaults)
    let activity = activity
    capture.onSamples = { samples in activity.observe(samples, at: now()) }
    capture.onInterruption = { [weak self] in
      Task { @MainActor in self?.handleInterruption() }
    }
  }

  var store: LifelogStore { LifelogStore(root: settings.rootURL, calendar: calendar) }

  var statusText: String {
    switch phase {
    case .off: "Off"
    case .recording: "Recording · Mac stays awake"
    case .yieldingToMeeting: "Paused while a meeting is recorded"
    case .sleeping: "Paused while the Mac sleeps"
    case .retrying(let reason): "Waiting for the microphone: \(reason)"
    case .blocked(let reason): reason
    }
  }

  /// Recovers segments left by an earlier run and starts capture when enabled.
  func activate(observeSystem: Bool = true) {
    if validateRoot() {
      for folder in store.pendingFolders() where !queue.contains(folder) { enqueue(folder) }
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
      startLoop()
    }
    refreshStats()
    if settings.enabled { startInBackground() }
  }

  func setEnabled(_ enabled: Bool) async {
    settings.enabled = enabled
    LifelogSettingsStore.save(settings, to: defaults)
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
    // Close into the old root before adopting the new root, including silence counters.
    if previous.rootURL != updated.rootURL { endSegment(reason: .stopped, restart: false) }
    settings = updated
    LifelogSettingsStore.save(updated, to: defaults)
    if previous.rootURL != updated.rootURL {
      for folder in store.pendingFolders() where !queue.contains(folder) { enqueue(folder) }
    }
    await setEnabled(updated.enabled)
  }

  /// Synchronous close on normal application termination. Pending WAVs are
  /// durable; the next launch drains them. No asynchronous work is required to quit.
  func shutdown() {
    shuttingDown = true
    loopTask?.cancel()
    startTask?.cancel()
    nextRetryAt = nil
    endSegment(reason: .stopped, restart: false)
    queueTask?.cancel()
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
    endSegment(reason: .sleep, restart: false)
    if settings.enabled, !meetingActive { phase = .sleeping }
  }

  func systemDidWake() async {
    asleep = false
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
    case .retrying:
      guard let nextRetryAt, time >= nextRetryAt, startTask == nil else { return }
      self.nextRetryAt = nil
      startInBackground()
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
      transcribedCount: { day in store.segments(on: day).filter { $0.segment.status == .complete }.count },
      pendingCount: { day in
        store.segments(on: day).filter {
          $0.segment.status == .pending || $0.segment.status == .recording || $0.folder == currentFolder
        }.count
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
          try store.save(segment, in: item.folder)
          enqueue(item.folder)
        } catch { lastError = error.localizedDescription }
      }
    }
  }

  func waitForTranscriptions() async {
    while let queueTask { await queueTask.value }
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
    switch await startCheck() {
    case .skip: return
    case .blocked(let reason):
      phase = .blocked(reason)
      return
    case .go: break
    }
    do {
      let started = now()
      let created = try store.createSegment(id: UUID(), startedAt: started)
      do {
        try capture.start(
          writingTo: store.audioURL(in: created.folder),
          preferredDeviceUID: MicrophoneSettingsStore.preferredDeviceUID(from: defaults))
      } catch {
        try? FileManager.default.removeItem(at: created.folder)
        throw error
      }
      current = created
      segmentStartedAt = started
      nextRetryAt = nil
      phase = .recording
      wakeLock.acquire()
    } catch {
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
  private func endSegment(reason: LifelogCutReason, restart: Bool) {
    guard let closing = current else { return }
    let store = LifelogStore(root: closing.folder.deletingLastPathComponent().deletingLastPathComponent(), calendar: calendar)
    let ended = now()
    let hadSound = hadSound(since: closing.segment.startedAt, at: ended)
    var next: (segment: LifelogSegment, folder: URL)?
    var result: LifelogCaptureResult?
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
      result = try? capture.stop()
      phase = .retrying(error.localizedDescription)
      nextRetryAt = ended + Self.retryInterval
    }
    current = next
    segmentStartedAt = next?.segment.startedAt
    if next == nil { wakeLock.release() }
    if let writeError = result?.writeError { lastError = "Audio write failed: \(writeError)" }

    var segment = closing.segment
    segment.endedAt = ended
    segment.closeReason = reason
    segment.audioSeconds = result?.seconds ?? ended.timeIntervalSince(segment.startedAt)
    do {
      if let error = result?.writeError {
        segment.status = .failed
        segment.error = "Audio capture/write error: " + error
        try store.save(segment, in: closing.folder)
      } else if hadSound || WavFile.hasMeaningfulSignal(at: store.audioURL(in: closing.folder)) {
        segment.status = .pending
        try store.save(segment, in: closing.folder)
        enqueue(closing.folder)
      } else {
        try store.discardSilentSegment(segment, in: closing.folder, seconds: segment.audioSeconds ?? 0)
      }
    } catch {
      lastError = "Segment could not be saved: \(error.localizedDescription)"
    }
    refreshStats()
  }

  /// Meaningful signal at or after `start`. The monitor only answers "quiet
  /// for at least d", so ask for a hair more than the elapsed time.
  private func hadSound(since start: Date, at time: Date) -> Bool {
    !activity.isQuiet(for: time.timeIntervalSince(start) + 0.001, at: time)
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
    guard FileManager.default.fileExists(atPath: audio.path) else { return }
    if segment.status == .recording {
      // Left open by an earlier run: the WAV header may be stale.
      try? WavFile.repairHeader(at: audio)
      let bytes = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?
        .intValue ?? 44
      let seconds = Double(max(0, bytes - 44) / MemoryLayout<Int16>.size) / Double(WavFile.sampleRate)
      segment.status = .pending
      segment.closeReason = .recovered
      segment.audioSeconds = seconds
      segment.endedAt = segment.startedAt + seconds
    }
    let started = now()
    do {
      let turns: [TranscriptTurn]
      do {
        turns = try await transcribe(audio, store.systemAudioURL(in: folder))
      } catch let error as CocoaError where error.code == .fileReadCorruptFile {
        // The shared entry reports "no usable audio" this way.
        turns = []
      }
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

  // MARK: - Housekeeping

  private func startLoop() {
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
    }
    stats.silentSegmentsDiscarded = store.dayStats(day).silentSegmentsDiscarded
    todayStats = stats
  }
}
