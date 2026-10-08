import Foundation

/// A review of existing records. Creating a selection never starts capture,
/// runs ASR, or moves the source segments into the meeting archive.
struct LifelogSelection: Codable, Equatable, Sendable, Identifiable {
  struct Line: Codable, Equatable, Sendable {
    let turnID: UUID
    let startedAt: Date
    let endedAt: Date
    let source: TranscriptTurn.Source
    let text: String
  }

  struct Source: Codable, Equatable, Sendable {
    let segmentID: UUID
    let relativeFolder: String
    let status: LifelogSegment.Status
    let lines: [Line]
    /// Recognised screen text overlapping the range, bounded and labelled.
    var screenItems: [ScreenTextEvidence.Item]? = nil
    /// Set when `screen-text.md` exists for the source segment.
    var screenTextFile: String? = nil
  }

  enum SelectionError: Error, Equatable {
    case invalidRange
    case rangeTooLong
    case noFinalText
  }

  let id: UUID
  let createdAt: Date
  let startedAt: Date
  let endedAt: Date
  var title: String
  let sources: [Source]

  var hasIncompleteSources: Bool {
    sources.contains { [.recording, .pending, .failed].contains($0.status) }
  }

  var lineCount: Int { sources.reduce(0) { $0 + $1.lines.count } }

  /// Intersect by absolute turn time, not just segment start. A turn crossing
  /// a selected boundary is retained in full, with its original timestamps;
  /// no attempt is made to invent a word-level cut or speaker identity.
  static func read(
    store: LifelogStore, start: Date, end: Date, title: String,
    now: Date = Date(), id: UUID = UUID()
  ) throws -> Self {
    guard start < end else { throw SelectionError.invalidRange }
    guard end.timeIntervalSince(start) <= 48 * 60 * 60 else {
      throw SelectionError.rangeTooLong
    }
    var sources: [Source] = []
    var budget = ScreenTextEvidence.Budget()
    // Include the preceding day for a segment whose midnight cut was late.
    var date = store.calendar.date(byAdding: .day, value: -1,
      to: store.calendar.startOfDay(for: start)) ?? start
    let last = store.calendar.startOfDay(for: end)
    while date <= last {
      let day = store.dayKey(date)
      for item in store.segments(on: day) {
        let segment = item.segment
        let segmentEnd = segment.endedAt
          ?? (segment.status == .recording ? now : segment.startedAt + (segment.audioSeconds ?? 0))
        guard segment.startedAt < end, segmentEnd > start else { continue }
        let lines: [Line] = segment.status == .complete
          ? (segment.transcript ?? []).compactMap { turn in
            let turnStart = segment.startedAt + turn.start
            let turnEnd = segment.startedAt + max(turn.start, turn.end)
            guard turnStart < end, turnEnd > start,
              !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Line(turnID: turn.id, startedAt: turnStart, endedAt: turnEnd,
              source: turn.source, text: turn.text)
          } : []
        let screen = segment.screenText?.status == .complete
          ? ScreenTextEvidence.items(store.screenTextDocument(in: item.folder)?.entries ?? [],
            from: start, to: end, budget: &budget) : []
        let relative = "\(day)/\(item.folder.lastPathComponent)"
        let screenFile = FileManager.default.fileExists(atPath: store.screenTextMarkdownURL(in: item.folder).path)
          ? "\(relative)/\(LifelogStore.screenTextMarkdownFileName)" : nil
        sources.append(Source(segmentID: segment.id, relativeFolder: relative,
          status: segment.status, lines: lines, screenItems: screen.isEmpty ? nil : screen,
          screenTextFile: screenFile))
      }
      guard let next = store.calendar.date(byAdding: .day, value: 1, to: date), next > date
      else { break }
      date = next
    }
    return Self(id: id, createdAt: now, startedAt: start, endedAt: end,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources)
  }

  func digestEntries(store: LifelogStore) throws -> [LifelogDigest.Entry] {
    let entries = sources.filter { !$0.lines.isEmpty || !($0.screenItems ?? []).isEmpty }.enumerated().map { index, source in
      let screen = source.screenItems ?? []
      let timed = screen.map { ($0.startedAt, ScreenTextEvidence.line($0, store: store)) }
        + source.lines.map { ($0.startedAt, "[\(store.clockText($0.startedAt))] [\($0.source.rawValue)] \($0.text)") }
      return LifelogDigest.Entry(label: "S\(index + 1)", folderPath: source.relativeFolder,
        startedAt: (source.lines.map(\.startedAt) + screen.map(\.startedAt)).min() ?? startedAt,
        endedAt: (source.lines.map(\.endedAt) + screen.map(\.endedAt)).max() ?? endedAt,
        lines: timed.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1),
        segmentID: source.segmentID,
        file: source.lines.isEmpty ? LifelogStore.screenTextMarkdownFileName : LifelogStore.transcriptFileName)
    }
    guard !entries.isEmpty else { throw SelectionError.noFinalText }
    return entries
  }

  /// Saves a new reference artifact, without altering any source segment.
  /// This retained text snapshot remains attributable even if the source is
  /// deliberately removed later. It is not a completed generated summary.
  func save(in store: LifelogStore) throws -> URL {
    let folder = store.root.appending(path: "selections", directoryHint: .isDirectory)
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder,
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: folder.appending(path: "selection.json"), options: .atomic)
    var text = "# \(title.isEmpty ? "Selected recording" : title)\n\n"
    text += "\(startedAt.ISO8601Format()) – \(endedAt.ISO8601Format())\n\n"
    text += "> Source excerpts, not a generated meeting summary. Boundary-crossing turns are retained in full.\n\n"
    for source in sources {
      text += "## \(source.segmentID.uuidString) · \(source.status.rawValue)\n\n"
      text += "[Source transcript](../../\(source.relativeFolder)/transcript.md)\n\n"
      if let screenFile = source.screenTextFile { text += "[Screen text (local OCR)](../../\(screenFile))\n\n" }
      for line in source.lines {
        text += "[\(line.startedAt.ISO8601Format()) – \(line.endedAt.ISO8601Format())] "
          + "[\(line.source.rawValue)] \(line.text)\n\n"
      }
      for item in source.screenItems ?? [] {
        text += "[\(item.startedAt.ISO8601Format()) – \(item.endedAt.ISO8601Format())] "
          + "[screen \(item.displayID)] \(item.text)\n\n"
      }
    }
    try Data(text.utf8).write(to: folder.appending(path: "transcript.md"), options: .atomic)
    return folder
  }
}
