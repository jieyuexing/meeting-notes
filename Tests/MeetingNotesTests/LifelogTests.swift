import Foundation
import Testing

@testable import MeetingNotes

// MARK: - Fixtures

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }

  var now: Date { lock.withLock { value } }

  func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class FakeCapture: LifelogCapture, @unchecked Sendable {
  var onSamples: (@Sendable ([Int16]) -> Void)?
  var onInterruption: (@Sendable () -> Void)?
  private(set) var current: URL?
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var rotations = 0
  var failStart = false
  var segmentSeconds: TimeInterval = 60

  var isRunning: Bool { current != nil }

  func start(writingTo url: URL, preferredDeviceUID: String?) throws {
    if failStart {
      throw NSError(domain: "FakeCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no mic"])
    }
    try WavFile.create(at: url).close()
    current = url
    starts += 1
  }

  func rotate(to url: URL) throws -> LifelogCaptureResult {
    let previous = try #require(current)
    try WavFile.create(at: url).close()
    current = url
    rotations += 1
    return LifelogCaptureResult(url: previous, seconds: segmentSeconds)
  }

  func stop() throws -> LifelogCaptureResult? {
    guard let previous = current else { return nil }
    current = nil
    stops += 1
    return LifelogCaptureResult(url: previous, seconds: segmentSeconds)
  }

  func emitSound() { onSamples?(Array(repeating: 3_000, count: 1_600)) }
}

/// Returns one turn per call unless the next scripted result says otherwise.
private final class FakeTranscriber: @unchecked Sendable {
  enum Outcome { case text(String), empty, noUsableAudio, failure }
  private let lock = NSLock()
  private var script: [Outcome] = []
  private(set) var calls = 0

  func enqueue(_ outcomes: Outcome...) { lock.withLock { script += outcomes } }

  func transcribe(_ microphone: URL, _ system: URL) async throws -> [TranscriptTurn] {
    let outcome = lock.withLock { () -> Outcome in
      calls += 1
      return script.isEmpty ? .text("今天下午三点给小王回电话。") : script.removeFirst()
    }
    switch outcome {
    case .text(let text):
      return [TranscriptTurn(start: 1, end: 6, speaker: "Unknown", text: text, source: .microphone)]
    case .empty: return []
    case .noUsableAudio: throw CocoaError(.fileReadCorruptFile)
    case .failure: throw NSError(domain: "FakeTranscriber", code: 2)
    }
  }
}

private func temporaryRoot() -> URL {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".local/tmp/lifelog-24h/tmp")
    .appending(path: "lifelog-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private var shanghai: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  return calendar
}

private func date(_ text: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: text)!
}

@MainActor
private struct Harness {
  let root: URL
  let clock: TestClock
  let capture = FakeCapture()
  let transcriber = FakeTranscriber()
  let defaults: UserDefaults
  let controller: LifelogController

  init(
    start: Date = date("2026-10-08T10:00:00+08:00"),
    settings: (inout LifelogSettings) -> Void = { _ in },
    digestRequest: LifelogDigest.Request? = nil
  ) {
    root = temporaryRoot()
    clock = TestClock(start)
    defaults = UserDefaults(suiteName: "lifelog-\(UUID().uuidString)")!
    var stored = LifelogSettings()
    stored.rootPath = root.appending(path: "lifelog").path
    settings(&stored)
    LifelogSettingsStore.save(stored, to: defaults)
    let clock = clock
    let transcriber = transcriber
    let request = digestRequest
    controller = LifelogController(
      defaults: defaults,
      capture: capture,
      transcribe: { try await transcriber.transcribe($0, $1) },
      requestAccess: { true },
      transcriptionBlocker: { nil },
      digestRequest: { _ in request },
      reservedRoots: { [] },
      now: { clock.now },
      calendar: shanghai,
      notesLanguage: { .chineseSimplified })
  }

  var store: LifelogStore { LifelogStore(root: root.appending(path: "lifelog"), calendar: shanghai) }

  /// Segments that are no longer being written.
  func closed(_ day: String) -> [(segment: LifelogSegment, folder: URL)] {
    store.segments(on: day).filter { $0.segment.status != .recording }
  }
}

// MARK: - Settings and isolation

