import Foundation
import Testing
@testable import MeetingNotes

private actor MediaLatch {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
  func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}
private struct AwakeDesktop: DisplayCaptureAvailabilityProviding {
  func availability() async -> DisplayCaptureAvailability { .init(hasDesktopSession: true, hasDisplay: true) }
}
private final class FixtureMic: LifelogCapture, @unchecked Sendable {
  var onSamples: (@Sendable ([Int16]) -> Void)?
  var onInterruption: (@Sendable () -> Void)?
  var onWriteFailure: (@Sendable (URL, String) -> Void)?
  var current: URL?
  var starts = 0
  var isRunning: Bool { current != nil }
  func start(writingTo url: URL, preferredDeviceUID: String?) throws {
    try WavFile.finalize(WavFile.create(at: url), bytes: 0); current = url; starts += 1
  }
  func stop() throws -> LifelogCaptureResult? {
    defer { current = nil }; return current.map { .init(url: $0, seconds: 1) }
  }
  func rotate(to url: URL) throws -> LifelogCaptureResult {
    let old = try #require(try stop()); try start(writingTo: url, preferredDeviceUID: nil); return old
  }
}
private final class FixtureMedia: UnifiedSegmentCapturing, @unchecked Sendable {
  var onFailure: (@Sendable (URL, String) -> Void)?
  var onSamples: (@Sendable ([Int16]) -> Void)?
  let startLatch: MediaLatch?
  let closeLatch: MediaLatch?
  var failStart = false
  var systemSignal = false
  var metadata: UnifiedCaptureMetadata?
  var admitted = false
  var suspended = false
  var closed = false
  init(start: MediaLatch? = nil, close: MediaLatch? = nil) { startLatch = start; closeLatch = close }
  func start(segment: UnifiedCaptureSegment, clock: CaptureClock) async throws {
    try FileManager.default.createDirectory(at: segment.root, withIntermediateDirectories: true)
    let handle = try WavFile.create(at: segment.systemAudioURL)
    let samples = [Int16](repeating: systemSignal ? 3000 : 0, count: 1600)
    try handle.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    try WavFile.finalize(handle, bytes: samples.count * 2)
    try Data("fixture-video".utf8).write(to: segment.root.appending(path: "screen-1.mp4"))
    metadata = .init(startedAt: segment.startedAt, endedAt: nil, systemAudioFile: "system.wav", displays: [], gaps: [], failure: nil)
    await startLatch?.wait()
    if failStart { throw CocoaError(.fileWriteUnknown) }
    admitted = !suspended
  }
  func rotate(to segment: UnifiedCaptureSegment, clock: CaptureClock) async throws {
    _ = try await stop(); try await start(segment: segment, clock: clock)
  }
  func suspendImmediately() { suspended = true; admitted = false }
  func stop() async throws -> UnifiedCaptureMetadata? {
    await closeLatch?.wait(); closed = true; metadata?.endedAt = Date(); return metadata
  }
}
private actor TranscriptionReceipt {
  var calls = 0
  func invoke(_ mic: URL, _ system: URL) throws -> [TranscriptTurn] {
    #expect(try !WavFile.checkedMeaningfulSignal(at: mic))
    #expect(try WavFile.checkedMeaningfulSignal(at: system))
    calls += 1
    return [.init(start: 0, end: 1, speaker: "Unknown", text: "remote speaker", source: .system)]
  }
}
/// Fixture recognition result: one entry per video, no Vision involved.
private let fixtureScreenText: LifelogScreenTextJob.Extract = { videos, start in
  let entries = videos.map {
    ScreenTextEntry(displayID: $0.displayID, startedAt: start + 1, endedAt: start + 4, startOffset: 1,
      endOffset: 4, keyframes: 2, lines: ["Fixture screen line", "第二行"])
  }
  var stats = ScreenTextStats(); stats.displays = videos.count; stats.totalFrames = 8
  stats.keyframes = 2 * videos.count; stats.entries = entries.count
  stats.characters = entries.map(\.characterCount).reduce(0, +)
  return ScreenTextExtraction(entries: entries, stats: stats, failures: [], estimatedTimeDisplays: [])
}
@MainActor private func controller(
  _ media: FixtureMedia, _ mic: FixtureMic, _ receipt: TranscriptionReceipt,
  root: URL? = nil, defaults existing: (UserDefaults, String)? = nil,
  screenText: @escaping LifelogScreenTextJob.Extract = fixtureScreenText,
  transcribe: LifelogController.Transcribe? = nil
) throws -> (LifelogController, URL, UserDefaults, String) {
  let root = root ?? TestTemporary.root.appending(path: "unified-\(UUID().uuidString)")
  let name = existing?.1 ?? "unified-tests-\(UUID().uuidString)"
  let defaults = try existing?.0 ?? #require(UserDefaults(suiteName: name))
  if existing == nil {
    var settings = LifelogSettings(); settings.rootPath = root.path; settings.t3Enabled = false
    LifelogSettingsStore.save(settings, to: defaults)
  }
  let controller = LifelogController(defaults: defaults, capture: mic, unified: media,
    displayGate: DisplayCaptureGate(provider: AwakeDesktop()),
    transcribe: transcribe ?? { try await receipt.invoke($0, $1) },
    requestAccess: { true }, transcriptionBlocker: { nil }, digestRequest: { _ in nil }, reservedRoots: { [] },
    extractScreenText: screenText)
  return (controller, root, defaults, name)
}
private func video(_ root: URL, _ segment: LifelogSegment) throws -> URL {
  root.appending(path: try #require(segment.screenRelativeFolder) + "/screen-1.mp4")
}

@Test @MainActor func unifiedSystemSpeechWaitsForFinalizationAndConvertsScreen() async throws {
  let close = MediaLatch(); let media = FixtureMedia(close: close); media.systemSignal = true
  let mic = FixtureMic(); let receipt = TranscriptionReceipt()
  let (c, root, defaults, name) = try controller(media, mic, receipt)
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true)
  #expect(c.phase == .recording)
  c.pauseDisplays()
  #expect(!mic.isRunning && !media.admitted)
  #expect(await receipt.calls == 0)
  let resume = Task { await c.resumeDisplays() }
  for _ in 0..<10 { await Task.yield() }
  #expect(mic.starts == 1) // closed generation must drain before replacement
  await close.open(); await resume.value
  await c.setEnabled(false); await c.waitForTranscriptions(); await c.waitForScreenText()
  #expect(await receipt.calls >= 1)
  let records = c.store.segments(on: c.store.dayKey(Date()))
  #expect(records.contains { $0.segment.transcript?.first?.source == .system })
  #expect(records.allSatisfy { $0.segment.screenRelativeFolder != nil })
  // Audio retention never decides screen files; screen text does.
  #expect(records.allSatisfy { $0.segment.screenText?.status == .complete && $0.segment.screenDeletedAt != nil })
  #expect(!FileManager.default.fileExists(atPath: try video(root, records[0].segment).path))
}

