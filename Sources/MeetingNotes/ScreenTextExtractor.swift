@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Fork: converts the per-display screen videos of one closed lifelog segment
/// into timestamped text on this Mac. Frames are decoded in order, compared
/// with the last keyframe through a cheap luminance grid, and only changed
/// frames reach Vision text recognition. Nothing is uploaded.
struct ScreenTextConfiguration: Equatable, Sendable {
  /// At most one decoded frame per interval is analysed (capture is 2 fps).
  var sampleInterval: TimeInterval = 1
  /// Luminance grid used as the frame fingerprint.
  var gridColumns = 64
  var gridRows = 36
  /// A grid cell counts as changed above this luminance difference (0–255).
  var cellThreshold = 16
  /// A frame is new content when at least this share of cells changed
  /// against the last keyframe (0.4 % ≈ 9 of 2304 cells): a moving cursor or
  /// menu-bar clock stays below it, a new line of text or window exceeds it.
  var changedFraction = 0.004
  /// Continuous change (scrolling, video) is recognised at most this often.
  var minimumKeyframeInterval: TimeInterval = 3
  /// Consecutive keyframes of one display are merged into one entry with a
  /// time range when this share of the smaller line set is shared (overlap
  /// coefficient), so a page that only gains lines stays one entry.
  var mergeSimilarity = 0.75
  var minimumConfidence: Float = 0.3
  var recognitionLanguages = ["zh-Hans", "ja-JP", "en-US"]
  /// Probe 2026-10-08: with a fixed zh-Hans/ja-JP/en-US list Vision drops
  /// whole kana lines (or garbles Chinese when ja-JP comes first); per-line
  /// detection reads mixed Chinese/Japanese/English pages correctly.
  var automaticallyDetectsLanguage = true
}

/// Downscaled luminance of one frame, row-major.
struct ScreenFingerprint: Equatable, Sendable {
  let columns: Int
  let rows: Int
  let luma: [UInt8]

  func changedFraction(comparedTo other: ScreenFingerprint, cellThreshold: Int) -> Double {
    guard luma.count == other.luma.count, !luma.isEmpty else { return 1 }
    var changed = 0
    for index in luma.indices where abs(Int(luma[index]) - Int(other.luma[index])) > cellThreshold {
      changed += 1
    }
    return Double(changed) / Double(luma.count)
  }

  /// Averages a 3×3 point sample per cell of a 32BGRA buffer.
  static func make(_ pixels: CVPixelBuffer, columns: Int, rows: Int) -> ScreenFingerprint? {
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    guard width > 0, height > 0 else { return nil }
    var luma = [UInt8](repeating: 0, count: columns * rows)
    for row in 0..<rows {
      for column in 0..<columns {
        var sum = 0
        for sy in 1...3 {
          let y = min(height - 1, (row * 4 + sy) * height / (rows * 4))
          for sx in 1...3 {
            let x = min(width - 1, (column * 4 + sx) * width / (columns * 4))
            let pixel = base + y * stride + x * 4
            sum += (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
          }
        }
        luma[row * columns + column] = UInt8(sum / 9)
      }
    }
    return ScreenFingerprint(columns: columns, rows: rows, luma: luma)
  }
}

/// Decides which decoded frames are analysed and which become keyframes.
struct ScreenKeyframeSelector: Sendable {
  let configuration: ScreenTextConfiguration
  private var lastKeyframe: ScreenFingerprint?
  private var lastKeyframeTime = -TimeInterval.infinity
  private var lastSampleTime = -TimeInterval.infinity

  init(configuration: ScreenTextConfiguration) { self.configuration = configuration }

  /// Small tolerance for capture timestamp jitter around the 0.5 s cadence.
  mutating func wantsSample(at time: TimeInterval) -> Bool {
    guard time + 0.05 >= lastSampleTime + configuration.sampleInterval else { return false }
    lastSampleTime = time
    return true
  }