@Test func lifelogSettingsDefaultOffWithSeparateRootAndRoundTrip() {
  let defaults = UserDefaults(suiteName: "lifelog-settings-\(UUID().uuidString)")!
  let loaded = LifelogSettingsStore.load(from: defaults)
  #expect(!loaded.enabled)
  #expect(loaded.rootPath == "~/jieyuexing-universe/.state/opsail/lifelog")
  #expect(loaded.silenceThreshold == 180)
  #expect(loaded.maximumSegmentDuration == 1_800)
  #expect(loaded.digestCommand.isEmpty)
  #expect(loaded.digestMinuteOfDay == 23 * 60 + 55)
  #expect(loaded.digestBackendSettings == nil)

  var changed = loaded
  changed.enabled = true
  changed.silenceThreshold = 120
  changed.maximumSegmentDuration = 600
  changed.digestCommand = "/abs/lmstudio-summary"
  changed.digestMinuteOfDay = 22 * 60
  LifelogSettingsStore.save(changed, to: defaults)
  #expect(LifelogSettingsStore.load(from: defaults) == changed)
  #expect(
    changed.digestBackendSettings
      == SummaryBackendSettings(backend: .command, command: "/abs/lmstudio-summary"))

  // Out-of-range values are clamped rather than stored verbatim.
  defaults.set(1.0, forKey: "lifelog.silenceSeconds")
  defaults.set(99_999.0, forKey: "lifelog.maximumSegmentSeconds")
  defaults.set(5_000, forKey: "lifelog.digest.minuteOfDay")
  let clamped = LifelogSettingsStore.load(from: defaults)
  #expect(clamped.silenceThreshold == LifelogSettings.silenceRange.lowerBound)
  #expect(clamped.maximumSegmentDuration == LifelogSettings.maximumSegmentRange.upperBound)
  #expect(clamped.digestMinuteOfDay == 23 * 60 + 55)
}

@Test func lifelogDigestBackendOffOrBlankCommandNeverSummarizes() {
  var settings = LifelogSettings()
  settings.digestBackend = .command
  settings.digestCommand = "   "
  #expect(settings.digestBackendSettings == nil)
  settings.digestCommand = "echo {}"
  settings.digestBackend = .off
  #expect(settings.digestBackendSettings == nil)
  settings.digestBackend = .codex
  #expect(settings.digestBackendSettings?.backend == .codex)
}

@Test func lifelogRootMustStayOutsideMeetingStorage() {
  let archive = URL(fileURLWithPath: "/Users/me/universe/.state/opsail/meeting-notes")
  let spool = URL(fileURLWithPath: "/Users/me/Library/Application Support/MeetingNotes/Spool")
  let reserved = [archive, spool]
  #expect(LifelogSettings.rootError("/Users/me/universe/.state/opsail/lifelog", reserved: reserved) == nil)
  #expect(LifelogSettings.rootError("~/lifelog", reserved: reserved) == nil)
  #expect(LifelogSettings.rootError(archive.path, reserved: reserved) != nil)
  #expect(LifelogSettings.rootError(archive.path + "/lifelog", reserved: reserved) != nil)
  #expect(LifelogSettings.rootError(spool.path + "/x", reserved: reserved) != nil)
  // A root that would contain the meeting archive is rejected too.
  #expect(LifelogSettings.rootError("/Users/me/universe/.state/opsail", reserved: reserved) != nil)
  #expect(LifelogSettings.rootError("relative/path", reserved: reserved) != nil)
  #expect(LifelogSettings.rootError("  ", reserved: reserved) != nil)
}

// MARK: - Segmentation policy

@Test func segmentPolicyCutsOnSilenceOnlyAfterSoundAndCapsDuration() {
  let policy = LifelogSegmentPolicy(silenceThreshold: 180, maximumDuration: 1_800)
  let start = date("2026-10-08T10:00:00+08:00")
  func decide(after seconds: TimeInterval, hadSound: Bool, quietFor: TimeInterval)
    -> LifelogSegmentPolicy.Decision
  {
    policy.decide(
      segmentStartedAt: start, now: start + seconds, hadSound: hadSound,
      quietForThreshold: quietFor >= 180, calendar: shanghai)
  }
  #expect(decide(after: 60, hadSound: true, quietFor: 10) == .keep)
  // Exactly at the threshold the segment is cut; one second earlier it is kept.
  #expect(decide(after: 400, hadSound: true, quietFor: 179) == .keep)
  #expect(decide(after: 400, hadSound: true, quietFor: 180) == .cut(.silence))
  // A segment that never heard anything rolls over instead of growing.
  #expect(decide(after: 179, hadSound: false, quietFor: 179) == .keep)
  #expect(decide(after: 180, hadSound: false, quietFor: 180) == .discardSilence)
  // The cap applies even while someone keeps talking.
  #expect(decide(after: 1_799, hadSound: true, quietFor: 0) == .keep)
  #expect(decide(after: 1_800, hadSound: true, quietFor: 0) == .cut(.maximumDuration))
}