@Test @MainActor func unifiedSilentDesktopConvertsScreenWithoutASR() async throws {
  let media = FixtureMedia(); let receipt = TranscriptionReceipt()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), receipt)
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true)
  let bytesWhileRecording = c.screenBytes
  await c.setEnabled(false); await c.waitForTranscriptions(); await c.waitForScreenText()
  #expect(await receipt.calls == 0)
  let record = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(record.segment.status == .empty)
  #expect(!FileManager.default.fileExists(atPath: c.store.systemAudioURL(in: record.folder).path))
  // Picture content is independent of speech: a silent segment is converted.
  let state = try #require(record.segment.screenText)
  #expect(state.status == .complete && state.deleteRequested == true && state.attempts == 0)
  #expect(state.stats?.keyframes == 2 && state.preview == ["Fixture screen line", "第二行"])
  #expect(record.segment.screenDeletedAt != nil)
  #expect(!FileManager.default.fileExists(atPath: try video(root, record.segment).path))
  #expect(!FileManager.default.fileExists(atPath: c.store.screenFolder(for: record.segment)!.path))
  #expect(FileManager.default.fileExists(atPath: c.store.screenTextMarkdownURL(in: record.folder).path))
  let document = try #require(c.store.screenTextDocument(in: record.folder))
  #expect(document.entries.first?.lines == ["Fixture screen line", "第二行"] && document.segmentID == record.segment.id)
  // The capacity figure counts only the screen subroot, so it drops.
  #expect(bytesWhileRecording > 0 && c.screenBytes == 0)
}

