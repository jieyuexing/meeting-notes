@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MeetingNotes

private func fingerprint(_ value: UInt8, changed: Int = 0, to other: UInt8 = 0) -> ScreenFingerprint {
  let configuration = ScreenTextConfiguration()
  var luma = [UInt8](repeating: value, count: configuration.gridColumns * configuration.gridRows)
  for index in 0..<changed { luma[index] = other }
  return ScreenFingerprint(columns: configuration.gridColumns, rows: configuration.gridRows, luma: luma)
}

@Test func keyframeSelectorDropsIdenticalAndSlightChangesButKeepsClearChanges() {
  var selector = ScreenKeyframeSelector(configuration: ScreenTextConfiguration())
  func sample(_ time: TimeInterval) -> Bool { selector.wantsSample(at: time) }
  func key(_ value: ScreenFingerprint, _ time: TimeInterval) -> Bool { selector.isKeyframe(value, at: time) }
  // 2 fps input is analysed at most once per sampleInterval (1 s).
  #expect(sample(0))
  #expect(key(fingerprint(100), 0))
  #expect(!sample(0.5))
  #expect(sample(1))
  // Identical frame.
  #expect(!key(fingerprint(100), 1))
  // Global luminance drift below the per-cell threshold (16).
  #expect(!key(fingerprint(110), 4))
  // Slight change: 5 of 2304 cells (0.22% < 0.4%), e.g. cursor or clock.
  #expect(!key(fingerprint(100, changed: 5, to: 200), 5))
  // Clear change: 200 cells (8.7%) after the minimum interval.
  #expect(key(fingerprint(100, changed: 200, to: 200), 6))
  // A clear change too soon after a keyframe waits for the minimum interval
  // (3 s) and is then compared against the last keyframe again.
  #expect(!key(fingerprint(0), 7))
  #expect(key(fingerprint(0), 9))
  // Slow accumulation is measured against the last keyframe, not the
  // previous frame: 5, 7, then 10 changed cells finally cross 0.4%.
  #expect(!key(fingerprint(0, changed: 5, to: 255), 20))
  #expect(!key(fingerprint(0, changed: 7, to: 255), 21))
  #expect(key(fingerprint(0, changed: 10, to: 255), 22))
}

@Test func screenTextTimingMapsVideoTimeToFirstFrameAndSegmentStart() {
  let segmentStart = Date(timeIntervalSince1970: 1_791_417_600)
  let firstFrameAt = segmentStart + 1.5
  let absolute = ScreenTextTiming.absolute(frameSeconds: 47, firstFrameSeconds: 10, firstFrameAt: firstFrameAt)
  #expect(absolute == segmentStart + 38.5)
  #expect(absolute.timeIntervalSince(segmentStart) == 38.5)
}

@Test func readingOrderSortsRowsDropsDuplicatesAndLowConfidence() {
  func observation(_ text: String, x: Double, y: Double, confidence: Float = 0.9) -> ScreenTextObservation {
    ScreenTextObservation(text: text, box: CGRect(x: x, y: y, width: 0.2, height: 0.04), confidence: confidence)
  }
  // Vision boxes are normalised with the origin at the bottom left.
  let lines = ScreenTextLayout.readingOrder([
    observation("third", x: 0.1, y: 0.40),
    observation("second right", x: 0.6, y: 0.705),
    observation("first", x: 0.1, y: 0.90),
    observation("second left", x: 0.1, y: 0.70),
    observation("  first ", x: 0.5, y: 0.20),
    observation("THIRD", x: 0.5, y: 0.15),
    observation("noise", x: 0.3, y: 0.30, confidence: 0.1),
    observation("   ", x: 0.3, y: 0.10),
  ], minimumConfidence: 0.3)
  #expect(lines == ["first", "second left", "second right", "third"])
}