@Test func segmentPolicyRequestsCutOnFirstTickAfterLocalMidnight() {
  let policy = LifelogSegmentPolicy(silenceThreshold: 180, maximumDuration: 1_800)
  let start = date("2026-10-08T23:50:00+08:00")
  #expect(
    policy.decide(
      segmentStartedAt: start, now: date("2026-10-08T23:59:59+08:00"), hadSound: true,
      quietForThreshold: false, calendar: shanghai) == .keep)
  #expect(
    policy.decide(
      segmentStartedAt: start, now: date("2026-10-09T00:00:00+08:00"), hadSound: true,
      quietForThreshold: false, calendar: shanghai) == .cut(.midnight))
  #expect(
    policy.decide(
      segmentStartedAt: date("2026-10-08T23:59:00+08:00"),
      now: date("2026-10-09T00:00:01+08:00"), hadSound: false,
      quietForThreshold: false, calendar: shanghai) == .discardSilence)
}

@Test func segmentsBelongToTheLocalDayOfTheirStart() {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  #expect(store.dayKey(date("2026-10-08T23:59:59+08:00")) == "2026-10-08")
  #expect(store.dayKey(date("2026-10-08T16:00:00Z")) == "2026-10-09")
}

// MARK: - Controller: rotation, silence, meeting hand-off

@MainActor
@Test func controllerRotatesWithoutStoppingFakeCaptureAndTranscribesOnlySegmentsWithSound() async throws {
  let harness = Harness()
  let controller = harness.controller
  await controller.setEnabled(true)
  #expect(controller.phase == .recording)
  #expect(harness.capture.starts == 1)

  // Pure silence rolls over without transcription and is only counted.
  harness.clock.advance(180)
  controller.tick()
  #expect(harness.capture.rotations == 1)
  #expect(harness.capture.stops == 0)
  await controller.waitForTranscriptions()
  #expect(harness.transcriber.calls == 0)
  #expect(harness.store.dayStats("2026-10-08").silentSegmentsDiscarded == 1)
  #expect(harness.closed("2026-10-08").isEmpty)

  // Sound, then three quiet minutes: the segment is cut and transcribed.
  harness.clock.advance(30)
  harness.capture.emitSound()
  harness.clock.advance(179)
  controller.tick()
  #expect(harness.capture.rotations == 1)
  harness.clock.advance(1)
  controller.tick()
  #expect(harness.capture.rotations == 2)
  await controller.waitForTranscriptions()
  let segments = harness.closed("2026-10-08")
  #expect(segments.count == 1)
  let (segment, folder) = try #require(segments.first)
  #expect(segment.status == .complete)
  #expect(segment.closeReason == .silence)
  #expect(segment.characterCount == "今天下午三点给小王回电话。".count)
  #expect(segment.language == "zh")
  #expect(segment.transcribedAt != nil)
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "transcript.md").path))
  // Audio is deleted after processing under the default retention setting.
  #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "microphone.wav").path))
  let transcript = try String(contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8)
  #expect(transcript.contains("**[10:03:01]** 今天下午三点给小王回电话。"))
  // Rotation never stopped the capture.
  #expect(harness.capture.isRunning)
}

@MainActor
@Test func soundWithoutRecognizableSpeechIsMarkedEmptyAndCounted() async throws {
  let harness = Harness()
  harness.transcriber.enqueue(.empty, .noUsableAudio)
  let controller = harness.controller
  await controller.setEnabled(true)
  for _ in 0..<2 {
    harness.capture.emitSound()
    harness.clock.advance(180)
    controller.tick()
  }
  await controller.waitForTranscriptions()
  let segments = harness.closed("2026-10-08")
  #expect(segments.count == 2)
  #expect(segments.allSatisfy { $0.segment.status == .empty })
  #expect(segments.allSatisfy {
    !FileManager.default.fileExists(atPath: $0.folder.appending(path: "transcript.md").path)
      && !FileManager.default.fileExists(atPath: $0.folder.appending(path: "microphone.wav").path)
  })
  #expect(controller.todayStats.emptySegments == 2)
  #expect(controller.todayStats.completeSegments == 0)
}

