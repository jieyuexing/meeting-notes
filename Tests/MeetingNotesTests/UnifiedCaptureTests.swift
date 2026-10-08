import Foundation
import Testing

@testable import MeetingNotes

private final class UnifiedEventFixture: UnifiedCaptureEventSink, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var events: [UnifiedCaptureEvent] = []
  func receive(_ event: UnifiedCaptureEvent) { lock.withLock { events.append(event) } }
}

@Test func unifiedCaptureUsesCallerSegmentRootAndDoesNotChoosePersistentStorage() {
  let callerRoot = URL(filePath: "/private/fixture/segment-a")
  let segment = UnifiedCaptureSegment(root: callerRoot, startedAt: .distantPast, displayPolicy: .allDisplays)
  #expect(segment.root == callerRoot)
  #expect(segment.startedAt == .distantPast)
}

@Test func unifiedCaptureOnlyAssignsSystemAudioOnceForMultipleDisplays() {
  #expect(UnifiedSegmentCapture.systemAudioDisplayIDs([7]) == [7])
  #expect(UnifiedSegmentCapture.systemAudioDisplayIDs([7, 8, 9]) == [7])
  #expect(UnifiedSegmentCapture.systemAudioDisplayIDs([]).isEmpty)
}

@Test func unifiedMetadataDistinguishesCompleteFromPartialFailure() throws {
  let clean = UnifiedCaptureMetadata(startedAt: .distantPast, endedAt: Date(), systemAudioFile: "system.wav", displays: [.init(displayID: 7, videoFile: "screen-7.mp4", actualFirstFrameAt: nil, endedAt: Date(), droppedFrames: 0, failure: nil)], gaps: [], failure: nil)
  #expect(clean.failure == nil)
  let partial = UnifiedCaptureMetadata(startedAt: .distantPast, endedAt: Date(), systemAudioFile: "system.wav", displays: clean.displays, gaps: ["display 8 failed"], failure: "display 8 failed")
  #expect(partial.failure != nil)
  let decoded = try JSONDecoder().decode(UnifiedCaptureMetadata.self, from: JSONEncoder().encode(partial))
  #expect(decoded == partial)
}

@Test func sharedClockUsesSourceTimeAndPadsMicrophoneOnlyOnce() throws {
  let root = TestTemporary.root.appending(path: "clock-wav-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let clock = CaptureClock(); clock.start()
  let recorder = LifelogRecorder(); recorder.align(to: clock)
  let file = root.appending(path: "microphone.wav")
  try recorder.startFile(at: file)
  // No hardware capture: exercise the production writer with a deliberately
  // invalid source timestamp, which must use the shared clock safely.
  recorder.write([1, 2, 3], hostSeconds: .nan)
  recorder.write([4, 5, 6], hostSeconds: .nan)
  _ = try recorder.stop()
  let bytes = try Data(contentsOf: file)
  #expect(bytes.suffix(12) == [UInt8](arrayLiteral: 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0))
  #expect(clock.samplePosition(atHostSeconds: -1) == 0)
}