@Test func mergerCombinesRepeatedTextIntoRangesPerDisplay() {
  let start = Date(timeIntervalSince1970: 1_791_417_600)
  var merger = ScreenTextMerger(similarity: 0.75)
  merger.add(displayID: 1, at: start + 10, offset: 10, lines: ["Inbox", "Message A", "Message B", "Message C"])
  // A page that only gains a line is merged; the new line is kept once.
  merger.add(displayID: 1, at: start + 20, offset: 20, lines: ["Inbox", "Message A", "Message B", "Message C", "Message D"])
  merger.add(displayID: 1, at: start + 30, offset: 30, lines: ["Inbox", "Message A", "Message B", "Message C", "Message D"])
  // Another display never merges into display 1.
  merger.add(displayID: 2, at: start + 25, offset: 25, lines: ["Inbox", "Message A", "Message B", "Message C", "Message D"])
  // Different content starts a new entry; blank keyframes are ignored.
  merger.add(displayID: 1, at: start + 40, offset: 40, lines: [])
  merger.add(displayID: 1, at: start + 50, offset: 50, lines: ["Editor", "func main()"])
  // Sharing only 1 of 3 lines (e.g. a window title) is not a repeat.
  merger.add(displayID: 1, at: start + 60, offset: 60, lines: ["Editor", "README.md", "# Title"])
  let entries = merger.finish()
  #expect(entries.count == 4)
  #expect(entries[0].displayID == 1 && entries[0].startedAt == start + 10 && entries[0].endedAt == start + 30)
  #expect(entries[0].startOffset == 10 && entries[0].endOffset == 30 && entries[0].keyframes == 3)
  #expect(entries[0].lines == ["Inbox", "Message A", "Message B", "Message C", "Message D"])
  #expect(entries[1].displayID == 2 && entries[1].keyframes == 1)
  #expect(entries[2].lines == ["Editor", "func main()"] && entries[2].startOffset == 50)
  #expect(entries[3].lines == ["Editor", "README.md", "# Title"])
  #expect(ScreenTextLayout.similarity(["a", "b", "c", "d"], ["a", "b", "c", "x", "y"]) == 0.75)
  // CJK/Latin spacing differences between frames are the same line.
  #expect(ScreenTextLayout.similarity(["019 行：log line 19 状态"], ["019行：log line 19状态"]) == 1)
}

