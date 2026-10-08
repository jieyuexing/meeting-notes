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
@MainActor private func controller(_ media: FixtureMedia, _ mic: FixtureMic, _ receipt: TranscriptionReceipt) throws -> (LifelogController, URL, UserDefaults, String) {
  let root = TestTemporary.root.appending(path: "unified-\(UUID().uuidString)")
  let name = "unified-tests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  var settings = LifelogSettings(); settings.rootPath = root.path; settings.t3Enabled = false
  LifelogSettingsStore.save(settings, to: defaults)
  let controller = LifelogController(defaults: defaults, capture: mic, unified: media,
    displayGate: DisplayCaptureGate(provider: AwakeDesktop()), transcribe: { try await receipt.invoke($0, $1) },
    requestAccess: { true }, transcriptionBlocker: { nil }, digestRequest: { _ in nil }, reservedRoots: { [] })
  return (controller, root, defaults, name)
}

@Test @MainActor func unifiedSystemSpeechWaitsForFinalizationAndRetainsScreen() async throws {
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
  await c.setEnabled(false); await c.waitForTranscriptions()
  #expect(await receipt.calls >= 1)
  let records = c.store.segments(on: c.store.dayKey(Date()))
  #expect(records.contains { $0.segment.transcript?.first?.source == .system })
  #expect(records.allSatisfy { $0.segment.screenRelativeFolder != nil })
  #expect(FileManager.default.fileExists(atPath: root.appending(path: records[0].segment.screenRelativeFolder! + "/screen-1.mp4").path))
}

@Test @MainActor func unifiedSilentDesktopKeepsArtifactsWithoutASR() async throws {
  let media = FixtureMedia(); let receipt = TranscriptionReceipt()
  let (c, root, defaults, name) = try controller(media, FixtureMic(), receipt)
  defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
  await c.setEnabled(true); await c.setEnabled(false); await c.waitForTranscriptions()
  #expect(await receipt.calls == 0)
  let record = try #require(c.store.segments(on: c.store.dayKey(Date())).first)
  #expect(record.segment.status == .empty)
  #expect(FileManager.default.fileExists(atPath: root.appending(path: record.segment.screenRelativeFolder! + "/screen-1.mp4").path))
  #expect(!FileManager.default.fileExists(atPath: c.store.systemAudioURL(in: record.folder).path))
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