@MainActor
@Test func failedTranscriptionKeepsTheAudio() async throws {
  let harness = Harness()
  harness.transcriber.enqueue(.failure)
  await harness.controller.setEnabled(true)
  harness.capture.emitSound()
  harness.clock.advance(1_800)
  harness.controller.tick()
  await harness.controller.waitForTranscriptions()
  let (segment, folder) = try #require(harness.closed("2026-10-08").first)
  #expect(segment.status == .failed)
  #expect(segment.closeReason == .maximumDuration)
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "microphone.wav").path))
}

@MainActor
@Test func meetingRecordingSuspendsLifelogAndResumesAfterwards() async throws {
  let harness = Harness()
  let controller = harness.controller
  await controller.setEnabled(true)
  harness.capture.emitSound()
  harness.clock.advance(20)

  controller.meetingCaptureWillStart()
  #expect(controller.phase == .yieldingToMeeting)
  #expect(harness.capture.stops == 1)
  #expect(!harness.capture.isRunning)
  // Ticks during the meeting never restart capture.
  harness.clock.advance(600)
  controller.tick()
  #expect(!harness.capture.isRunning)

  await controller.meetingCaptureDidEnd()
  #expect(controller.phase == .recording)
  #expect(harness.capture.starts == 2)
  await controller.waitForTranscriptions()
  let (segment, _) = try #require(harness.closed("2026-10-08").first)
  #expect(segment.closeReason == .meeting)
  #expect(segment.status == .complete)
}

@MainActor
@Test func meetingEndDoesNotStartLifelogWhenDisabled() async {
  let harness = Harness()
  let controller = harness.controller
  controller.meetingCaptureWillStart()
  await controller.meetingCaptureDidEnd()
  #expect(controller.phase == .off)
  #expect(harness.capture.starts == 0)

  // Enabling during a meeting waits for the meeting to end.
  controller.meetingCaptureWillStart()
  await controller.setEnabled(true)
  #expect(controller.phase == .yieldingToMeeting)
  #expect(harness.capture.starts == 0)
  await controller.meetingCaptureDidEnd()
  #expect(controller.phase == .recording)
}

@MainActor
@Test func sleepClosesTheSegmentAndWakeStartsAFreshOne() async throws {
  let harness = Harness()
  let controller = harness.controller
  await controller.setEnabled(true)
  harness.capture.emitSound()
  harness.clock.advance(40)
  controller.systemWillSleep()
  #expect(controller.phase == .sleeping)
  #expect(!harness.capture.isRunning)
  harness.clock.advance(3_600)
  await controller.systemDidWake()
  #expect(controller.phase == .recording)
  await controller.waitForTranscriptions()
  #expect(harness.closed("2026-10-08").first?.segment.closeReason == .sleep)
}

@MainActor
@Test func disablingClosesTheSegmentAndMicrophoneFailureRetries() async throws {
  let harness = Harness()
  let controller = harness.controller
  harness.capture.failStart = true
  await controller.setEnabled(true)
  guard case .retrying = controller.phase else {
    Issue.record("Expected a retry state, got \(controller.phase)")
    return
  }
  harness.capture.failStart = false
  harness.clock.advance(LifelogController.retryInterval)
  controller.tick()
  await controller.waitForStart()
  #expect(controller.phase == .recording)

  harness.capture.emitSound()
  harness.clock.advance(10)
  await controller.setEnabled(false)
  #expect(controller.phase == .off)
  #expect(!harness.capture.isRunning)
  await controller.waitForTranscriptions()
  #expect(harness.closed("2026-10-08").first?.segment.closeReason == .stopped)
}

@MainActor
@Test func controllerRefusesToStartWhenTranscriptionWouldLeaveTheMac() async {
  let root = temporaryRoot()
  let defaults = UserDefaults(suiteName: "lifelog-\(UUID().uuidString)")!
  var settings = LifelogSettings()
  settings.rootPath = root.path
  LifelogSettingsStore.save(settings, to: defaults)
  let capture = FakeCapture()
  let controller = LifelogController(
    defaults: defaults, capture: capture,
    transcribe: { _, _ in [] }, requestAccess: { true },
    transcriptionBlocker: { "OpenAI transcription is selected." },
    digestRequest: { _ in nil }, reservedRoots: { [] })
  await controller.setEnabled(true)
  #expect(capture.starts == 0)
  guard case .blocked = controller.phase else {
    Issue.record("Expected blocked, got \(controller.phase)")
    return
  }
}

