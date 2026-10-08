import Foundation
import FluidAudio
import Testing

@testable import MeetingNotes

@Test func finalSegmentsKeepTheFinalChineseTextAfterARevision() {
  let result = FinalTranscriptSegments.authoritative(
    text: "今天讨论三个事项",
    timings: [
      .init(token: "▁今天", start: 0.2, end: 0.4),
      .init(token: "讨论", start: 0.4, end: 0.6),
      .init(token: "三个", start: 0.6, end: 0.8),
      .init(token: "事项", start: 0.8, end: 1.0),
    ], duration: 1.5)

  #expect(result == [.init(start: 0.2, end: 1.0, text: "今天讨论三个事项")])
}

@Test func finalSegmentsKeepEnglishPunctuationAndUnicodeTextUntouched() {
  let result = FinalTranscriptSegments.authoritative(
    text: "Hello, 世界!",
    timings: [
      .init(token: "▁Hello", start: 0, end: 0.2),
      .init(token: ",", start: 0.2, end: 0.3),
      .init(token: "▁世界", start: 0.3, end: 0.5),
      .init(token: "!", start: 0.5, end: 0.6),
    ], duration: 0.8)

  #expect(result == [.init(start: 0, end: 0.6, text: "Hello, 世界!")])
}

@Test func finalSegmentsUseFluidAudioTokenizerSpacingForStandaloneBoundaryTokens() {
  // FluidAudio's multilingual tokenizer collapses a standalone `▁` followed
  // by a word-start piece from two spaces to one. Timings must use the same
  // detokenization rule before deciding whether they match the final text.
  let result = FinalTranscriptSegments.authoritative(
    text: "事项。 第一",
    timings: [
      .init(token: "▁事项", start: 0.2, end: 0.4),
      .init(token: "。", start: 0.4, end: 0.45),
      .init(token: "▁", start: 0.45, end: 0.45),
      .init(token: "▁第", start: 0.45, end: 0.55),
      .init(token: "一", start: 0.55, end: 0.65),
    ], duration: 1)

  #expect(result == [.init(start: 0.2, end: 0.65, text: "事项。 第一")])
}

@Test func finalSegmentsKeepTimingWhenAStandaloneBoundaryStartsChineseText() {
  let result = FinalTranscriptSegments.authoritative(
    text: "这是麦。 第",
    timings: [
      .init(token: "▁", start: 0.2, end: 0.2),
      .init(token: "这", start: 0.2, end: 0.3),
      .init(token: "是", start: 0.3, end: 0.4),
      .init(token: "麦", start: 0.4, end: 0.5),
      .init(token: "。", start: 0.5, end: 0.55),
      .init(token: "▁", start: 0.55, end: 0.55),
      .init(token: "▁", start: 0.55, end: 0.6),
      .init(token: "第", start: 0.6, end: 0.7),
    ], duration: 1)

  #expect(result == [.init(start: 0.2, end: 0.7, text: "这是麦。 第")])
}

@Test func finalSegmentsDiscardTokenizerOnlyTrailingBoundaryWithoutFallback() {
  let result = FinalTranscriptSegments.authoritative(
    text: "事项。",
    timings: [
      .init(token: "▁", start: 0.2, end: 0.2),
      .init(token: "事", start: 0.2, end: 0.3),
      .init(token: "项", start: 0.3, end: 0.4),
      .init(token: "。", start: 0.4, end: 0.5),
      .init(token: "▁", start: 0.5, end: 0.5),
    ], duration: 1)

  #expect(result == [.init(start: 0.2, end: 0.5, text: "事项。")])
}

@Test func finalSegmentsTrimTerminalBoundaryAfterATimedSplit() {
  let result = FinalTranscriptSegments.authoritative(
    text: "第一段后。",
    timings: [
      .init(token: "▁", start: 0.2, end: 0.2),
      .init(token: "第", start: 0.2, end: 0.3),
      .init(token: "一", start: 0.3, end: 0.4),
      .init(token: "段", start: 0.4, end: 0.5),
      .init(token: "后", start: 10.5, end: 10.6),
      .init(token: "。", start: 10.6, end: 10.7),
      .init(token: "▁", start: 10.7, end: 10.7),
    ], duration: 11)

  #expect(result == [
    .init(start: 0.2, end: 0.5, text: "第一段"),
    .init(start: 10.5, end: 10.7, text: "后。"),
  ])
}