@Test @MainActor func unifiedFailedAndCancelledStartNeverRevivesCapture() async throws {
  let latch = MediaLatch(); let media = FixtureMedia(start: latch); let mic = FixtureMic()
  let (c, root, defaults, name) = try controller(media, mic, TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  let start = Task { await c.setEnabled(true) }
  while !mic.isRunning { await Task.yield() }
  await c.setEnabled(false)
  await latch.open(); await start.value; await c.waitForTranscriptions()
  #expect(c.phase == .off)
  #expect(!mic.isRunning && !media.admitted && media.closed)
  #expect(c.store.segments(on: c.store.dayKey(Date())).count == 1)
}

@Test @MainActor func unifiedStartFailurePreservesSourceAndBlocksRootChange() async throws {
  let media = FixtureMedia(); media.failStart = true
  let (c, root, defaults, name) = try controller(media, FixtureMic(), TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true); await c.waitForCaptureClose()
  let record = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(record.segment.status == .failed)
  #expect(FileManager.default.fileExists(atPath: c.store.audioURL(in: record.folder).path))
  await c.setEnabled(false)
  var changed = c.settings; changed.rootPath += "-other"
  await c.updateSettings(changed)
  #expect(c.settings.rootURL.path == root.path)
}

@Test func displayWakeCannotClearAnIndependentSessionLock() async {
  let gate = DisplayCaptureGate(provider: AwakeDesktop())
  gate.sessionDidResignActive(); gate.screensDidSleep(); gate.screensDidWake()
  #expect(await gate.recheck() == .paused(.sessionInactive))
  gate.sessionDidBecomeActive()
  #expect(await gate.recheck() == .ready)
}

@Test @MainActor func unifiedWriteFailureRetainsPrefixAndRejectsStaleFailure() async throws {
  let media = FixtureMedia(); let mic = FixtureMic()
  let (c, root, defaults, name) = try controller(media, mic, TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true)
  let first = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  let oldRoot = root.appending(path: try #require(first.segment.screenRelativeFolder))
  media.onFailure?(oldRoot, "fixture disk failure")
  for _ in 0..<20 { await Task.yield() }
  await c.waitForCaptureClose()
  #expect(!mic.isRunning)
  #expect(try c.store.load(folder: first.folder).status == .failed)
  #expect(FileManager.default.fileExists(atPath: c.store.systemAudioURL(in: first.folder).path))
  await c.setEnabled(false); await c.setEnabled(true)
  let starts = mic.starts
  media.onFailure?(oldRoot, "late old callback")
  for _ in 0..<20 { await Task.yield() }
  #expect(c.phase == .recording && mic.isRunning && mic.starts == starts)
  await c.setEnabled(false); await c.waitForTranscriptions()
}

@Test @MainActor func unifiedCapacityPausesWithoutRemovingScreenArtifacts() async throws {
  let media = FixtureMedia(); let mic = FixtureMic()
  let (c, root, defaults, name) = try controller(media, mic, TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  var settings = c.settings; settings.screenCapacityGB = 1
  await c.updateSettings(settings)
  await c.setEnabled(true)
  let file = root.appending(path: "screen/fixture-sparse.mp4")
  #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: 1_000_000_000); try handle.close()
  c.tick(); await c.waitForCaptureClose()
  if case .blocked = c.phase {} else { Issue.record("Capacity must block capture") }
  #expect(!mic.isRunning)
  #expect(FileManager.default.fileExists(atPath: file.path))
  await c.setEnabled(false); await c.waitForTranscriptions()
}

private struct ScreenFailure: LocalizedError { var errorDescription: String? { "fixture decode failure" } }

@Test @MainActor func failedScreenTextKeepsVideoAndRetriesOnNextLaunch() async throws {
  let media = FixtureMedia()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), TranscriptionReceipt(),
    screenText: { _, _ in throw ScreenFailure() })
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true); await c.setEnabled(false); await c.waitForTranscriptions(); await c.waitForScreenText()
  let failed = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(failed.segment.screenText?.status == .failed && failed.segment.screenText?.attempts == 1)
  #expect(failed.segment.screenText?.error == "fixture decode failure")
  #expect(failed.segment.screenDeletedAt == nil)
  #expect(FileManager.default.fileExists(atPath: try video(root, failed.segment).path))
  #expect(!FileManager.default.fileExists(atPath: c.store.screenTextURL(in: failed.folder).path))
  #expect(c.todayStats.screenTextFailed == 1)
  // Next launch: same root and preferences, recognition works again.
  let (next, _, _, _) = try controller(FixtureMedia(), FixtureMic(), TranscriptionReceipt(), root: root, defaults: (defaults, name))
  next.activate(observeSystem: false); await next.waitForScreenText()
  let retried = try next.store.load(folder: failed.folder)
  #expect(retried.screenText?.status == .complete && retried.screenDeletedAt != nil)
  #expect(!FileManager.default.fileExists(atPath: try video(root, retried).path))
}

@Test @MainActor func screenTextSwitchOffKeepsVideosButStillRecognizes() async throws {
  let media = FixtureMedia()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  var settings = c.settings; settings.screenTextDeletesVideo = false
  await c.updateSettings(settings)
  #expect(LifelogSettingsStore.load(from: defaults).screenTextDeletesVideo == false)
  await c.setEnabled(true); await c.setEnabled(false); await c.waitForTranscriptions(); await c.waitForScreenText()
  let record = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(record.segment.screenText?.status == .complete && record.segment.screenText?.deleteRequested == false)
  #expect(record.segment.screenDeletedAt == nil)
  #expect(FileManager.default.fileExists(atPath: try video(root, record.segment).path))
  // Turning deletion back on later never deletes already processed videos.
  settings.screenTextDeletesVideo = true
  await c.updateSettings(settings); await c.setEnabled(false)
  #expect(c.store.screenTextRecoveryFolders().isEmpty)
}