@MainActor
@Test func pendingSegmentsFromAnEarlierRunAreTranscribedOnActivation() async throws {
  let root = temporaryRoot().appending(path: "lifelog")
  let store = LifelogStore(root: root, calendar: shanghai)
  let (segment, folder) = try store.createSegment(
    id: UUID(), startedAt: date("2026-10-08T09:00:00+08:00"))
  try WavFile.create(at: store.audioURL(in: folder)).close()
  #expect(segment.status == .recording)
  #expect(store.pendingFolders() == [folder])

  let defaults = UserDefaults(suiteName: "lifelog-\(UUID().uuidString)")!
  var settings = LifelogSettings()
  settings.rootPath = root.path
  LifelogSettingsStore.save(settings, to: defaults)
  let transcriber = FakeTranscriber()
  let controller = LifelogController(
    defaults: defaults, capture: FakeCapture(),
    transcribe: { try await transcriber.transcribe($0, $1) }, requestAccess: { true },
    transcriptionBlocker: { nil }, digestRequest: { _ in nil }, reservedRoots: { [] },
    calendar: shanghai)
  controller.activate(observeSystem: false)
  await controller.waitForTranscriptions()
  let recovered = try store.load(folder: folder)
  #expect(recovered.status == .complete)
  #expect(recovered.closeReason == .recovered)
  #expect(store.pendingFolders().isEmpty)
}

// MARK: - Daily digest

private func completeSegment(
  _ store: LifelogStore, at start: String, lines: [(TimeInterval, String)]
) throws -> URL {
  let startedAt = date(start)
  var (segment, folder) = try store.createSegment(id: UUID(), startedAt: startedAt)
  segment.endedAt = startedAt + (lines.last?.0 ?? 0) + 5
  segment.status = .pending
  let turns = lines.map {
    TranscriptTurn(start: $0.0, end: $0.0 + 4, speaker: "Unknown", text: $0.1, source: .microphone)
  }
  try store.complete(
    segment, in: folder, turns: turns, transcriptionStartedAt: segment.endedAt!,
    transcribedAt: segment.endedAt! + 2, deleteAudio: true)
  return folder
}

