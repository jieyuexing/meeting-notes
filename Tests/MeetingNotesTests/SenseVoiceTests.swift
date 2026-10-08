import Foundation
import Testing

@testable import MeetingNotes

@Test func senseVoiceIsAFinalOnlyEngineAndNotTheDefault() {
  let defaults = UserDefaults(suiteName: "sensevoice-engine-\(UUID().uuidString)")!
  #expect(TranscriptionEngineSettingsStore.load(from: defaults) == .onDevice)
  #expect(TranscriptionEngineSettingsStore.loadLive(from: defaults) == .onDevice)
  TranscriptionEngineSettingsStore.save(.senseVoice, to: defaults)
  #expect(TranscriptionEngineSettingsStore.load(from: defaults) == .senseVoice)
  #expect(TranscriptionEngineOption.allCases.contains(.senseVoice))
  #expect(!TranscriptionEngineOption.senseVoice.supportsLivePreview)
  #expect(TranscriptionEngineOption.onDevice.supportsLivePreview)
  #expect(TranscriptionEngineOption.openAI.supportsLivePreview)

  // A live setting can never hold SenseVoice, whether saved or stored by hand.
  TranscriptionEngineSettingsStore.saveLive(.senseVoice, to: defaults)
  #expect(defaults.string(forKey: "transcription.liveEngine") == "onDevice")
  defaults.set("senseVoice", forKey: "transcription.liveEngine")
  #expect(TranscriptionEngineSettingsStore.loadLive(from: defaults) == .onDevice)
  TranscriptionEngineSettingsStore.saveLive(.openAI, to: defaults)
  #expect(TranscriptionEngineSettingsStore.loadLive(from: defaults) == .openAI)
}

@Test func senseVoiceTextDropsModelTagsAndPieceMarkers() {
  #expect(
    SenseVoiceText.clean("<|ja|><|NEUTRAL|><|Speech|><|withitn|>明日の会議は10時からです。")
      == "明日の会議は10時からです。")
  #expect(SenseVoiceText.clean("<|zh|><|EMO_UNKNOWN|><|BGM|><|woitn|>") == "")
  #expect(SenseVoiceText.clean(" <|en|>▁Ship▁the  fix <|Laughter|> today. ") == "Ship the fix today.")
  #expect(SenseVoiceText.clean("第一，<|Applause|>明天继续。") == "第一，明天继续。")
  #expect(SenseVoiceText.clean("a < b | c > d") == "a < b | c > d")
  #expect(SenseVoiceText.clean("Notes (draft) ▁, 已 更新 ▁。") == "Notes (draft), 已更新。")
  #expect(SenseVoiceText.clean("<|ko|>오늘 회의는 ▁세 가지 안건입니다 .") == "오늘 회의는 세 가지 안건입니다.")
  #expect(SenseVoiceText.clean("明日 の 会議 。") == "明日の会議。")
  #expect(SenseVoiceText.clean("金曜日 の 午後 3 時 まで に") == "金曜日の午後3時までに")
  #expect(SenseVoiceText.clean("Release 3 on Friday") == "Release 3 on Friday")
}

@Test func senseVoiceBlocksDeferSpeechThatCrossesTheBlockEdge() {
  let rate = SenseVoiceSegmentation.sampleRate
  // Mid-block speech is emitted; the segment running into the edge waits for
  // the next block, which then starts at that segment.
  let deferred = SenseVoiceSegmentation.step(
    speech: [rate..<(3 * rate), (8 * rate)..<(10 * rate)], blockStart: 100 * rate,
    blockCount: 10 * rate, isLast: false)
  #expect(deferred.segments == [(101 * rate)..<(103 * rate)])
  #expect(deferred.nextStart == 108 * rate)

  // Within the one-second tolerance still counts as touching the edge.
  let nearEdge = SenseVoiceSegmentation.step(
    speech: [(2 * rate)..<(9 * rate + rate / 2)], blockStart: 0, blockCount: 10 * rate,
    isLast: false)
  #expect(nearEdge.segments.isEmpty)
  #expect(nearEdge.nextStart == 2 * rate)

  // Speech that began at the block start is emitted so the loop advances.
  let continuous = SenseVoiceSegmentation.step(
    speech: [0..<(10 * rate)], blockStart: 50 * rate, blockCount: 10 * rate, isLast: false)
  #expect(continuous.segments == [(50 * rate)..<(60 * rate)])
  #expect(continuous.nextStart == 60 * rate)

  // The last block emits everything.
  let last = SenseVoiceSegmentation.step(
    speech: [rate..<(2 * rate), (5 * rate)..<(6 * rate)], blockStart: 0, blockCount: 6 * rate,
    isLast: true)
  #expect(last.segments == [rate..<(2 * rate), (5 * rate)..<(6 * rate)])
  #expect(last.nextStart == 6 * rate)

  let silent = SenseVoiceSegmentation.step(
    speech: [], blockStart: 0, blockCount: 10 * rate, isLast: false)
  #expect(silent.segments.isEmpty)
  #expect(silent.nextStart == 10 * rate)
}

