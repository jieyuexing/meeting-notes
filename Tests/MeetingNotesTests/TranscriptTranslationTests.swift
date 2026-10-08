import Foundation
import Testing

@testable import MeetingNotes

@Test func transcriptTranslationSettingDefaultsOnAndRoundTrips() {
  let defaults = UserDefaults(suiteName: "translation-setting-\(UUID().uuidString)")!
  #expect(TranscriptTranslationSettingsStore.load(from: defaults))
  TranscriptTranslationSettingsStore.save(false, to: defaults)
  #expect(!TranscriptTranslationSettingsStore.load(from: defaults))
}

@Test func transcriptLanguageDetectionSeparatesChineseJapaneseKoreanAndLatin() {
  #expect(TranscriptLanguageDetector.detect(text: "这是麦克风测试，今天讨论三个事项。") == "zh")
  #expect(TranscriptLanguageDetector.detect(text: "明日の会議は十時から始めます。資料は事前に共有します。") == "ja")
  #expect(TranscriptLanguageDetector.detect(text: "会議室予約確認済。担当者変更有。") == "zh")
  #expect(TranscriptLanguageDetector.detect(text: "오늘 회의는 세 가지 안건을 논의합니다.") == "ko")
  #expect(
    TranscriptLanguageDetector.detect(
      text: "We agreed to ship the release on Friday and update the notes.") == "en")
  #expect(
    TranscriptLanguageDetector.detect(
      text: "Nous avons décidé de publier la nouvelle version vendredi prochain.") == "fr")
  // Mixed: technical English terms do not outweigh the spoken language.
  #expect(TranscriptLanguageDetector.detect(text: "我们在 Meeting Notes 里用 Jira 跟踪这个问题。") == "zh")
  #expect(TranscriptLanguageDetector.detect(text: "Meeting Notes の Jira チケットを金曜日までに更新します。") == "ja")
  #expect(TranscriptLanguageDetector.detect(text: "  123，。 ") == nil)
  #expect(TranscriptLanguageDetector.detect([]) == nil)
  #expect(
    TranscriptLanguageDetector.detect([
      turn(0, "第一，明天上午十点继续。"), turn(5, "第二，周五下午三点检查结果。"),
    ]) == "zh")
}

@Test func notesLanguageCodesAreUniqueAndRoundTrip() {
  let codes = MeetingNotesLanguage.allCases.compactMap(\.languageCode)
  #expect(codes.count == MeetingNotesLanguage.allCases.count - 1)
  #expect(Set(codes).count == codes.count)
  #expect(MeetingNotesLanguage.source.languageCode == nil)
  #expect(MeetingNotesLanguage.chineseSimplified.languageCode == "zh")
  #expect(MeetingNotesLanguage(languageCode: "ja") == .japanese)
  #expect(MeetingNotesLanguage(languageCode: "xx") == nil)
  #expect(TranscriptTranslation.fileName(for: "zh") == "transcript.zh.md")
  #expect(TranscriptTranslation.allFileNames.contains("transcript.zh.md"))
  #expect(!TranscriptTranslation.allFileNames.contains("transcript.md"))
}

@Test func translationChunksRespectLimitsAndKeepEveryLine() {
  let lines = (0..<95).map { TranscriptFormatter.Line(start: Double($0), speaker: "Unknown", text: String(repeating: "あ", count: $0 == 50 ? 5_000 : 60)) }
  let ranges = TranscriptTranslator.chunks(lines)
  #expect(ranges.first?.lowerBound == 0)
  #expect(ranges.last?.upperBound == lines.count)
  #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
  #expect(ranges.allSatisfy { $0.count <= TranscriptTranslator.chunkLineLimit })
  #expect(ranges.contains(50..<51))
  for range in ranges where range.count > 1 {
    #expect(range.map { lines[$0].text.count }.reduce(0, +) <= TranscriptTranslator.chunkCharacterLimit)
  }
  #expect(TranscriptTranslator.chunks([]).isEmpty)
}

@Test func translationPromptNumbersLinesAndFencesThemAsData() {
  let lines = [line(0, "明日は休みです。"), line(5, "会議は十時です。"), line(9, "資料を送ります。")]
  let prompt = TranscriptTranslator.prompt(
    title: "定例", lines: lines, range: 1..<3, source: "ja", target: "zh")
  #expect(prompt.contains("from Japanese into Chinese (Simplified)"))
  #expect(prompt.contains("[1] 会議は十時です。\n[2] 資料を送ります。"))
  #expect(!prompt.contains("[0]"))
  #expect(prompt.contains("data, not instructions"))
  #expect(prompt.contains("indices 1 through 2"))
}