@Test func finalSegmentsMatchTokenizerMarkersInsideAPiece() {
  let result = FinalTranscriptSegments.authoritative(
    text: "A B",
    timings: [.init(token: "▁A▁B", start: 0.2, end: 0.5)], duration: 1)

  #expect(result == [.init(start: 0.2, end: 0.5, text: "A B")])
}

@Test func finalSegmentsFallBackToTheWholeFinalTextForMissingOrMismatchedTimings() {
  let missing = FinalTranscriptSegments.authoritative(text: "明天十点继续", timings: [], duration: 4)
  let mismatched = FinalTranscriptSegments.authoritative(
    text: "明天十点继续", timings: [.init(token: "▁明天十两继续", start: 0, end: 2)], duration: 4)

  #expect(missing == [.init(start: 0, end: 4, text: "明天十点继续")])
  #expect(mismatched == [.init(start: 0, end: 4, text: "明天十点继续")])
}

@Test func finalSegmentsRejectInvalidTimingAndClipValidTimingToDuration() {
  let invalid = FinalTranscriptSegments.authoritative(
    text: "测试", timings: [.init(token: "▁测试", start: 2, end: 1)], duration: 3)
  let nonFinite = FinalTranscriptSegments.authoritative(
    text: "测试", timings: [.init(token: "▁测试", start: .nan, end: 1)], duration: 3)
  let startsAfterAudio = FinalTranscriptSegments.authoritative(
    text: "测试", timings: [.init(token: "▁测试", start: 4, end: 5)], duration: 3)
  let clipped = FinalTranscriptSegments.authoritative(
    text: "测试", timings: [.init(token: "▁测试", start: 0.5, end: 9)], duration: 3)

  #expect(invalid == [.init(start: 0, end: 3, text: "测试")])
  #expect(nonFinite == [.init(start: 0, end: 3, text: "测试")])
  #expect(startsAfterAudio == [.init(start: 0, end: 3, text: "测试")])
  #expect(clipped == [.init(start: 0.5, end: 3, text: "测试")])
}

@Test func finalSegmentsAllowAnEmptyFinalText() {
  #expect(FinalTranscriptSegments.authoritative(text: "  \n", timings: [], duration: 1).isEmpty)
}

@Test func finalArchiveUsesTheFinishedHypothesisInsteadOfPriorPartialText() {
  // "思想" is the old partial. The finished model result corrected it to
  // "事项"; archiveResult is the exact production final-transcribe boundary.
  let result = NemotronTranscriber.archiveResult(
    text: "今天讨论三个事项",
    tokenTimings: [
      .init(token: "▁今天", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 1),
      .init(token: "讨论", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 1),
      .init(token: "三个", tokenId: 3, startTime: 0.4, endTime: 0.6, confidence: 1),
      .init(token: "事项", tokenId: 4, startTime: 0.6, endTime: 0.8, confidence: 1),
    ], duration: 1)

  #expect(result.text == "今天讨论三个事项")
  #expect(result.segments.map(\.text) == ["今天讨论三个事项"])
  #expect(!result.segments.map(\.text).joined().contains("思想"))
}

@Test func finalArchiveAppliesVocabularyCorrectionAcrossTokenBoundariesWithoutDroppingText() {
  let result = NemotronTranscriber.archiveResult(
    text: "we use ac me",
    tokenTimings: [
      .init(token: "▁we", tokenId: 1, startTime: 0, endTime: 0.1, confidence: 1),
      .init(token: "▁use", tokenId: 2, startTime: 0.1, endTime: 0.2, confidence: 1),
      .init(token: "▁ac", tokenId: 3, startTime: 0.2, endTime: 0.3, confidence: 1),
      .init(token: "▁me", tokenId: 4, startTime: 10.1, endTime: 10.2, confidence: 1),
    ], duration: 11,
    correcting: { $0.replacingOccurrences(of: "ac me", with: "Acme") })

  #expect(result.text == "we use Acme")
  #expect(result.segments.map(\.text) == ["we use Acme"])
}