@Test @MainActor func quitDuringScreenTextLeavesPendingWorkForNextLaunch() async throws {
  let media = FixtureMedia()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), TranscriptionReceipt(),
    screenText: { _, _ in try await Task.sleep(for: .seconds(600)); throw ScreenFailure() })
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true); await c.setEnabled(false); await c.waitForTranscriptions()
  for _ in 0..<20 { await Task.yield() }
  c.shutdown(); await c.waitForScreenText()
  let pending = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(pending.segment.screenText?.status == .pending && pending.segment.screenText?.attempts == 0)
  #expect(FileManager.default.fileExists(atPath: try video(root, pending.segment).path))
  let (next, _, _, _) = try controller(FixtureMedia(), FixtureMic(), TranscriptionReceipt(), root: root, defaults: (defaults, name))
  next.activate(observeSystem: false); await next.waitForScreenText()
  #expect(try next.store.load(folder: pending.folder).screenText?.status == .complete)
}

@Test @MainActor func capacityPauseResumesAfterScreenSpaceIsFreed() async throws {
  let media = FixtureMedia(); let mic = FixtureMic()
  let (c, root, defaults, name) = try controller(media, mic, TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  var settings = c.settings; settings.screenCapacityGB = 1
  await c.updateSettings(settings)
  await c.setEnabled(true)
  let file = root.appending(path: "screen/fixture-sparse.mp4")
  #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: 1_000_000_000); try handle.close()
  c.tick(); await c.waitForCaptureClose()
  if case .blocked = c.phase {} else { Issue.record("Capacity must block capture") }
  c.tick(); await c.waitForStart()
  if case .blocked = c.phase {} else { Issue.record("Still above the limit: stay blocked") }
  try FileManager.default.removeItem(at: file)
  c.tick(); await c.waitForStart()
  #expect(c.phase == .recording && mic.isRunning)
  await c.setEnabled(false); await c.waitForTranscriptions(); await c.waitForScreenText()
}

private actor AudioGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var open = false
  func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
  func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Test @MainActor func audioAndScreenQueuesNeverOverwriteEachOther() async throws {
  let media = FixtureMedia(); media.systemSignal = true
  let gate = AudioGate()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), TranscriptionReceipt(),
    transcribe: { _, _ in
      await gate.wait()
      return [.init(start: 0, end: 1, speaker: "Unknown", text: "late audio", source: .system)]
    })
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true); await c.setEnabled(false); await c.waitForCaptureClose()
  // Screen text finishes while ASR still holds an older copy of segment.json.
  await c.waitForScreenText()
  let folder = try #require(c.store.segments(on: c.store.dayKey(Date())).first).folder
  #expect(try c.store.load(folder: folder).screenText?.status == .complete)
  await gate.release(); await c.waitForTranscriptions()
  let segment = try c.store.load(folder: folder)
  #expect(segment.status == .complete && segment.transcript?.first?.text == "late audio")
  #expect(segment.screenText?.status == .complete && segment.screenDeletedAt != nil)
}

@Test @MainActor func legacyScreenVideosAreConvertedOnlyOnRequest() async throws {
  let (c, root, defaults, name) = try controller(FixtureMedia(), FixtureMic(), TranscriptionReceipt())
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root)
  var legacy = try store.createSegment(id: UUID(), startedAt: Date())
  legacy.segment.screenRelativeFolder = "screen/\(store.dayKey(Date()))/\(legacy.segment.id.uuidString.lowercased())"
  legacy.segment.status = .empty; legacy.segment.endedAt = Date()
  try store.save(legacy.segment, in: legacy.folder)
  let screen = try #require(store.screenFolder(for: legacy.segment))
  try FileManager.default.createDirectory(at: screen, withIntermediateDirectories: true)
  try Data("legacy".utf8).write(to: screen.appending(path: "screen-1.mp4"))
  c.activate(observeSystem: false); await c.waitForScreenText()
  #expect(try store.load(folder: legacy.folder).screenText == nil)
  #expect(FileManager.default.fileExists(atPath: screen.appending(path: "screen-1.mp4").path))
  #expect(c.legacyScreenSegments == 1)
  c.convertLegacyScreenVideos(); await c.waitForScreenText()
  let converted = try store.load(folder: legacy.folder)
  #expect(converted.screenText?.status == .complete && converted.screenDeletedAt != nil)
  #expect(!FileManager.default.fileExists(atPath: screen.path))
  #expect(c.legacyScreenSegments == 0)
}