@Test func digestChunksKeepEveryLineInTimeOrderWithinTheLimit() throws {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  _ = try completeSegment(
    store, at: "2026-10-08T14:00:00+08:00",
    lines: (0..<30).map { (TimeInterval($0 * 10), String(repeating: "下", count: 90)) })
  _ = try completeSegment(
    store, at: "2026-10-08T09:00:00+08:00", lines: [(0, "早上先整理邮件。"), (30, "十点开会。")])
  let entries = LifelogDigest.entries(store: store, day: "2026-10-08")
  #expect(entries.map(\.label) == ["S1", "S2"])
  #expect(entries[0].lines.first == "[09:00:00] 早上先整理邮件。")
  let chunks = LifelogDigest.chunks(entries, limit: 1_000)
  #expect(chunks.count > 1)
  #expect(chunks.allSatisfy { $0.count <= 1_000 })
  let joined = chunks.joined(separator: "\n")
  for entry in entries {
    for line in entry.lines { #expect(joined.contains(line)) }
  }
  // A continued segment repeats its header so the model can still cite it.
  #expect(chunks.dropFirst().allSatisfy { $0.hasPrefix("### S2 · ") })
  #expect(joined.range(of: "[09:00:00]")!.lowerBound < joined.range(of: "[14:00:00]")!.lowerBound)
  // A long ASR fallback line must also be bounded, with every character kept.
  let long = LifelogDigest.Entry(
    label: "S1", folderPath: "x", startedAt: Date(), endedAt: Date(),
    lines: ["[10:00:00] " + String(repeating: "长", count: 2_000)])
  let split = LifelogDigest.chunks([long], limit: 1_000)
  #expect(split.count > 1)
  #expect(split.allSatisfy { $0.count <= 1_000 })
  #expect(split.joined().filter { $0 == "长" }.count == 2_000)
}

@Test func digestOnlyCoversTheRequestedDay() throws {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  _ = try completeSegment(store, at: "2026-10-08T23:58:00+08:00", lines: [(0, "睡前记一下明天买牛奶。")])
  _ = try completeSegment(store, at: "2026-10-09T00:00:00+08:00", lines: [(0, "零点以后的话。")])
  let entries = LifelogDigest.entries(store: store, day: "2026-10-08")
  #expect(entries.count == 1)
  #expect(entries[0].lines == ["[23:58:00] 睡前记一下明天买牛奶。"])
}

@Test func digestWithoutABackendWritesNothing() async throws {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  _ = try completeSegment(store, at: "2026-10-08T09:00:00+08:00", lines: [(0, "测试。")])
  let run = try await LifelogDigest.generate(
    store: store, day: "2026-10-08", label: nil, chunkCharacters: 12_000,
    language: .chineseSimplified, request: nil)
  #expect(run.status == .skipped)
  #expect(!FileManager.default.fileExists(atPath: store.digestURL(day: "2026-10-08", label: nil).path))
}

@Test func digestMapsChunksThenMergesAndLinksSegments() async throws {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  let morning = try completeSegment(
    store, at: "2026-10-08T09:00:00+08:00",
    lines: (0..<12).map { (TimeInterval($0 * 10), "上午讨论发布计划第\($0)项" + String(repeating: "。", count: 60)) })
  _ = try completeSegment(
    store, at: "2026-10-08T15:00:00+08:00",
    lines: (0..<12).map { (TimeInterval($0 * 10), "下午约定周五交付第\($0)项" + String(repeating: "。", count: 60)) })
  final class Prompts: @unchecked Sendable {
    let lock = NSLock()
    var values: [String] = []
  }
  let prompts = Prompts()
  let response = """
    {"overview":"讨论发布与交付。","periods":[{"start":"09:00","end":"09:02","title":"发布计划","summary":"上午过了一遍发布计划。"}],
     "actions":[{"text":"周五交付","kind":"commitment","time":"15:00","segment":"S2"}],
     "reviews":[{"time":"09:01","segment":"S1","reason":"发布顺序没定。"},{"time":"10:00","segment":"S9","reason":"未知段。"}]}
    """
  let request: LifelogDigest.Request = { prompt, _ in
    prompts.lock.withLock { prompts.values.append(prompt) }
    return Data(response.utf8)
  }
  let run = try await LifelogDigest.generate(
    store: store, day: "2026-10-08", label: nil, chunkCharacters: 1_200,
    language: .chineseSimplified, request: request, backendDescription: "test")
  #expect(run.status == .complete)
  #expect(run.chunkCount > 1)
  #expect(run.requestCount == run.chunkCount + 1)
  #expect(run.segmentCount == 2)
  #expect(run.inputCharacters == prompts.values.map(\.count).reduce(0, +))
  #expect(prompts.values.last?.contains("BEGIN PARTIAL DIGESTS") == true)
  #expect(prompts.values.first?.contains("BEGIN TRANSCRIPT") == true)

  let markdown = try String(
    contentsOf: store.digestURL(day: "2026-10-08", label: nil), encoding: .utf8)
  #expect(markdown.contains("# 2026-10-08 常开记录汇总"))
  #expect(markdown.contains("讨论发布与交付。"))
  #expect(markdown.contains("[S1 09:01](../2026-10-08/\(morning.lastPathComponent)/transcript.md)"))
  #expect(markdown.contains("S9 10:00"))
  #expect(!markdown.contains("(../2026-10-08/S9"))
  let meta = try #require(store.digestRun(day: "2026-10-08", label: nil))
  #expect(meta.segmentIDs.count == 2)

  // A labelled rerun for model comparison never overwrites the main digest.
  _ = try await LifelogDigest.generate(
    store: store, day: "2026-10-08", label: "codex", chunkCharacters: 1_200,
    language: .chineseSimplified, request: request)
  #expect(store.digestURL(day: "2026-10-08", label: "codex").lastPathComponent == "2026-10-08.codex.md")
  #expect(FileManager.default.fileExists(atPath: store.digestURL(day: "2026-10-08", label: "codex").path))
}

@Test func digestFailureLeavesTranscriptsAndRecordsTheError() async throws {
  let store = LifelogStore(root: temporaryRoot(), calendar: shanghai)
  let folder = try completeSegment(store, at: "2026-10-08T09:00:00+08:00", lines: [(0, "测试。")])
  let run = try await LifelogDigest.generate(
    store: store, day: "2026-10-08", label: nil, chunkCharacters: 12_000,
    language: .chineseSimplified,
    request: { _, _ in throw CommandSummaryBackend.CommandError.noJSONObject })
  #expect(run.status == .failed)
  #expect(run.error != nil)
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "transcript.md").path))
  #expect(!FileManager.default.fileExists(atPath: store.digestURL(day: "2026-10-08", label: nil).path))
  #expect(store.digestRun(day: "2026-10-08", label: nil)?.status == .failed)
}