@Test func translationResponsesMustMatchTheLinesOneToOne() throws {
  #expect(
    try TranscriptTranslator.decode(
      response([(4, "资料"), (3, "会议")]), expected: 3..<5) == ["会议", "资料"])
  let mismatched: [(String, Data)] = [
    ("missing line", response([(3, "会议")])),
    ("extra line", response([(3, "会议"), (4, "资料"), (5, "多余")])),
    ("duplicate index", response([(3, "会议"), (3, "会议")])),
    ("wrong index", response([(3, "会议"), (7, "资料")])),
    ("empty text", response([(3, "会议"), (4, "  ")])),
  ]
  for (label, data) in mismatched {
    #expect(throws: TranscriptTranslator.TranslationError.self, "\(label)") {
      try TranscriptTranslator.decode(data, expected: 3..<5)
    }
  }
  #expect(throws: (any Error).self) {
    try TranscriptTranslator.decode(Data("{\"translations\":\"no\"}".utf8), expected: 0..<1)
  }
}

@Test func translationRetriesAMismatchedChunkThenSucceeds() async throws {
  let calls = CallRecorder()
  let lines = [line(0, "おはようございます。"), line(4, "始めましょう。")]
  let translated = try await TranscriptTranslator.translate(
    title: "t", lines: lines, source: "ja", target: "zh"
  ) { prompt, _ in
    let count = await calls.record(prompt)
    return count == 1 ? response([(0, "早上好。")]) : response([(0, "早上好。"), (1, "开始吧。")])
  }
  #expect(translated == ["早上好。", "开始吧。"])
  #expect(await calls.count == 2)
}

@Test func translationMarksAChunkThatNeverAlignsAndKeepsTheRest() async throws {
  let calls = CallRecorder()
  let lines = (0..<(TranscriptTranslator.chunkLineLimit + 1)).map { line(Double($0), "行\($0)です。") }
  let translated = try await TranscriptTranslator.translate(
    title: "t", lines: lines, source: "ja", target: "zh"
  ) { prompt, _ in
    _ = await calls.record(prompt)
    // The second chunk (one line) always comes back with the wrong count.
    if prompt.contains("[\(TranscriptTranslator.chunkLineLimit)] ") {
      return response([])
    }
    return response((0..<TranscriptTranslator.chunkLineLimit).map { ($0, "第\($0)行。") })
  }
  #expect(translated.count == lines.count)
  #expect(translated.dropLast().allSatisfy { $0 != nil })
  #expect(translated.last == .some(nil))
  #expect(translated[3] == "第3行。")
  #expect(await calls.count == 1 + TranscriptTranslator.attemptsPerChunk)
}

@Test func translationFailsWhenNoChunkAligns() async throws {
  await #expect(throws: TranscriptTranslator.TranslationError.self) {
    _ = try await TranscriptTranslator.translate(
      title: "t", lines: [line(0, "はい。")], source: "ja", target: "zh"
    ) { _, _ in response([(0, "")]) }
  }
}

@Test func translationBackendErrorAbortsAfterRetries() async throws {
  let calls = CallRecorder()
  await #expect(throws: CommandSummaryBackend.CommandError.self) {
    _ = try await TranscriptTranslator.translate(
      title: "t", lines: [line(0, "はい。")], source: "ja", target: "zh"
    ) { prompt, _ in
      _ = await calls.record(prompt)
      throw CommandSummaryBackend.CommandError.failed(1, "offline")
    }
  }
  #expect(await calls.count == TranscriptTranslator.attemptsPerChunk)
}

@Test func translationPassSendsNothingWhenTheBackendIsOffOrNoTranslationIsNeeded() async throws {
  let japanese = completeMeeting([turn(0, "明日の会議は十時からです。"), turn(6, "資料は事前に送ります。")])
  let chinese = completeMeeting([turn(0, "明天上午十点继续。")])
  let calls = CallRecorder()
  let request: TranscriptTranslator.Request = { prompt, _ in
    _ = await calls.record(prompt)
    return Data()
  }
  let cases: [(MeetingDocument, SummaryBackend, MeetingNotesLanguage, Bool, String)] = [
    (japanese, .off, .chineseSimplified, true, "ja"),
    (japanese, .command, .chineseSimplified, false, "ja"),
    (japanese, .command, .source, true, "ja"),
    (japanese, .command, .japanese, true, "ja"),
    (chinese, .command, .chineseSimplified, true, "zh"),
  ]
  for (meeting, backend, notes, enabled, language) in cases {
    let outcome = try await TranscriptTranslationPass.run(
      meeting, settings: SummaryBackendSettings(backend: backend, command: "unused"),
      notesLanguage: notes, enabled: enabled, isSignedIn: { true }, request: request)
    #expect(outcome.language == language)
    #expect(outcome.translation == nil)
    #expect(outcome.error == nil)
  }
  #expect(await calls.count == 0)

  var purged = japanese
  purged.transcriptDeletedAt = Date()
  #expect(
    TranscriptTranslator.decide(
      purged, detectedLanguage: "ja", notesLanguage: .chineseSimplified, backend: .command,
      enabled: true) == .skip)
}

