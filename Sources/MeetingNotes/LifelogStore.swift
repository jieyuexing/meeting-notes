import Foundation

/// Why a lifelog segment ended.
enum LifelogCutReason: String, Codable, Sendable {
  case silence, maximumDuration, midnight, meeting, sleep, stopped, deviceChange, recovered
}

/// `segment.json` of one always-on segment. Field names are read by the
/// experiment's sampling and report scripts; keep them stable.
struct LifelogSegment: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    /// Audio is still being written.
    case recording
    /// Closed, waiting for final transcription.
    case pending
    case complete
    /// Audio had signal but the recognizer returned no text.
    case empty
    /// Transcription failed; the audio is kept.
    case failed
  }

  var id: UUID
  var startedAt: Date
  var endedAt: Date?
  var status: Status
  var closeReason: LifelogCutReason?
  var audioSeconds: Double?
  var speechSeconds: Double?
  var characterCount: Int?
  var language: String?
  var transcriptionStartedAt: Date?
  var transcribedAt: Date?
  var error: String?
  var transcript: [TranscriptTurn]?
  /// Independent screen directory; never subject to audio retention/silence deletion.
  var screenRelativeFolder: String?
  var media: UnifiedCaptureMetadata?
  /// Owned by the screen-text queue; audio-side saves keep the on-disk value.
  var screenText: LifelogScreenTextState?
  /// When the screen videos were deleted after their text was saved.
  var screenDeletedAt: Date?
}

/// Per-day counters for segments that were never kept.
struct LifelogDayStats: Codable, Equatable, Sendable {
  var silentSegmentsDiscarded = 0
  var silentSecondsDiscarded: Double = 0
}

/// Lifelog storage, separate from `MeetingStore`:
///
/// ```
/// <root>/YYYY-MM-DD/HHmmss-<id8>/segment.json, transcript.md, microphone.wav (until transcribed)
/// <root>/YYYY-MM-DD/HHmmss-<id8>/screen-text.json, screen-text.md   recognised screen text
/// <root>/YYYY-MM-DD/day.json                    silent-segment counters
/// <root>/digest/YYYY-MM-DD[.<label>].md / .json daily digest and its run record
/// ```
///
/// A segment belongs to the local calendar day on which it started; the
/// recorder also requests a cut on the first tick after midnight. Any late
/// tick or audio buffer crossing midnight stays with the starting day.
struct LifelogStore: Sendable {
  static let segmentFileName = "segment.json"
  static let transcriptFileName = "transcript.md"
  static let audioFileName = "microphone.wav"

  let root: URL
  let calendar: Calendar

  init(root: URL, calendar: Calendar = .autoupdatingCurrent) {
    self.root = root.standardizedFileURL
    self.calendar = calendar
  }

  var digestFolder: URL { root.appending(path: "digest", directoryHint: .isDirectory) }

