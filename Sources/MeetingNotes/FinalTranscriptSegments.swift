import FluidAudio
import Foundation

/// Builds archive turns from the recognizer's final hypothesis only. Streaming
/// partials may be revised, so they are useful for display but cannot be used
/// as the source of truth once recording has stopped.
enum FinalTranscriptSegments {
  private static let maximumSegmentSpan: TimeInterval = 10

  struct Timing: Equatable, Sendable {
    let token: String
    let start: TimeInterval
    let end: TimeInterval

    init(token: String, start: TimeInterval, end: TimeInterval) {
      self.token = token
      self.start = start
      self.end = end
    }

    init(_ timing: TokenTiming) {
      self.init(token: timing.token, start: timing.startTime, end: timing.endTime)
    }
  }

  struct Segment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  static func authoritative(
    text: String, tokenTimings: [TokenTiming], duration: TimeInterval
  ) -> [Segment] {
    authoritative(text: text, timings: tokenTimings.map(Timing.init), duration: duration)
  }

  static func authoritative(
    text: String, timings: [Timing], duration: TimeInterval
  ) -> [Segment] {
    let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalText.isEmpty else { return [] }

    let safeDuration = max(0, duration)
    guard let pieces = validatedPieces(timings, finalText: finalText, duration: safeDuration)
    else {
      return [Segment(start: 0, end: safeDuration, text: finalText)]
    }
    return groupedSegments(from: pieces, duration: safeDuration)
  }

  private struct Piece {
    let text: String
    let timing: Timing
  }

  private static func validatedPieces(
    _ timings: [Timing], finalText: String, duration: TimeInterval
  ) -> [Piece]? {
    guard !timings.isEmpty else { return nil }
    var previousStart: TimeInterval = -.infinity
    var previousEnd: TimeInterval = -.infinity
    var rawPieces: [Piece] = []
    for timing in timings {
      guard timing.start.isFinite, timing.end.isFinite,
        timing.start >= 0, timing.end >= timing.start,
        timing.start >= previousStart, timing.end >= previousEnd,
        timing.start <= duration
      else { return nil }
      previousStart = timing.start
      previousEnd = timing.end
      let text = renderedToken(timing.token)
      if text != "<blank>" && text != "<pad>" && !text.isEmpty {
        rawPieces.append(Piece(text: text, timing: timing))
      }
    }
    // Match FluidAudio's NemotronMultilingualTokenizer.decode(ids:): a
    // standalone SentencePiece `▁` can sit before the next token's own `▁`.
    // The tokenizer collapses that run to one ASCII space. Do it while the
    // timing pieces are still separate, so their concatenation remains an
    // exact slice of `finalText` instead of merely being comparable after a
    // lossy normalization.
    var previousEndsInSpace = false
    let pieces = rawPieces.compactMap { piece -> Piece? in
      var text = ""
      for character in piece.text {
        let decoded: Character = character == "▁" ? " " : character
        if decoded == " ", previousEndsInSpace { continue }
        text.append(decoded)
        previousEndsInSpace = decoded == " "
      }
      return text.isEmpty ? nil : Piece(text: text, timing: piece.timing)
    }
    guard !pieces.isEmpty,
      pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == finalText
    else { return nil }
    return pieces
  }

  private static func renderedToken(_ token: String) -> String {
    token.replacingOccurrences(of: "▁", with: " ")
  }

  private static func groupedSegments(from pieces: [Piece], duration: TimeInterval) -> [Segment] {
    var segments: [Segment] = []
    var group: [Piece] = []

    func appendGroup() {
      guard let first = group.first, let last = group.last else { return }
      let text = group.map(\.text).joined()
      segments.append(Segment(
        start: min(duration, first.timing.start),
        end: min(duration, last.timing.end),
        text: segments.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text))
    }

    for piece in pieces {
      if let first = group.first,
        piece.timing.end - first.timing.start > maximumSegmentSpan,
        canStartSegment(with: piece.text)
      {
        appendGroup()
        group.removeAll(keepingCapacity: true)
      }
      group.append(piece)
    }
    appendGroup()
    // `finishWithTokenTimings` can include a final standalone `▁` after the
    // terminal punctuation. The finished transcript is normalized at its
    // outer boundary, so make the last timed slice match it exactly as well.
    if let lastIndex = segments.indices.last {
      let last = segments[lastIndex]
      var text = last.text
      while text.last?.isWhitespace == true {
        text.removeLast()
      }
      segments[lastIndex] = Segment(
        start: last.start, end: last.end,
        text: text)
    }
    return segments
  }

  private static func canStartSegment(with text: String) -> Bool {
    guard let first = text.first else { return false }
    return first.isWhitespace || isCJK(first)
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
      (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        || (0xF900...0xFAFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        || (0xAC00...0xD7AF).contains($0.value)
    }
  }
}