@Test func translationPassRequiresTheCodexSignIn() async throws {
  let calls = CallRecorder()
  let outcome = try await TranscriptTranslationPass.run(
    completeMeeting([turn(0, "明日の会議は十時からです。")]),
    settings: SummaryBackendSettings(backend: .codex), notesLanguage: .chineseSimplified,
    enabled: true, isSignedIn: { false }
  ) { prompt, _ in
    _ = await calls.record(prompt)
    return Data()
  }
  #expect(outcome.language == "ja")
  #expect(outcome.translation == nil)
  #expect(outcome.error is OpenAIEnricher.EnrichmentError)
  #expect(await calls.count == 0)
}

@Test func translationPassAlignsTranslationsWithTranscriptLines() async throws {
  let meeting = completeMeeting([
    turn(0, "明日の会議は十時からです。"), turn(12, "資料は事前に送ります。"),
  ])
  let outcome = try await TranscriptTranslationPass.run(
    meeting, settings: SummaryBackendSettings(backend: .command, command: "unused"),
    notesLanguage: .chineseSimplified, enabled: true, isSignedIn: { false }
  ) { _, _ in response([(1, "资料会提前发送。"), (0, "明天的会议十点开始。")]) }
  let translation = try #require(outcome.translation)
  #expect(translation.sourceLanguage == "ja")
  #expect(translation.targetLanguage == "zh")
  #expect(translation.transcriptionVersion == meeting.transcriptionVersion)
  #expect(translation.lines.map(\.start) == [0, 12])
  #expect(translation.lines.map(\.text) == ["明日の会議は十時からです。", "資料は事前に送ります。"])
  #expect(translation.lines.map(\.translation) == ["明天的会议十点开始。", "资料会提前发送。"])
  #expect(translation.generator == "Custom summary command")
  #expect(translation.fileName == "transcript.zh.md")
  // An existing complete translation of this version is not redone.
  var translated = meeting
  translated.transcriptTranslation = translation
  #expect(
    TranscriptTranslator.decide(
      translated, detectedLanguage: "ja", notesLanguage: .chineseSimplified, backend: .command,
      enabled: true) == .skip)
}

@Test func summaryPromptCarriesTheNotesLanguageInstruction() async throws {
  #expect(
    MeetingNotesLanguage.chineseSimplified.processingInstruction
      == "Write every generated text field in Chinese (Simplified), regardless of the transcript language.")
  let directory = TestTemporary.root.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let captured = directory.appending(path: "prompt.txt")
  let json = #"{"summary":"ok","topics":[],"decisions":[],"action_items":[],"open_questions":[],"key_statements":[]}"#
  _ = try await OpenAIEnricher().testBackend(
    SummaryBackendSettings(
      backend: .command, command: "cat > '\(captured.path)' && printf '%s' '\(json)'"))
  let prompt = try String(contentsOf: captured, encoding: .utf8)
  #expect(prompt.contains(MeetingNotesLanguageStore.load().processingInstruction))
}

