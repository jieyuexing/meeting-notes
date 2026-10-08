import Foundation
import Testing
@testable import MeetingNotes

private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}()
private let dayStart = Date(timeIntervalSince1970: 1_791_417_600) // 2026-10-08T00:00:00Z

private func entry(_ display: UInt32, _ offset: TimeInterval, _ lines: [String], from start: Date = dayStart) -> ScreenTextEntry {
  ScreenTextEntry(displayID: display, startedAt: start + offset, endedAt: start + offset + 5,
    startOffset: offset, endOffset: offset + 5, keyframes: 2, lines: lines)
}

/// A finished segment with optional transcript turns and saved screen text.
private func segment(
  _ store: LifelogStore, at offset: TimeInterval, turns: [TranscriptTurn] = [], screen: [ScreenTextEntry]?
) throws -> URL {
  let start = dayStart + offset
  var item = try store.createSegment(id: UUID(), startedAt: start)
  item.segment.screenRelativeFolder = "screen/2026-10-08/\(item.segment.id.uuidString.lowercased())"
  item.segment.endedAt = start + 600
  item.segment.screenText = .pending
  try store.save(item.segment, in: item.folder)
  try store.complete(item.segment, in: item.folder, turns: turns, transcriptionStartedAt: start + 600,
    transcribedAt: start + 610, deleteAudio: true)
  if let screen {
    var stats = ScreenTextStats(); stats.entries = screen.count
    stats.characters = screen.map(\.characterCount).reduce(0, +)
    try store.saveScreenText(ScreenTextDocument(segmentID: item.segment.id, segmentStartedAt: start,
      segmentEndedAt: start + 600, generatedAt: start + 620, engine: "fixture", estimatedTimeDisplays: [],
      stats: stats, entries: screen), in: item.folder)
    try store.update(in: item.folder) {
      $0.screenText?.status = .complete
      $0.screenText?.stats = stats
    }
  }
  return item.folder
}

@Test func screenTextFilesAreWrittenAndOnlyMarkdownWhenTextExists() throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: utc)
  let folder = try segment(store, at: 3_600, screen: [entry(2, 3_610, ["# heading-like text", "第二行 日本語"])])
  let markdown = try String(contentsOf: store.screenTextMarkdownURL(in: folder), encoding: .utf8)
  #expect(markdown.contains("### 01:00:10–01:00:15 · 显示器 2"))
  #expect(markdown.contains("````text\n# heading-like text\n第二行 日本語\n````"))
  #expect(markdown.contains("可能有识别错误"))
  #expect(store.screenTextDocument(in: folder)?.entries.count == 1)
  let blank = try segment(store, at: 7_200, screen: [])
  #expect(FileManager.default.fileExists(atPath: store.screenTextURL(in: blank).path))
  #expect(!FileManager.default.fileExists(atPath: store.screenTextMarkdownURL(in: blank).path))
}

@Test func audioSavesKeepScreenFieldsAndRecoveryRulesAreBounded() throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: utc)
  let pending = try segment(store, at: 0, screen: nil)
  let stale = try store.load(folder: pending)
  try store.update(in: pending) { $0.screenText?.status = .complete; $0.screenDeletedAt = dayStart }
  try store.markFailed(stale, in: pending, error: CocoaError(.fileReadUnknown), startedAt: dayStart)
  let merged = try store.load(folder: pending)
  #expect(merged.status == .failed && merged.screenText?.status == .complete && merged.screenDeletedAt == dayStart)

  let waiting = try segment(store, at: 100, screen: nil)
  let exhausted = try segment(store, at: 200, screen: nil)
  try store.update(in: exhausted) { $0.screenText?.status = .failed; $0.screenText?.attempts = 3 }
  let retry = try segment(store, at: 300, screen: nil)
  try store.update(in: retry) { $0.screenText?.status = .failed; $0.screenText?.attempts = 2 }
  let deletion = try segment(store, at: 400, screen: [entry(1, 410, ["x"])])
  try store.update(in: deletion) { $0.screenText?.deleteRequested = true }
  let legacy = try segment(store, at: 500, screen: nil)
  try store.update(in: legacy) { $0.screenText = nil }
  let recovery = store.screenTextRecoveryFolders(excluding: waiting)
  #expect(Set(recovery) == [retry, deletion])
  #expect(store.legacyScreenFolders().isEmpty) // no video on disk
  #expect(try store.hasUnfinishedSegments())
}