@Test func senseVoiceForcedSplitStaysBelowTheModelWindow() {
  let rate = SenseVoiceSegmentation.sampleRate
  let maximum = SenseVoiceSegmentation.maximumSegmentSamples
  #expect(maximum < 108 * rate)
  #expect(SenseVoiceSegmentation.forcedSplit(0..<0).isEmpty)
  #expect(SenseVoiceSegmentation.forcedSplit(rate..<(60 * rate)) == [rate..<(60 * rate)])
  #expect(SenseVoiceSegmentation.forcedSplit(0..<maximum) == [0..<maximum])

  let long = (5 * rate)..<(205 * rate)
  let pieces = SenseVoiceSegmentation.forcedSplit(long)
  #expect(pieces.count == 3)
  #expect(pieces.allSatisfy { $0.count <= maximum && !$0.isEmpty })
  #expect(pieces.first?.lowerBound == long.lowerBound)
  #expect(pieces.last?.upperBound == long.upperBound)
  #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
  #expect(Set(pieces.map(\.count)).count <= 2)
}

@Test func senseVoiceContextWindowsNeverOverlapNeighbours() {
  let rate = SenseVoiceSegmentation.sampleRate
  let context = SenseVoiceSegmentation.contextSamples
  #expect(context < rate / 2)
  let segments = [(2 * rate)..<(5 * rate), (5 * rate + rate / 2)..<(8 * rate), (8 * rate)..<(9 * rate)]
  let windows = SenseVoiceSegmentation.contextWindows(segments, within: (rate + rate / 2)..<(9 * rate + rate / 10))
  // Full context into free space, half the gap between neighbours, none
  // across a forced split (zero gap), and clamped to the block.
  #expect(windows[0] == (2 * rate - context)..<(5 * rate + rate / 4))
  #expect(windows[1] == (5 * rate + rate / 4)..<(8 * rate))
  #expect(windows[2] == (8 * rate)..<(9 * rate + rate / 10))
  #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound })
  let edge = SenseVoiceSegmentation.contextWindows([0..<rate], within: 0..<(rate + 10))
  #expect(edge == [0..<(rate + 10)])
  #expect(SenseVoiceSegmentation.contextWindows([], within: 0..<rate).isEmpty)
}

@Test func senseVoiceArchiveKeepsSegmentTimesAndAppliesVocabulary() {
  let result = SenseVoiceTranscriber.archiveResult(
    segments: [
      .init(start: 0.4, end: 3.2, text: "我们用 jira 跟踪"),
      .init(start: 4, end: 4.5, text: "  "),
      .init(start: 5.1, end: 12, text: "明天上午10点继续。"),
    ],
    duration: 10,
    correcting: { $0.replacingOccurrences(of: "jira", with: "Jira") })
  #expect(result.duration == 10)
  #expect(result.segments.map(\.text) == ["我们用 Jira 跟踪", "明天上午10点继续。"])
  #expect(result.segments.map(\.start) == [0.4, 5.1])
  #expect(result.segments.map(\.end) == [3.2, 10])
  let turns = FinalTranscriptionEngine.turns(from: result, source: .system)
  #expect(turns.map(\.source) == [.system, .system])
  #expect(turns.map(\.start) == [0.4, 5.1])
}