@Test func translatedTranscriptFollowsRenameRetranscriptionAndRetention() async throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  let started = try await store.begin(title: "日本定例", calendar: nil)
  try await store.replaceTranscript(
    [turn(0, "明日の会議は十時からです。"), turn(12, "資料は事前に送ります。")], status: .complete)
  let document = try #require(await store.current())
  let translation = TranscriptTranslation(
    sourceLanguage: "ja", targetLanguage: "zh", transcriptionVersion: document.transcriptionVersion,
    lines: [
      .init(start: 0, text: "明日の会議は十時からです。", translation: "明天的会议十点开始。"),
      .init(start: 12, text: "資料は事前に送ります。", translation: nil),
    ],
    generatedAt: Date(), generator: "Custom summary command")

  // A stale version is refused; the current one writes the artifact.
  #expect(
    try await !store.setTranscriptLanguage(
      "ja", translation: translation, meetingID: started.id,
      transcriptionVersion: document.transcriptionVersion + 1))
  #expect(
    try await store.setTranscriptLanguage(
      "ja", translation: translation, meetingID: started.id,
      transcriptionVersion: document.transcriptionVersion))
  #expect(
    try await !store.setTranscriptLanguage(
      "ja", translation: nil, meetingID: started.id,
      transcriptionVersion: document.transcriptionVersion))
  let folder = try #require(await store.currentFolder())
  let artifact = try String(contentsOf: folder.appending(path: "transcript.zh.md"), encoding: .utf8)
  #expect(artifact.contains("artifact: translated-transcript"))
  #expect(artifact.contains("source_language: ja"))
  #expect(artifact.contains("complete: false"))
  #expect(artifact.contains("# 日本定例 — Transcript (Japanese → Chinese (Simplified))"))
  #expect(artifact.contains("**[00:00:00]** 明日の会議は十時からです。\n\n> 明天的会议十点开始。"))
  #expect(artifact.contains("**[00:00:12]** 資料は事前に送ります。\n\n> _(Translation failed for this line.)_"))
  let stored = try #require(await store.current())
  #expect(stored.transcriptLanguage == "ja")
  #expect(stored.transcriptTranslation == translation)

  // Settings-driven rewrites keep it; rename moves it and refreshes the title.
  try await store.setInsights(
    MeetingInsights(
      summary: "明天十点开会。", topics: [], decisions: [], actionItems: [], openQuestions: [],
      keyStatements: [], generatedAt: Date(), generator: "test"))
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "transcript.zh.md").path))
  try await store.renameCompletedMeeting(id: started.id, title: "Renamed weekly")
  let renamed = try #require(await store.currentFolder())
  #expect(!FileManager.default.fileExists(atPath: folder.path))
  let renamedArtifact = try String(
    contentsOf: renamed.appending(path: "transcript.zh.md"), encoding: .utf8)
  #expect(renamedArtifact.contains("# Renamed weekly — Transcript"))

  // A new transcription version drops the translation of the old one.
  try await store.replaceCompletedTranscript([turn(0, "新しい転写です。")])
  #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "transcript.zh.md").path))
  #expect(await store.current()?.transcriptTranslation == nil)
  #expect(await store.current()?.transcriptLanguage == nil)

  // Retention deletes it with the transcript.
  let current = try #require(await store.current())
  #expect(
    try await store.setTranscriptLanguage(
      "ja", translation: TranscriptTranslation(
        sourceLanguage: "ja", targetLanguage: "zh",
        transcriptionVersion: current.transcriptionVersion,
        lines: [.init(start: 0, text: "新しい転写です。", translation: "新的转写。")],
        generatedAt: Date(), generator: "test"),
      meetingID: started.id, transcriptionVersion: current.transcriptionVersion))
  #expect(FileManager.default.fileExists(atPath: renamed.appending(path: "transcript.zh.md").path))
  var aged = try #require(await store.current())
  aged.endedAt = Date(timeIntervalSinceNow: -120 * 86_400)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode(aged).write(to: MeetingStore.stateFile(in: renamed), options: .atomic)
  let cutoff = Date(timeIntervalSinceNow: -90 * 86_400)
  #expect(try await store.purgeExpiredTranscripts(before: cutoff) == 1)
  #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "transcript.zh.md").path))
  #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "transcript.md").path))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let purged = try decoder.decode(
    MeetingDocument.self, from: Data(contentsOf: MeetingStore.stateFile(in: renamed)))
  #expect(purged.transcriptTranslation == nil)
  #expect(
    try await !store.setTranscriptLanguage(
      "ja", translation: translation, meetingID: started.id,
      transcriptionVersion: purged.transcriptionVersion))
  #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "transcript.zh.md").path))
}