@Test func screenEvidenceDedupesAcrossTimeAndBoundsLength() {
  var budget = ScreenTextEvidence.Budget()
  let many = (0..<20).map { "line \($0) " + String(repeating: "字", count: 250) }
  let first = ScreenTextEvidence.items([
    entry(1, 10, many),
    entry(1, 20, ["line 0 " + String(repeating: "字", count: 250), "fresh"]),
  ], budget: &budget)
  #expect(first.count == 2)
  // ≤10 lines per entry, ≤160 characters per line plus the ellipsis.
  #expect(first[0].text.components(separatedBy: " / ").count == ScreenTextEvidence.maximumLinesPerEntry)
  #expect(first[0].text.components(separatedBy: " / ").allSatisfy { $0.count <= ScreenTextEvidence.maximumLineCharacters + 1 })
  // The repeated line was already used: only the new line remains.
  #expect(first[1].text == "fresh")
  // Per-segment cap: further entries are replaced by one omission marker.
  var segmentBudget = ScreenTextEvidence.Budget()
  let capped = ScreenTextEvidence.items((0..<40).map { entry(1, Double($0 * 10), ["unique \($0) " + String(repeating: "a", count: 150)]) }, budget: &segmentBudget)
  #expect(capped.last?.text == ScreenTextEvidence.omittedMarker)
  #expect(capped.dropLast().map(\.text.count).reduce(0, +) <= ScreenTextEvidence.maximumCharactersPerSegment)
  // Range filter for selections.
  var rangeBudget = ScreenTextEvidence.Budget()
  let ranged = ScreenTextEvidence.items([entry(1, 10, ["a"]), entry(1, 100, ["b"])], from: dayStart + 50, to: dayStart + 200, budget: &rangeBudget)
  #expect(ranged.map(\.text) == ["b"])
  let store = LifelogStore(root: URL(fileURLWithPath: "/"), calendar: utc)
  #expect(ScreenTextEvidence.line(ranged[0], store: store) == "[00:01:40] [screen 1] b")
}

@Test func dailyDigestUsesScreenTextAsLabelledEvidence() async throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: utc)
  _ = try segment(store, at: 3_600,
    turns: [TranscriptTurn(start: 30, end: 35, speaker: "", text: "let's ship friday", source: .microphone)],
    screen: [entry(1, 3_610, ["Release checklist"]), entry(2, 3_650, ["Release checklist", "Build 42 green"])])
  // A silent desktop segment still contributes what was on screen.
  let silent = try segment(store, at: 7_200, screen: [entry(1, 7_210, ["Quarterly report.xlsx"])])
  // Pending screen text is not yet evidence, and blocks the catch-up count.
  let waiting = try segment(store, at: 9_000, screen: nil)
  let entries = LifelogDigest.entries(store: store, day: "2026-10-08")
  #expect(entries.count == 2)
  #expect(entries[0].lines == [
    "[01:00:10] [screen 1] Release checklist",
    "[01:00:30] let's ship friday",
    "[01:00:50] [screen 2] Build 42 green",
  ])
  #expect(entries[0].file == LifelogStore.transcriptFileName)
  #expect(entries[1].lines == ["[02:00:10] [screen 1] Quarterly report.xlsx"])
  #expect(entries[1].file == LifelogStore.screenTextMarkdownFileName)
  #expect(LifelogDigest.isDigestible(try store.load(folder: silent)))
  #expect(!LifelogDigest.isDigestible(try store.load(folder: waiting)))
  #expect(LifelogDigest.isWaiting(try store.load(folder: waiting)))
  final class Box: @unchecked Sendable { var prompt = "" }
  let box = Box()
  let run = try await LifelogDigest.generate(store: store, day: "2026-10-08", label: nil, chunkCharacters: 12_000,
    language: .english, request: { prompt, _ in
      box.prompt = prompt
      return Data(#"{"overview":"o","periods":[],"actions":[],"reviews":[{"time":"02:00","segment":"S2","reason":"r"}]}"#.utf8)
    })
  #expect(run.status == .complete && run.segmentCount == 2)
  #expect(box.prompt.contains("[screen N]") && box.prompt.contains("OCR"))
  let markdown = try String(contentsOf: store.digestURL(day: "2026-10-08", label: nil), encoding: .utf8)
  #expect(markdown.contains("/screen-text.md)"))
}