  /// Compares with the last keyframe, never the previous frame, so slow
  /// accumulated change is still caught.
  mutating func isKeyframe(_ fingerprint: ScreenFingerprint, at time: TimeInterval) -> Bool {
    if let lastKeyframe {
      guard time - lastKeyframeTime >= configuration.minimumKeyframeInterval,
        fingerprint.changedFraction(comparedTo: lastKeyframe, cellThreshold: configuration.cellThreshold)
          >= configuration.changedFraction
      else { return false }
    }
    lastKeyframe = fingerprint
    lastKeyframeTime = time
    return true
  }
}

/// One recognised text box; `box` is Vision's normalised rectangle with the
/// origin at the bottom left.
struct ScreenTextObservation: Equatable, Sendable {
  var text: String
  var box: CGRect
  var confidence: Float
}

enum ScreenTextLayout {
  /// Top-to-bottom rows, left-to-right within a row, one line per box. Boxes
  /// are not joined across columns, so side-by-side windows never interleave
  /// within one line. Blank, low-confidence and repeated lines are dropped.
  static func readingOrder(_ observations: [ScreenTextObservation], minimumConfidence: Float) -> [String] {
    let kept = observations.filter {
      $0.confidence >= minimumConfidence && !normalized($0.text).isEmpty
    }.sorted { $0.box.midY > $1.box.midY }
    var rows: [[ScreenTextObservation]] = []
    for observation in kept {
      if let last = rows.last?.last,
        abs(last.box.midY - observation.box.midY) < min(last.box.height, observation.box.height) / 2
      {
        rows[rows.count - 1].append(observation)
      } else {
        rows.append([observation])
      }
    }
    var seen = Set<String>()
    return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }.compactMap {
      let line = normalized($0.text)
      return seen.insert(key(line)).inserted ? line : nil
    }
  }

  static func normalized(_ line: String) -> String {
    line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Comparison key: Vision is inconsistent about spaces between CJK and
  /// Latin text ("019 行" / "019行"), so whitespace and case are ignored.
  static func key(_ line: String) -> String {
    line.filter { !$0.isWhitespace }.lowercased()
  }

  /// Overlap coefficient of two line sets: |A ∩ B| / min(|A|, |B|).
  static func similarity(_ first: [String], _ second: [String]) -> Double {
    let a = Set(first.map(key)), b = Set(second.map(key))
    let smaller = min(a.count, b.count)
    return smaller == 0 ? 0 : Double(a.intersection(b).count) / Double(smaller)
  }
}

enum ScreenTextTiming {
  /// The video writer starts its session at the first frame's source time, so
  /// differences between presentation times are wall-clock differences from
  /// the recorded first frame.
  static func absolute(frameSeconds: Double, firstFrameSeconds: Double, firstFrameAt: Date) -> Date {
    firstFrameAt + max(0, frameSeconds - firstFrameSeconds)
  }
}

/// One stretch of similar on-screen text of one display.
struct ScreenTextEntry: Codable, Equatable, Sendable {
  var displayID: UInt32
  var startedAt: Date
  var endedAt: Date
  /// Seconds from the segment start.
  var startOffset: TimeInterval
  var endOffset: TimeInterval
  var keyframes: Int
  var lines: [String]

  var characterCount: Int { lines.map(\.count).reduce(0, +) }
}

struct ScreenTextMerger {
  let similarity: Double
  private var open: [UInt32: (entry: ScreenTextEntry, last: [String])] = [:]
  private var closed: [ScreenTextEntry] = []

  init(similarity: Double) { self.similarity = similarity }

  mutating func add(displayID: UInt32, at date: Date, offset: TimeInterval, lines: [String]) {
    guard !lines.isEmpty else { return }
    if var current = open[displayID], ScreenTextLayout.similarity(current.last, lines) >= similarity {
      current.entry.endedAt = date
      current.entry.endOffset = offset
      current.entry.keyframes += 1
      var known = Set(current.entry.lines.map(ScreenTextLayout.key))
      current.entry.lines += lines.filter { known.insert(ScreenTextLayout.key($0)).inserted }
      current.last = lines
      open[displayID] = current
      return
    }
    if let previous = open[displayID] { closed.append(previous.entry) }
    open[displayID] = (ScreenTextEntry(displayID: displayID, startedAt: date, endedAt: date,
      startOffset: offset, endOffset: offset, keyframes: 1, lines: lines), lines)
  }