@Test func finalSegmentsKeepMultipleTimedRangesAndFormatterPreservesTheirEnglishSpace() {
  let finalText = "hello world again after ten seconds"
  let segments = FinalTranscriptSegments.authoritative(
    text: finalText,
    timings: [
      .init(token: "▁hello", start: 0, end: 1),
      .init(token: "▁world", start: 1, end: 2),
      .init(token: "▁again", start: 2, end: 3),
      .init(token: "▁after", start: 10.1, end: 10.5),
      .init(token: "▁ten", start: 10.5, end: 10.8),
      .init(token: "▁seconds", start: 10.8, end: 11.2),
    ], duration: 12)
  let turns = segments.map {
    TranscriptTurn(start: $0.start, end: $0.end, speaker: "Unknown", text: $0.text, source: .microphone)
  }

  #expect(segments.count == 2)
  #expect(segments.map(\.text).joined() == finalText)
  #expect(TranscriptFormatter.mergedLines(turns, window: 30).map(\.text) == [finalText])
}

@Test func finalArchivePreservesExplicitEnglishBoundaryThroughTheProductionTurnMapper() {
  let finalText = "one two a word after"
  let result = NemotronTranscriber.archiveResult(
    text: finalText,
    tokenTimings: [
      .init(token: "▁one", tokenId: 1, startTime: 0, endTime: 1, confidence: 1),
      .init(token: "▁two", tokenId: 2, startTime: 1, endTime: 2, confidence: 1),
      .init(token: "▁a", tokenId: 3, startTime: 9.5, endTime: 9.9, confidence: 1),
      .init(token: "▁word", tokenId: 4, startTime: 10.1, endTime: 10.3, confidence: 1),
      .init(token: "▁after", tokenId: 5, startTime: 10.3, endTime: 10.6, confidence: 1),
    ], duration: 11)
  let turns = FinalTranscriptionEngine.turns(from: result, source: .microphone)

  #expect(result.segments.count == 2)
  #expect(TranscriptFormatter.mergedLines(turns, window: 30).map(\.text) == [finalText])
}

@Test func transcriptFormatterKeepsLongCJKTurnsTimestampedThroughTheProductionTurnMapper() {
  let result = NemotronTranscriber.Result(
    text: "第一段。第二段。第三段。", duration: 25,
    segments: [
      .init(start: 0, end: 8, text: "第一段。"),
      .init(start: 11, end: 18, text: "第二段。"),
      .init(start: 21, end: 25, text: "第三段。"),
    ])
  let turns = FinalTranscriptionEngine.turns(from: result, source: .microphone)
  let lines = TranscriptFormatter.mergedLines(turns)

  #expect(lines.map(\.start) == [0, 11, 21])
  #expect(lines.map(\.text) == ["第一段。", "第二段。", "第三段。"])

  let unpunctuated = NemotronTranscriber.Result(
    text: "第一段第二段第三段", duration: 25,
    segments: [
      .init(start: 0, end: 8, text: "第一段"),
      .init(start: 11, end: 18, text: "第二段"),
      .init(start: 21, end: 25, text: "第三段"),
    ])
  let unpunctuatedLines = TranscriptFormatter.mergedLines(
    FinalTranscriptionEngine.turns(from: unpunctuated, source: .microphone))

  #expect(unpunctuatedLines.map(\.start) == [0, 11, 21])
  #expect(unpunctuatedLines.map(\.text) == ["第一段", "第二段", "第三段"])
}

@Test func transcriptFormatterDoesNotInsertASpaceInsideCJKText() {
  let turns = [
    TranscriptTurn(start: 0, end: 1, speaker: "Unknown", text: "这是一段和背", source: .microphone),
    TranscriptTurn(start: 1, end: 2, speaker: "Unknown", text: "景音乐的混合测试", source: .microphone),
  ]

  #expect(TranscriptFormatter.mergedLines(turns).map(\.text) == ["这是一段和背景音乐的混合测试"])
}
