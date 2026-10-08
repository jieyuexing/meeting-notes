import Foundation
import Testing
@testable import MeetingNotes

@Test func lifelogSelectionUsesTurnTimesAndKeepsSourceAudioAttribution() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: calendar)
  let beginning = Date(timeIntervalSince1970: 1_791_417_600)
  var item = try store.createSegment(id: UUID(), startedAt: beginning)
  item.segment.status = .complete
  item.segment.endedAt = beginning + 180
  item.segment.transcript = [
    TranscriptTurn(start: 0, end: 10, speaker: "", text: "outside", source: .microphone),
    TranscriptTurn(start: 50, end: 70, speaker: "", text: "boundary", source: .microphone),
    TranscriptTurn(start: 80, end: 90, speaker: "", text: "remote voice", source: .system),
    TranscriptTurn(start: 120, end: 150, speaker: "", text: "after", source: .system),
  ]
  try store.save(item.segment, in: item.folder)
  let before = try Data(contentsOf: item.folder.appending(path: "segment.json"))
  let selection = try LifelogSelection.read(store: store, start: beginning + 60,
    end: beginning + 120, title: "Review", now: beginning + 200)
  #expect(selection.sources.flatMap(\.lines).map(\.text) == ["boundary", "remote voice"])
  #expect(selection.sources[0].lines[0].startedAt == beginning + 50)
  #expect(selection.sources[0].lines[1].source == .system)
  #expect(try selection.digestEntries(store: store)[0].lines[1].contains("[system]"))
  let saved = try selection.save(in: store)
  #expect(FileManager.default.fileExists(atPath: saved.appending(path: "selection.json").path))
  #expect(try Data(contentsOf: item.folder.appending(path: "segment.json")) == before)
}

@Test func lifelogSelectionRejectsEmptyOrExcessiveRangesAndReportsPending() throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root)
  let start = Date(timeIntervalSince1970: 1_791_417_600)
  #expect(throws: LifelogSelection.SelectionError.invalidRange) {
    try LifelogSelection.read(store: store, start: start, end: start, title: "")
  }
  #expect(throws: LifelogSelection.SelectionError.rangeTooLong) {
    try LifelogSelection.read(store: store, start: start, end: start + 200_000, title: "")
  }
  _ = try store.createSegment(id: UUID(), startedAt: start)
  let pending = try LifelogSelection.read(store: store, start: start, end: start + 60,
    title: "", now: start + 90)
  #expect(pending.hasIncompleteSources)
  #expect(throws: LifelogSelection.SelectionError.noFinalText) {
    try pending.digestEntries(store: store)
  }
}

@Test func selectionDigestUsesExistingFinalTextAndIndependentOutput() async throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root)
  let start = Date(timeIntervalSince1970: 1_791_417_600)
  let item = try store.createSegment(id: UUID(), startedAt: start)
  var segment = item.segment; segment.endedAt = start + 20
  try store.complete(segment, in: item.folder,
    turns: [.init(start: 1, end: 9, speaker: "", text: "selected source", source: .system)],
    transcriptionStartedAt: start, transcribedAt: start + 20, deleteAudio: false)
  let selection = try LifelogSelection.read(store: store, start: start, end: start + 20, title: "Meeting")
  let folder = try selection.save(in: store)
  let before = try Data(contentsOf: item.folder.appending(path: "segment.json"))
  let result = try await LifelogDigest.generate(store: store, day: "Meeting", label: nil,
    chunkCharacters: 2000, language: .english, request: { prompt, _ in
      #expect(prompt.contains("selected source"))
      #expect(prompt.contains("[system]"))
      return Data(#"{"overview":"Summary","periods":[],"actions":[],"reviews":[]}"#.utf8)
    }, selectedEntries: try selection.digestEntries(store: store), outputFolder: folder)
  #expect(result.status == .complete)
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "meeting.md").path))
  #expect(!FileManager.default.fileExists(atPath: store.digestFolder.path))
  #expect(try Data(contentsOf: item.folder.appending(path: "segment.json")) == before)
  let markdown = try String(contentsOf: folder.appending(path: "meeting.md"), encoding: .utf8)
  #expect(markdown.contains("](../../"))
}