  mutating func finish() -> [ScreenTextEntry] {
    let all = closed + open.values.map(\.entry)
    open = [:]
    closed = []
    return all.sorted { ($0.startedAt, $0.displayID) < ($1.startedAt, $1.displayID) }
  }
}

struct ScreenTextVideo: Equatable, Sendable {
  var displayID: UInt32
  var url: URL
  /// nil when the writer metadata is missing; times then start at the
  /// segment start and the display is reported as estimated.
  var firstFrameAt: Date?
}

struct ScreenTextStats: Codable, Equatable, Sendable {
  var displays = 0
  /// Every decoded video frame.
  var totalFrames = 0
  /// Frames fingerprinted after the sample interval.
  var sampledFrames = 0
  /// Frames sent to text recognition.
  var keyframes = 0
  var entries = 0
  var characters = 0
  /// Keyframes whose recognition failed.
  var failures = 0
  /// Time spent inside Vision recognition.
  var ocrSeconds: Double = 0
  /// Decode, fingerprint and recognition wall time.
  var processingSeconds: Double = 0
}

struct ScreenTextExtraction: Equatable, Sendable {
  var entries: [ScreenTextEntry]
  var stats: ScreenTextStats
  var failures: [String]
  var estimatedTimeDisplays: [UInt32]
}

enum ScreenTextExtractor {
  typealias Recognize = @Sendable (CVPixelBuffer) throws -> [ScreenTextObservation]

  /// Throws when a video cannot be read (the caller keeps it); per-keyframe
  /// recognition errors are counted in `stats.failures` instead.
  static func extract(
    videos: [ScreenTextVideo], segmentStart: Date,
    configuration: ScreenTextConfiguration = ScreenTextConfiguration(),
    recognize: Recognize? = nil
  ) async throws -> ScreenTextExtraction {
    let recognize = recognize ?? visionRecognizer(configuration)
    let clock = ContinuousClock()
    let started = clock.now
    var stats = ScreenTextStats()
    var failures: [String] = []
    var estimated: [UInt32] = []
    var merger = ScreenTextMerger(similarity: configuration.mergeSimilarity)
    for video in videos.sorted(by: { $0.displayID < $1.displayID }) {
      stats.displays += 1
      if video.firstFrameAt == nil { estimated.append(video.displayID) }
      let firstFrameAt = video.firstFrameAt ?? segmentStart
      let asset = AVURLAsset(url: video.url)
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      ])
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
      reader.add(output)
      guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
      var selector = ScreenKeyframeSelector(configuration: configuration)
      var firstSeconds: Double?
      while let sample = output.copyNextSampleBuffer() {
        if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
        stats.totalFrames += 1
        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard seconds.isFinite else { continue }
        let first = firstSeconds ?? seconds
        firstSeconds = first
        guard selector.wantsSample(at: seconds - first) else { continue }
        stats.sampledFrames += 1
        guard let fingerprint = ScreenFingerprint.make(pixels, columns: configuration.gridColumns, rows: configuration.gridRows),
          selector.isKeyframe(fingerprint, at: seconds - first)
        else { continue }
        stats.keyframes += 1
        let date = ScreenTextTiming.absolute(frameSeconds: seconds, firstFrameSeconds: first, firstFrameAt: firstFrameAt)
        let ocrStarted = clock.now
        do {
          let lines = ScreenTextLayout.readingOrder(try recognize(pixels), minimumConfidence: configuration.minimumConfidence)
          merger.add(displayID: video.displayID, at: date, offset: date.timeIntervalSince(segmentStart), lines: lines)
        } catch {
          stats.failures += 1
          failures.append("Display \(video.displayID) at \(date.ISO8601Format()): \(error.localizedDescription)")
        }
        stats.ocrSeconds += elapsed(ocrStarted.duration(to: clock.now))
        // Recognition is synchronous; let other work use this thread.
        await Task.yield()
      }
      if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }
    let entries = merger.finish()
    stats.entries = entries.count
    stats.characters = entries.map(\.characterCount).reduce(0, +)
    stats.processingSeconds = elapsed(started.duration(to: clock.now))
    return ScreenTextExtraction(entries: entries, stats: stats, failures: failures, estimatedTimeDisplays: estimated)
  }

  static func visionRecognizer(_ configuration: ScreenTextConfiguration) -> Recognize {
    { pixels in
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = configuration.recognitionLanguages
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
      try VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
      return (request.results ?? []).compactMap { observation in
        observation.topCandidates(1).first.map {
          ScreenTextObservation(text: $0.string, box: observation.boundingBox, confidence: $0.confidence)
        }
      }
    }
  }

  private static func elapsed(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