  func dayKey(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  func clockText(_ date: Date, seconds: Bool = true) -> String {
    let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
    return seconds
      ? String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
      : String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  func audioURL(in folder: URL) -> URL { folder.appending(path: Self.audioFileName) }

  /// Optional for historical microphone-only segments.
  func systemAudioURL(in folder: URL) -> URL { folder.appending(path: "system.wav") }

  func createSegment(id: UUID, startedAt: Date) throws -> (segment: LifelogSegment, folder: URL) {
    let compact = clockText(startedAt).replacingOccurrences(of: ":", with: "")
    let folder = root
      .appending(path: dayKey(startedAt), directoryHint: .isDirectory)
      .appending(path: "\(compact)-\(id.uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let segment = LifelogSegment(id: id, startedAt: startedAt, status: .recording)
    try save(segment, in: folder)
    return (segment, folder)
  }

  func save(_ segment: LifelogSegment, in folder: URL) throws {
    try Self.encoder.encode(segment).write(
      to: folder.appending(path: Self.segmentFileName), options: .atomic)
  }

  func load(folder: URL) throws -> LifelogSegment {
    try Self.decoder.decode(
      LifelogSegment.self, from: Data(contentsOf: folder.appending(path: Self.segmentFileName)))
  }

  /// Removes a segment that never contained meaningful signal and counts it.
  func discardSilentSegment(_ segment: LifelogSegment, in folder: URL, seconds: Double) throws {
    guard segment.screenRelativeFolder == nil else {
      try complete(segment, in: folder, turns: [], transcriptionStartedAt: Date(),
        transcribedAt: Date(), deleteAudio: true)
      return
    }
    let day = dayKey(segment.startedAt)
    var stats = dayStats(day)
    stats.silentSegmentsDiscarded += 1
    stats.silentSecondsDiscarded += max(0, seconds)
    try Self.encoder.encode(stats).write(to: dayStatsURL(day), options: .atomic)
    try FileManager.default.removeItem(at: folder)
  }

  /// Saves the final transcript. No text means the segment is kept only as
  /// an `empty` record, without `transcript.md`.
  func complete(
    _ segment: LifelogSegment, in folder: URL, turns: [TranscriptTurn],
    transcriptionStartedAt: Date, transcribedAt: Date, deleteAudio: Bool
  ) throws {
    var updated = segment
    let lines = TranscriptFormatter.mergedLines(turns)
    updated.transcriptionStartedAt = transcriptionStartedAt
    updated.transcribedAt = transcribedAt
    updated.error = nil
    updated.status = lines.isEmpty ? .empty : .complete
    updated.transcript = lines.isEmpty ? nil : turns
    updated.characterCount = lines.map(\.text.count).reduce(0, +)
    updated.speechSeconds = turns.map { max(0, $0.end - $0.start) }.reduce(0, +)
    updated.language = lines.isEmpty ? nil : TranscriptLanguageDetector.detect(turns)
    if !lines.isEmpty {
      try Data(transcriptMarkdown(updated, lines: lines).utf8).write(
        to: folder.appending(path: Self.transcriptFileName), options: .atomic)
    }
    try saveKeepingScreen(updated, in: folder)
    if deleteAudio || lines.isEmpty {
      for audio in [audioURL(in: folder), systemAudioURL(in: folder)] {
      if FileManager.default.fileExists(atPath: audio.path) {
        try FileManager.default.removeItem(at: audio)
      }
      }
    }
  }

  func markFailed(_ segment: LifelogSegment, in folder: URL, error: Error, startedAt: Date) throws {
    var updated = segment
    updated.status = .failed
    updated.transcriptionStartedAt = startedAt
    updated.error = error.localizedDescription
    try saveKeepingScreen(updated, in: folder)
  }

  /// Conservative root-change gate: unreadable metadata cannot prove drainage.
  func hasUnfinishedSegments() throws -> Bool {
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: root.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    for day in names where day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil {
      let directory = root.appending(path: day)
      for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name != "day.json" {
        let segment = try load(folder: directory.appending(path: name))
        if [.recording, .pending, .failed].contains(segment.status) { return true }
        if let screen = segment.screenText, screen.status != .complete
          || (screen.deleteRequested == true && segment.screenDeletedAt == nil) { return true }
      }
    }
    return false
  }

  /// Segments whose audio still waits for transcription, including crash recovery.
  func pendingFolders() -> [URL] {
    days().flatMap { segmentFolders(day: $0) }.filter { folder in
      guard let segment = try? load(folder: folder),
        segment.status == .pending || segment.status == .recording
      else { return false }
      return FileManager.default.fileExists(atPath: audioURL(in: folder).path)
    }
  }

  func segments(on day: String) -> [(segment: LifelogSegment, folder: URL)] {
    segmentFolders(day: day)
      .compactMap { folder in (try? load(folder: folder)).map { ($0, folder) } }
      .sorted { $0.segment.startedAt < $1.segment.startedAt }
  }

  func dayStats(_ day: String) -> LifelogDayStats {
    (try? Self.decoder.decode(LifelogDayStats.self, from: Data(contentsOf: dayStatsURL(day))))
      ?? LifelogDayStats()
  }

  func days() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter(Self.isDayKey).sorted()
  }

  func digestURL(day: String, label: String?) -> URL {
    digestFolder.appending(path: digestBaseName(day: day, label: label) + ".md")
  }

  func digestRunURL(day: String, label: String?) -> URL {
    digestFolder.appending(path: digestBaseName(day: day, label: label) + ".json")
  }

  func digestRun(day: String, label: String?) -> LifelogDigest.Run? {
    try? Self.decoder.decode(
      LifelogDigest.Run.self, from: Data(contentsOf: digestRunURL(day: day, label: label)))
  }

  func saveDigest(_ run: LifelogDigest.Run, markdown: String?) throws {
    try FileManager.default.createDirectory(
      at: digestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let markdown {
      try Data(markdown.utf8).write(to: digestURL(day: run.date, label: run.label), options: .atomic)
    }
    try Self.encoder.encode(run).write(to: digestRunURL(day: run.date, label: run.label), options: .atomic)
  }

  /// Wall-clock timestamps: lifelog lines are located by time of day, not
  /// by offset into a meeting.
  func transcriptMarkdown(_ segment: LifelogSegment, lines: [TranscriptFormatter.Line]) -> String {
    var output = "---\n"
    output += "segment: \(segment.id.uuidString)\n"
    output += "started_at: \(segment.startedAt.ISO8601Format())\n"
    if let endedAt = segment.endedAt { output += "ended_at: \(endedAt.ISO8601Format())\n" }
    if let language = segment.language { output += "language: \(language)\n" }
    output += "---\n\n"
    for line in lines {
      output += "**[\(clockText(segment.startedAt + line.start))]** \(line.text)\n\n"
    }
    return output
  }

  private func digestBaseName(day: String, label: String?) -> String {
    let clean = (label ?? "").filenameSafe
    return clean.isEmpty ? day : "\(day).\(clean)"
  }

  private func dayStatsURL(_ day: String) -> URL {
    root.appending(path: day, directoryHint: .isDirectory).appending(path: "day.json")
  }

  private func segmentFolders(day: String) -> [URL] {
    let dayFolder = root.appending(path: day, directoryHint: .isDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dayFolder.path)) ?? []
    return names.sorted().compactMap { name in
      let folder = dayFolder.appending(path: name, directoryHint: .isDirectory)
      return FileManager.default.fileExists(atPath: folder.appending(path: Self.segmentFileName).path)
        ? folder : nil
    }
  }

  private static func isDayKey(_ name: String) -> Bool {
    name.count == 10 && name.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
  }

  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