/// Writes a real H.264 MP4 the way the production writer does: the session
/// starts at the first frame's source timestamp, which is not zero.
private func writeFixtureVideo(_ url: URL, frames: [UInt8], firstSeconds: Int64 = 10) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
  ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
  ])
  writer.add(input)
  #expect(writer.startWriting())
  let first = CMTime(value: firstSeconds * 2, timescale: 2)
  writer.startSession(atSourceTime: first)
  for (index, value) in frames.enumerated() {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    memset(CVPixelBufferGetBaseAddress(pixels), Int32(value), CVPixelBufferGetDataSize(pixels))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    #expect(adaptor.append(pixels, withPresentationTime: first + CMTime(value: Int64(index), timescale: 2)))
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

@Test func extractorDecodesRealVideoDedupesFramesAndMapsTimes() async throws {
  let folder = TestTemporary.root.appending(path: "screen-text-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let video = folder.appending(path: "screen-7.mp4")
  // 6 s white then 4 s black at 2 fps: 20 frames, two distinct screens.
  try await writeFixtureVideo(video, frames: Array(repeating: 255, count: 12) + Array(repeating: 0, count: 8))
  let segmentStart = Date(timeIntervalSince1970: 1_791_417_600)
  let recognize: ScreenTextExtractor.Recognize = { pixels in
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let center = base[90 * CVPixelBufferGetBytesPerRow(pixels) + 160 * 4]
    return [ScreenTextObservation(text: center > 128 ? "WHITE 白 白い" : "BLACK", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05), confidence: 1)]
  }
  let result = try await ScreenTextExtractor.extract(
    videos: [ScreenTextVideo(displayID: 7, url: video, firstFrameAt: segmentStart + 2)],
    segmentStart: segmentStart, recognize: recognize)
  #expect(result.stats.totalFrames == 20)
  #expect(result.stats.sampledFrames == 10)
  #expect(result.stats.keyframes == 2)
  #expect(result.stats.failures == 0)
  #expect(result.entries.map(\.lines) == [["WHITE 白 白い"], ["BLACK"]])
  #expect(result.entries.map(\.displayID) == [7, 7])
  #expect(result.entries[0].startedAt == segmentStart + 2)
  #expect(result.entries[1].startedAt == segmentStart + 8)
  #expect(result.entries[1].startOffset == 8)
  #expect(result.stats.characters == "WHITE 白 白い".count + "BLACK".count)
  #expect(result.estimatedTimeDisplays.isEmpty)
}

@Test func extractorCountsRecognitionFailuresAndRejectsUnreadableVideo() async throws {
  let folder = TestTemporary.root.appending(path: "screen-text-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let video = folder.appending(path: "screen-1.mp4")
  try await writeFixtureVideo(video, frames: [255, 255, 255, 255])
  struct Broken: Error {}
  let failing = try await ScreenTextExtractor.extract(
    videos: [ScreenTextVideo(displayID: 1, url: video, firstFrameAt: nil)],
    segmentStart: Date(timeIntervalSince1970: 0), recognize: { _ in throw Broken() })
  #expect(failing.stats.failures == 1)
  #expect(failing.failures.count == 1)
  // Missing first-frame metadata falls back to the segment start, flagged.
  #expect(failing.estimatedTimeDisplays == [1])
  let corrupt = folder.appending(path: "screen-2.mp4")
  try Data("not a movie".utf8).write(to: corrupt)
  await #expect(throws: (any Error).self) {
    _ = try await ScreenTextExtractor.extract(
      videos: [ScreenTextVideo(displayID: 2, url: corrupt, firstFrameAt: nil)],
      segmentStart: Date(timeIntervalSince1970: 0), recognize: { _ in [] })
  }
}

/// Opt-in real path: decode → dedupe → Vision OCR → `screen-text.*` → video
/// deletion, on a copy of a synthetic MP4. Skipped unless both absolute
/// variables are set: `MEETING_NOTES_SCREEN_OCR_VIDEO` (source MP4, never
/// modified) and `MEETING_NOTES_SCREEN_OCR_OUT` (new lifelog root for results).
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_NOTES_SCREEN_OCR_VIDEO"] != nil))
@MainActor func screenTextVisionProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  let source = try #require(environment["MEETING_NOTES_SCREEN_OCR_VIDEO"])
  let output = try #require(environment["MEETING_NOTES_SCREEN_OCR_OUT"])
  #expect(source.hasPrefix("/") && output.hasPrefix("/"))
  let store = LifelogStore(root: URL(fileURLWithPath: output, isDirectory: true)
    .appending(path: "lifelog-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory))
  let started = Date()
  var item = try store.createSegment(id: UUID(), startedAt: started)
  item.segment.screenRelativeFolder = "screen/\(store.dayKey(started))/\(item.segment.id.uuidString.lowercased())"
  item.segment.screenText = .pending
  item.segment.status = .empty
  item.segment.endedAt = started
  item.segment.media = UnifiedCaptureMetadata(startedAt: started, endedAt: started, systemAudioFile: "system.wav",
    displays: [.init(displayID: 1, videoFile: "screen-1.mp4", actualFirstFrameAt: started, endedAt: started, droppedFrames: 0, failure: nil)],
    gaps: [], failure: nil)
  try store.save(item.segment, in: item.folder)
  let screen = try #require(store.screenFolder(for: item.segment))
  try FileManager.default.createDirectory(at: screen, withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: screen.appending(path: "screen-1.mp4"))
  let clock = ContinuousClock()
  let begin = clock.now
  let outcome = await LifelogScreenTextJob.run(store: store, folder: item.folder, deleteVideos: true,
    extract: LifelogScreenTextJob.defaultExtract)
  let wall = begin.duration(to: clock.now)
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  let segment = try store.load(folder: item.folder)
  let stats = try #require(segment.screenText?.stats)
  print("SCREEN_OCR_PROBE outcome=\(outcome) wall=\(wall) frames=\(stats.totalFrames) sampled=\(stats.sampledFrames) keyframes=\(stats.keyframes) entries=\(stats.entries) characters=\(stats.characters) failures=\(stats.failures) ocrSeconds=\(stats.ocrSeconds) processingSeconds=\(stats.processingSeconds) maxRSSBytes=\(usage.ru_maxrss) userCPU=\(usage.ru_utime.tv_sec).\(usage.ru_utime.tv_usec) systemCPU=\(usage.ru_stime.tv_sec).\(usage.ru_stime.tv_usec)")
  print("SCREEN_OCR_PROBE folder=\(item.folder.path) videoDeleted=\(!FileManager.default.fileExists(atPath: screen.path)) screenDeletedAt=\(segment.screenDeletedAt.map { $0.ISO8601Format() } ?? "nil")")
  #expect(outcome == .complete)
  #expect(segment.screenDeletedAt != nil)
}
