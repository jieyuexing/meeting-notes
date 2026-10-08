import FluidAudio
import Foundation
import os

/// Fork: optional final-only engine (FORK.md「SenseVoice 最终转写」).
///
/// SenseVoice-Small is non-streaming, has a ~108 s window and returns no
/// timestamps. Each track is therefore split by Silero VAD, every speech
/// segment is transcribed on its own, and the segment bounds become the turn
/// times — timestamps are segment-level, not token-level. Models load from
/// FluidAudio's local cache and are downloaded only on first use; audio never
/// leaves this Mac.
actor SenseVoiceTranscriber {
  static let logger = Logger(subsystem: "app.meetingnotes.menu", category: "SenseVoiceTranscriber")

  /// `withitn` (14): punctuation plus Arabic numerals. The 2026-10-08
  /// comparison showed its only differences from `woitn` were number formats,
  /// while punctuation keeps transcript lines, sentence merging and the
  /// summary input readable.
  static let textNorm: Int32 = 14
  /// `0` lets SenseVoice identify the language.
  static let language: Int32 = 0
  static let vadConfig = VadSegmentationConfig(maxSpeechDuration: 30)

  private struct Models {
    let asr: SenseVoiceManager
    let vad: VadManager
  }

  private var models: Models?
  private var loadingTask: Task<Models, Error>?

  func prepare() async throws {
    _ = try await loadedModels()
  }

  private func loadedModels() async throws -> Models {
    if let models { return models }
    if let loadingTask { return try await loadingTask.value }
    let started = ContinuousClock.now
    let task = Task {
      let senseVoice = try await SenseVoiceModels.downloadAndLoad(precision: .fp16)
      let vad = try await VadManager()
      return Models(
        asr: SenseVoiceManager(
          models: senseVoice, language: Self.language, textNorm: Self.textNorm),
        vad: vad)
    }
    loadingTask = task
    do {
      let loaded = try await task.value
      models = loaded
      loadingTask = nil
      Self.logger.info("SenseVoice ready in \(started.duration(to: .now), privacy: .public)")
      return loaded
    } catch {
      loadingTask = nil
      Self.logger.error(
        "SenseVoice load failed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }

  func transcribe(_ url: URL) async throws -> NemotronTranscriber.Result {
    try Task.checkCancellation()
    let models = try await loadedModels()
    let reader = try PCM16WavReader(url: url)
    let total = reader.sampleCount
    var segments: [NemotronTranscriber.Segment] = []
    var foundSpeech = false
    var blockStart = 0
    do {
      while blockStart < total {
        try Task.checkCancellation()
        let count = min(SenseVoiceSegmentation.blockSamples, total - blockStart)
        let block = try reader.samples(from: blockStart, count: count)
        let speech = try await models.vad.segmentSpeech(block, config: Self.vadConfig).map {
          $0.startSample(sampleRate: SenseVoiceSegmentation.sampleRate)
            ..< $0.endSample(sampleRate: SenseVoiceSegmentation.sampleRate)
        }
        let step = SenseVoiceSegmentation.step(
          speech: speech, blockStart: blockStart, blockCount: count,
          isLast: blockStart + count >= total)
        foundSpeech = foundSpeech || !step.segments.isEmpty
        let pieces = step.segments.flatMap { SenseVoiceSegmentation.forcedSplit($0) }
        let windows = SenseVoiceSegmentation.contextWindows(
          pieces, within: blockStart..<min(blockStart + block.count, step.nextStart))
        for (range, window) in zip(pieces, windows) {
          try Task.checkCancellation()
          let lower = window.lowerBound - blockStart
          let upper = min(window.upperBound - blockStart, block.count)
          guard lower < upper else { continue }
          let text = SenseVoiceText.clean(
            try await models.asr.transcribe(audio: Array(block[lower..<upper])))
          if !text.isEmpty {
            segments.append(
              .init(
                start: SenseVoiceSegmentation.seconds(range.lowerBound),
                end: SenseVoiceSegmentation.seconds(range.upperBound), text: text))
          }
        }
        blockStart = step.nextStart
      }
      // The engine only calls this for tracks with a real signal. If VAD
      // still finds no speech, fall back to fixed windows instead of dropping
      // quiet audio that Nemotron would have transcribed.
      if !foundSpeech {
        for range in SenseVoiceSegmentation.forcedSplit(0..<total) {
          try Task.checkCancellation()
          let text = SenseVoiceText.clean(
            try await models.asr.transcribe(
              audio: reader.samples(from: range.lowerBound, count: range.count)))
          if !text.isEmpty {
            segments.append(
              .init(
                start: SenseVoiceSegmentation.seconds(range.lowerBound),
                end: SenseVoiceSegmentation.seconds(range.upperBound), text: text))
          }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      Self.logger.error(
        "SenseVoice transcription failed: \(String(describing: error), privacy: .public)")
      throw error
    }
    return Self.archiveResult(
      segments: segments, duration: SenseVoiceSegmentation.seconds(total),
      correcting: VocabularyTextCorrector.apply)
  }

  /// Applies the vocabulary per segment. A replacement spanning two VAD
  /// segments is not applied; segments are separated by silence.
  nonisolated static func archiveResult(
    segments: [NemotronTranscriber.Segment], duration: TimeInterval,
    correcting: (String) -> String
  ) -> NemotronTranscriber.Result {
    let corrected = segments.compactMap { segment -> NemotronTranscriber.Segment? in
      let text = correcting(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty
        ? nil : .init(start: segment.start, end: min(segment.end, duration), text: text)
    }
    return .init(
      text: corrected.map(\.text).joined(separator: " "), duration: duration,
      segments: corrected)
  }
}

/// Removes model meta tags (`<|ja|><|NEUTRAL|><|Speech|><|withitn|>`) and
/// SentencePiece leftovers from SenseVoice output. Spaces between Chinese or
/// Japanese characters (and digits next to them) are dropped; Korean and
/// Latin word spacing is kept.
enum SenseVoiceText {
  static func clean(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: #"<\|[^|<>]*\|>"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\u{2581}", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(
        of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、「」『』（）]) (?=[\p{Han}\p{Hiragana}\p{Katakana}])"#,
        with: "", options: .regularExpression)
      .replacingOccurrences(
        of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}]) (?=[0-9])|(?<=[0-9]) (?=[\p{Han}\p{Hiragana}\p{Katakana}])"#,
        with: "", options: .regularExpression)
      .replacingOccurrences(of: #" (?=[,.!?;:，。！？；：、）」』])"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// VAD block planning for SenseVoice. All values are 16 kHz sample indices.
enum SenseVoiceSegmentation {
  static let sampleRate = 16_000
  /// Forced split above 90 s, below SenseVoice's ~107.8 s (1800 LFR frames)
  /// window, which FluidAudio otherwise truncates with only a log line.
  static let maximumSegmentSamples = 90 * sampleRate
  /// VAD runs on 10-minute blocks so a long meeting is never held in memory
  /// as one float array.
  static let blockSamples = 10 * 60 * sampleRate
  /// A segment ending this close to a block end is treated as still spoken.
  static let blockEdgeTolerance = sampleRate
  /// Audio added around each VAD segment before recognition; the turn keeps
  /// the VAD bounds. Tight VAD crops made the first syllable unstable on the
  /// retained sample (FORK.md); the context never reaches past half the gap
  /// to a neighbouring segment, so no speech is recognized twice.
  static let contextSamples = sampleRate * 2 / 5

  struct Step: Equatable {
    let segments: [Range<Int>]
    let nextStart: Int
  }

  static func seconds(_ samples: Int) -> TimeInterval {
    Double(samples) / Double(sampleRate)
  }

  /// `speech` holds VAD ranges relative to the block. A final segment that
  /// reaches the block end is deferred so the next block starts at its
  /// beginning, unless it already began at the block start (or this is the
  /// last block); this keeps speech crossing a block edge in one piece and
  /// always advances.
  static func step(speech: [Range<Int>], blockStart: Int, blockCount: Int, isLast: Bool) -> Step {
    let blockEnd = blockStart + blockCount
    let absolute = speech.map { (blockStart + $0.lowerBound)..<(blockStart + $0.upperBound) }
    guard !isLast, let last = absolute.last, last.upperBound >= blockEnd - blockEdgeTolerance,
      last.lowerBound > blockStart
    else { return Step(segments: absolute, nextStart: blockEnd) }
    return Step(segments: Array(absolute.dropLast()), nextStart: last.lowerBound)
  }

  /// Recognition windows for consecutive, non-overlapping `segments`.
  static func contextWindows(
    _ segments: [Range<Int>], within bounds: Range<Int>, context: Int = contextSamples
  ) -> [Range<Int>] {
    segments.indices.map { index in
      let segment = segments[index]
      let before =
        index > 0
        ? (segment.lowerBound - segments[index - 1].upperBound) / 2
        : segment.lowerBound - bounds.lowerBound
      let after =
        index + 1 < segments.count
        ? (segments[index + 1].lowerBound - segment.upperBound) / 2
        : bounds.upperBound - segment.upperBound
      return max(bounds.lowerBound, segment.lowerBound - min(context, max(0, before)))
        ..< min(bounds.upperBound, segment.upperBound + min(context, max(0, after)))
    }
  }

  /// Splits a range longer than `maximum` into equal pieces no longer than it.
  static func forcedSplit(_ range: Range<Int>, maximum: Int = maximumSegmentSamples) -> [Range<Int>] {
    guard !range.isEmpty else { return [] }
    let pieces = (range.count + maximum - 1) / maximum
    let size = (range.count + pieces - 1) / pieces
    return stride(from: range.lowerBound, to: range.upperBound, by: size).map {
      $0..<min($0 + size, range.upperBound)
    }
  }
}

/// Reads the app's own 16 kHz mono PCM16 WAVs, which always carry a 44-byte
/// header (see `WavFile`), the same assumption `NemotronTranscriber` makes.
struct PCM16WavReader {
  static let headerSize = 44
  let url: URL
  let sampleCount: Int

  init(url: URL) throws {
    self.url = url
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    sampleCount = max(0, size - Self.headerSize) / MemoryLayout<Int16>.size
  }

  func samples(from start: Int, count: Int) throws -> [Float] {
    guard count > 0 else { return [] }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(Self.headerSize + start * MemoryLayout<Int16>.size))
    let data = try handle.read(upToCount: count * MemoryLayout<Int16>.size) ?? Data()
    let available = data.count / MemoryLayout<Int16>.size
    return data.withUnsafeBytes { raw in
      let input = raw.bindMemory(to: Int16.self)
      return (0..<available).map { Float(Int16(littleEndian: input[$0])) / 32_768 }
    }
  }
}