@Test func digestScheduleRunsAfterTheConfiguredTimeAndCatchesUpOnce() {
  let calendar = shanghai
  let minute = 23 * 60 + 55
  func due(
    _ now: String, runs: [String: LifelogDigest.Run] = [:], transcribed: [String: Int],
    pending: [String: Int] = [:]
  ) -> [String] {
    LifelogDigestSchedule.dueDays(
      now: date(now), minuteOfDay: minute, calendar: calendar,
      run: { runs[$0] }, transcribedCount: { transcribed[$0] ?? 0 },
      pendingCount: { pending[$0] ?? 0 })
  }
  #expect(due("2026-10-08T23:54:59+08:00", transcribed: ["2026-10-08": 3]).isEmpty)
  #expect(due("2026-10-08T23:55:00+08:00", transcribed: ["2026-10-08": 3]) == ["2026-10-08"])
  // Nothing transcribed: no empty digest.
  #expect(due("2026-10-08T23:56:00+08:00", transcribed: [:]).isEmpty)

  let partial = LifelogDigest.Run.fixture(day: "2026-10-08", segmentCount: 3, attempts: 1)
  // The last minutes of the day arrive after midnight: wait for them, then catch up.
  #expect(
    due(
      "2026-10-09T00:01:00+08:00", runs: ["2026-10-08": partial],
      transcribed: ["2026-10-08": 3], pending: ["2026-10-08": 1]
    ).isEmpty)
  #expect(
    due(
      "2026-10-09T00:03:00+08:00", runs: ["2026-10-08": partial],
      transcribed: ["2026-10-08": 4]) == ["2026-10-08"])
  // A digest that covers everything, or one that already used its attempts, is left alone.
  #expect(
    due(
      "2026-10-09T00:03:00+08:00", runs: ["2026-10-08": partial],
      transcribed: ["2026-10-08": 3]
    ).isEmpty)
  let exhausted = LifelogDigest.Run.fixture(
    day: "2026-10-08", segmentCount: 3, attempts: LifelogDigestSchedule.maximumAttempts)
  #expect(
    due(
      "2026-10-09T00:03:00+08:00", runs: ["2026-10-08": exhausted],
      transcribed: ["2026-10-08": 4]
    ).isEmpty)
  // A day the app missed entirely is written the next day.
  #expect(due("2026-10-09T08:00:00+08:00", transcribed: ["2026-10-08": 2]) == ["2026-10-08"])
}

@MainActor
@Test func scheduledDigestIsSkippedWithoutCommandAndWrittenWithOne() async throws {
  let quiet = Harness(start: date("2026-10-08T23:40:00+08:00"))
  await quiet.controller.setEnabled(true)
  quiet.capture.emitSound()
  quiet.clock.advance(180)
  quiet.controller.tick()
  await quiet.controller.waitForTranscriptions()
  quiet.clock.advance(15 * 60)
  await quiet.controller.runDueDigests()
  #expect(!FileManager.default.fileExists(atPath: quiet.store.digestURL(day: "2026-10-08", label: nil).path))

  let response = #"{"overview":"一天。","periods":[],"actions":[],"reviews":[]}"#
  let active = Harness(
    start: date("2026-10-08T23:40:00+08:00"),
    digestRequest: { _, _ in Data(response.utf8) })
  await active.controller.setEnabled(true)
  active.capture.emitSound()
  active.clock.advance(180)
  active.controller.tick()
  await active.controller.waitForTranscriptions()
  active.clock.advance(15 * 60)
  await active.controller.runDueDigests()
  #expect(FileManager.default.fileExists(atPath: active.store.digestURL(day: "2026-10-08", label: nil).path))
  #expect(active.store.digestRun(day: "2026-10-08", label: nil)?.attempts == 1)
}

extension LifelogDigest.Run {
  fileprivate static func fixture(day: String, segmentCount: Int, attempts: Int) -> Self {
    LifelogDigest.Run(
      date: day, label: nil, generatedAt: Date(), status: .complete, error: nil,
      durationSeconds: 1, inputCharacters: 1, chunkCount: 1, requestCount: 1,
      segmentCount: segmentCount, segmentIDs: [], attempts: attempts, backend: nil)
  }
}

// MARK: - Opt-in comparison entry