@Test func translatedTranscriptSurvivesTheDeletingArchiveMirror() async throws {
  let base = TestTemporary.root.appending(path: UUID().uuidString)
  let spool = base.appending(path: "spool")
  let archive = base.appending(path: "archive")
  defer { try? FileManager.default.removeItem(at: base) }
  let sync = RemoteSyncService(
    configuration: .init(
      remoteSyncEnabled: false, host: "", path: "", localPath: archive.path, enabled: true))
  // Spool-resident completed meeting: the copy leg runs rsync --delete-excluded.
  let store = MeetingStore(root: spool, sync: sync)
  let started = try await store.begin(title: "Mirror", calendar: nil)
  try await store.replaceTranscript([turn(0, "明日の会議は十時からです。")], status: .complete)
  let document = try #require(await store.current())
  #expect(
    try await store.setTranscriptLanguage(
      "ja",
      translation: TranscriptTranslation(
        sourceLanguage: "ja", targetLanguage: "zh",
        transcriptionVersion: document.transcriptionVersion,
        lines: [.init(start: 0, text: "明日の会議は十時からです。", translation: "明天的会议十点开始。")],
        generatedAt: Date(), generator: "test"),
      meetingID: started.id, transcriptionVersion: document.transcriptionVersion))
  let folder = try #require(await store.currentFolder())
  await sync.enqueue(folder: folder)
  await sync.flush()
  let mirrored = archive.appending(path: folder.pathComponents.suffix(4).joined(separator: "/"))
  #expect(FileManager.default.fileExists(atPath: mirrored.appending(path: "transcript.zh.md").path))
  #expect(FileManager.default.fileExists(atPath: mirrored.appending(path: "transcript.md").path))

  // Removing it at the source (re-transcription) removes the mirror copy too.
  try await store.replaceCompletedTranscript([turn(0, "別の内容です。")])
  await sync.enqueue(folder: folder)
  await sync.flush()
  #expect(!FileManager.default.fileExists(atPath: mirrored.appending(path: "transcript.zh.md").path))
  #expect(FileManager.default.fileExists(atPath: mirrored.appending(path: "transcript.md").path))
}

@Test func meetingDocumentsWithoutTheForkFieldsStillDecode() throws {
  let meeting = completeMeeting([turn(0, "Hello")])
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let data = try encoder.encode(meeting)
  let json = String(decoding: data, as: UTF8.self)
  #expect(!json.contains("transcriptLanguage"))
  #expect(!json.contains("transcriptTranslation"))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(MeetingDocument.self, from: data)
  #expect(decoded.transcriptLanguage == nil)
  #expect(decoded.transcriptTranslation == nil)
}

private actor CallRecorder {
  private(set) var prompts: [String] = []
  var count: Int { prompts.count }

  func record(_ prompt: String) -> Int {
    prompts.append(prompt)
    return prompts.count
  }
}

private func turn(_ start: TimeInterval, _ text: String) -> TranscriptTurn {
  TranscriptTurn(start: start, end: start + 4, speaker: "Unknown", text: text, source: .microphone)
}

private func line(_ start: TimeInterval, _ text: String) -> TranscriptFormatter.Line {
  TranscriptFormatter.Line(start: start, speaker: "Unknown", text: text)
}

private func completeMeeting(_ turns: [TranscriptTurn]) -> MeetingDocument {
  MeetingDocument(
    id: UUID(), title: "定例", startedAt: Date(), endedAt: Date(), status: .complete,
    transcript: turns)
}

private func response(_ items: [(Int, String)]) -> Data {
  let object: [String: Any] = ["translations": items.map { ["index": $0.0, "text": $0.1] }]
  return try! JSONSerialization.data(withJSONObject: object)
}

/// Opt-in translation probe through a real summary command. Inert without
/// all three variables. Input is a report written by
/// `localSenseVoiceFinalProbe`; only its transcript text is sent.
@Test func liveTranscriptTranslationProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let command = environment["MEETING_NOTES_TEST_COMMAND"],
    let inputPath = environment["MEETING_NOTES_TRANSLATION_INPUT"],
    let outputPath = environment["MEETING_NOTES_TRANSLATION_OUT"]
  else { return }
  let report = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inputPath)))
      as? [String: Any])
  let results = try #require(report["results"] as? [[String: Any]])
  let turns = results.flatMap { result in
    (result["turns"] as? [[String: Any]] ?? []).compactMap { item -> TranscriptTurn? in
      guard let start = item["start"] as? Double, let end = item["end"] as? Double,
        let text = item["text"] as? String
      else { return nil }
      return TranscriptTurn(start: start, end: end, speaker: "Unknown", text: text, source: .microphone)
    }
  }
  let meeting = MeetingDocument(
    id: UUID(), title: "合成音声テスト", startedAt: Date(), endedAt: Date(), status: .complete,
    transcript: turns)
  let outcome = try await TranscriptTranslationPass.run(
    meeting, settings: SummaryBackendSettings(backend: .command, command: command),
    notesLanguage: .chineseSimplified, enabled: true, isSignedIn: { true })
  if let error = outcome.error { throw error }
  var translated = meeting
  translated.transcriptLanguage = outcome.language
  translated.transcriptTranslation = outcome.translation
  let folder = URL(fileURLWithPath: outputPath, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try TranscriptTranslationArtifact.persist(for: translated, in: folder) { data, url in
    try data.write(to: url, options: .atomic)
  }
  #expect(outcome.language == "ja")
  #expect(translated.transcriptTranslation?.isComplete == true)
}