@Test func selectionCarriesBoundedScreenEvidenceWithSourceLabels() throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: utc)
  let folder = try segment(store, at: 0,
    turns: [TranscriptTurn(start: 100, end: 110, speaker: "", text: "spoken", source: .system)],
    screen: [entry(1, 20, ["before range"]), entry(1, 90, ["Agenda", "Agenda"]), entry(2, 300, ["after range"])])
  let selection = try LifelogSelection.read(store: store, start: dayStart + 60, end: dayStart + 200, title: "Review")
  let source = try #require(selection.sources.first)
  #expect(source.screenItems?.map(\.text) == ["Agenda"])
  let entries = try selection.digestEntries(store: store)
  #expect(entries[0].lines == ["[00:01:30] [screen 1] Agenda", "[00:01:40] [system] spoken"])
  // Screen text alone is enough evidence for notes.
  let silent = try LifelogSelection.read(store: store, start: dayStart + 80, end: dayStart + 95, title: "")
  #expect(try silent.digestEntries(store: store)[0].lines == ["[00:01:30] [screen 1] Agenda"])
  let saved = try selection.save(in: store)
  let text = try String(contentsOf: saved.appending(path: "transcript.md"), encoding: .utf8)
  #expect(text.contains("[screen 1] Agenda"))
  #expect(text.contains("screen-text.md"))
  #expect(FileManager.default.fileExists(atPath: folder.path))
}

@MainActor @Test func jobExtendsLastEntriesToSegmentEndForRangeSelection() async throws {
  let root = TestTemporary.root.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = LifelogStore(root: root, calendar: utc)
  var item = try store.createSegment(id: UUID(), startedAt: dayStart)
  item.segment.screenRelativeFolder = "screen/2026-10-08/\(item.segment.id.uuidString.lowercased())"
  item.segment.screenText = .pending
  item.segment.endedAt = dayStart + 1_200
  try store.save(item.segment, in: item.folder)
  let outcome = await LifelogScreenTextJob.run(store: store, folder: item.folder, deleteVideos: true,
    extract: { _, start in
      // One static document shown from 60 s; its only keyframe is at 60 s.
      let entries = [ScreenTextEntry(displayID: 1, startedAt: start + 60, endedAt: start + 60,
        startOffset: 60, endOffset: 60, keyframes: 1, lines: ["Design doc v3"])]
      var stats = ScreenTextStats(); stats.entries = 1; stats.characters = 13
      return ScreenTextExtraction(entries: entries, stats: stats, failures: [], estimatedTimeDisplays: [])
    })
  #expect(outcome == .complete)
  let entry = try #require(store.screenTextDocument(in: item.folder)?.entries.first)
  #expect(entry.endedAt == dayStart + 1_200 && entry.endOffset == 1_200)
  // A selection in the middle of the static period still sees it.
  let selection = try LifelogSelection.read(store: store, start: dayStart + 600, end: dayStart + 700, title: "")
  #expect(selection.sources.first?.screenItems?.map(\.text) == ["Design doc v3"])
}