/// Reruns the digest for one day with an explicit command, outside the app:
/// `MEETING_NOTES_LIFELOG_ROOT`, `MEETING_NOTES_LIFELOG_DIGEST_DATE`,
/// `MEETING_NOTES_LIFELOG_LABEL` and `MEETING_NOTES_TEST_COMMAND`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_NOTES_LIFELOG_DIGEST_DATE"] != nil))
func lifelogDigestProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  let root = try #require(environment["MEETING_NOTES_LIFELOG_ROOT"])
  let day = try #require(environment["MEETING_NOTES_LIFELOG_DIGEST_DATE"])
  let label = try #require(environment["MEETING_NOTES_LIFELOG_LABEL"])
  let command = try #require(environment["MEETING_NOTES_TEST_COMMAND"])
  #expect(root.hasPrefix("/"))
  let store = LifelogStore(root: URL(fileURLWithPath: root, isDirectory: true))
  let settings = SummaryBackendSettings(backend: .command, command: command)
  let run = try await LifelogDigest.generate(
    store: store, day: day, label: label,
    chunkCharacters: Int(environment["MEETING_NOTES_LIFELOG_CHUNK"] ?? "") ?? LifelogSettings().digestChunkCharacters,
    language: MeetingNotesLanguageStore.load(),
    request: LifelogDigest.request(for: settings), backendDescription: label)
  print("LIFELOG_DIGEST_RESULT: \(run.status.rawValue) \(store.digestURL(day: day, label: label).path)")
  #expect(run.status == .complete)
}

// Handoff regressions: written before fixing the inherited implementation.
@MainActor
@Test func lifelogRootChangeRejectsOverlapBeforeStoppingCapture() async {
  let harness = Harness()
  await harness.controller.setEnabled(true)
  let previous = harness.controller.settings
  var updated = previous
  updated.rootPath = "relative-path"
  await harness.controller.updateSettings(updated)
  #expect(harness.controller.settings.rootPath == previous.rootPath)
  #expect(harness.capture.isRunning)
}

@MainActor
@Test func lifelogQuietRootChangeWritesCountersToOriginalRoot() async {
  let harness = Harness()
  await harness.controller.setEnabled(true)
  harness.clock.advance(30)
  var updated = harness.controller.settings
  updated.rootPath = harness.root.appending(path: "new-root").path
  await harness.controller.updateSettings(updated)
  #expect(harness.store.dayStats("2026-10-08").silentSegmentsDiscarded == 1)
  #expect(harness.store.segments(on: "2026-10-08").isEmpty)
}

@Test func lifelogRejectsFilesystemRootWithoutReservedLocations() {
  #expect(LifelogSettings.rootError("/", reserved: []) != nil)
}

@MainActor
@Test func lifelogShutdownClosesTailAndPreservesEnabledPreference() async throws {
  let harness = Harness()
  await harness.controller.setEnabled(true)
  harness.capture.emitSound()
  harness.clock.advance(12)
  harness.controller.shutdown()
  #expect(!harness.capture.isRunning)
  #expect(LifelogSettingsStore.load(from: harness.defaults).enabled)
  let tail = try #require(harness.closed("2026-10-08").first)
  #expect(tail.segment.status == .pending)
  #expect(tail.segment.closeReason == .stopped)
  #expect(FileManager.default.fileExists(atPath: harness.store.audioURL(in: tail.folder).path))
  harness.clock.advance(120)
  harness.controller.tick()
  await harness.controller.setEnabled(true)
  #expect(harness.capture.starts == 1)
}

@MainActor
@Test func lifelogFailedSegmentsCanBeRetriedWithoutRecapturing() async throws {
  let harness = Harness()
  harness.transcriber.enqueue(.failure)
  await harness.controller.setEnabled(true)
  harness.capture.emitSound()
  harness.clock.advance(20)
  await harness.controller.setEnabled(false)
  await harness.controller.waitForTranscriptions()
  #expect(harness.closed("2026-10-08").first?.segment.status == .failed)
  harness.controller.retryFailedSegments()
  await harness.controller.waitForTranscriptions()
  #expect(harness.closed("2026-10-08").first?.segment.status == .complete)
  #expect(harness.capture.starts == 1)
}

@Test func lifelogDigestScheduleUsesWallClockAcrossDST() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/New_York")!
  let due = LifelogDigestSchedule.dueDays(
    now: date("2026-11-01T23:00:00-05:00"), minuteOfDay: 23 * 60 + 55,
    calendar: calendar, run: { _ in nil },
    transcribedCount: { $0 == "2026-11-01" ? 1 : 0 }, pendingCount: { _ in 0 })
  #expect(due.isEmpty)
}
