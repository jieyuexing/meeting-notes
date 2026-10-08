import Foundation

/// `segment.json` → `screenText`: the screen-text queue's own state, separate
/// from the audio `status`. Segments recorded before this field existed have
/// no value and are never processed automatically.
struct LifelogScreenTextState: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    /// Waiting for (or interrupted during) recognition; videos are kept.
    case pending
    /// `screen-text.json` is saved.
    case complete
    /// Videos are kept with a readable error.
    case failed
  }

  var status: Status
  /// Failed recognition attempts; launch recovery stops at `maximumAttempts`.
  var attempts: Int
  var startedAt: Date?
  var completedAt: Date?
  var error: String?
  var stats: ScreenTextStats?
  /// First recognised lines, for the Today row without reading the full file.
  var preview: [String]?
  /// Recorded before deleting videos so an interrupted deletion is finished
  /// on recovery, and a later change of the setting never deletes old videos.
  var deleteRequested: Bool?

  static let maximumAttempts = 3
  static let pending = LifelogScreenTextState(status: .pending, attempts: 0)
}

/// `screen-text.json` in the segment folder (the screen subfolder is deleted).
struct ScreenTextDocument: Codable, Equatable, Sendable {
  var segmentID: UUID
  var segmentStartedAt: Date
  var segmentEndedAt: Date?
  var generatedAt: Date
  var engine: String
  /// Displays without first-frame metadata; their times start at the segment start.
  var estimatedTimeDisplays: [UInt32]
  var stats: ScreenTextStats
  var entries: [ScreenTextEntry]
}

/// What Today shows for one segment, read from `segment.json` only; the full
/// lines are loaded from `screen-text.json` when a row is expanded.
struct ScreenTextSummary: Equatable, Sendable {
  var segmentID: UUID
  var startedAt: Date
  var status: LifelogScreenTextState.Status
  var preview: [String]
  var characters: Int
  var keyframes: Int
  var error: String?
  var markdownURL: URL?
  /// Screen videos still on disk (deletion off, failed, pending or legacy).
  var videoFolder: URL?
  var videosDeleted: Bool
}

extension LifelogStore {
  static let screenTextFileName = "screen-text.json"
  static let screenTextMarkdownFileName = "screen-text.md"
  static let screenTextEngine = "Apple Vision VNRecognizeTextRequest (accurate, zh-Hans/ja-JP/en-US, automatic language detection, on device)"

  func screenTextURL(in folder: URL) -> URL { folder.appending(path: Self.screenTextFileName) }
  func screenTextMarkdownURL(in folder: URL) -> URL { folder.appending(path: Self.screenTextMarkdownFileName) }

  func screenFolder(for segment: LifelogSegment) -> URL? {
    segment.screenRelativeFolder.map { root.appending(path: $0, directoryHint: .isDirectory) }
  }

  /// The per-display videos actually on disk, with first-frame times from the
  /// capture metadata when available.
  func screenVideos(for segment: LifelogSegment) -> [ScreenTextVideo] {
    guard let folder = screenFolder(for: segment),
      let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return [] }
    return names.sorted().compactMap { name in
      guard let match = name.wholeMatch(of: /screen-(\d+)\.mp4/), let id = UInt32(match.1) else { return nil }
      let firstFrame = segment.media?.displays.first { $0.displayID == id }?.actualFirstFrameAt
      return ScreenTextVideo(displayID: id, url: folder.appending(path: name), firstFrameAt: firstFrame)
    }
  }

  /// Re-read, change and atomically write without suspension, so concurrent
  /// audio and screen queues on the main actor never write stale copies.
  @discardableResult
  func update(in folder: URL, _ change: (inout LifelogSegment) throws -> Void) throws -> LifelogSegment {
    var segment = try load(folder: folder)
    try change(&segment)
    try save(segment, in: folder)
    return segment
  }

  /// Audio-side save: every field comes from `segment` except the screen-text
  /// fields, which keep their on-disk values (the screen queue owns them).
  func saveKeepingScreen(_ segment: LifelogSegment, in folder: URL) throws {
    var merged = segment
    if let current = try? load(folder: folder) {
      merged.screenText = current.screenText
      merged.screenDeletedAt = current.screenDeletedAt
    }
    try save(merged, in: folder)
  }

  func screenTextDocument(in folder: URL) -> ScreenTextDocument? {
    try? Self.decoder.decode(ScreenTextDocument.self, from: Data(contentsOf: screenTextURL(in: folder)))
  }

  /// `screen-text.md` is written only when some text was recognised, like
  /// `transcript.md`; the JSON is always written.
  func saveScreenText(_ document: ScreenTextDocument, in folder: URL) throws {
    let markdown = screenTextMarkdownURL(in: folder)
    if document.entries.isEmpty {
      if FileManager.default.fileExists(atPath: markdown.path) { try FileManager.default.removeItem(at: markdown) }
    } else {
      try Data(screenTextMarkdown(document).utf8).write(to: markdown, options: .atomic)
    }
    try Self.encoder.encode(document).write(to: screenTextURL(in: folder), options: .atomic)
  }

  /// Deletes only `screen-<id>.mp4` files of this segment, then its screen
  /// folder if nothing else is left. The day folder is never removed.
  func deleteScreenVideos(for segment: LifelogSegment) throws {
    for video in screenVideos(for: segment) {
      try FileManager.default.removeItem(at: video.url)
    }
    if let folder = screenFolder(for: segment),
      let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path), rest.isEmpty
    {
      try FileManager.default.removeItem(at: folder)
    }
  }

  /// Segments whose screen text should be (re)started on launch: pending or
  /// interrupted work, failures below the attempt limit, and unfinished
  /// deletions. Legacy segments without `screenText` are excluded.
  func screenTextRecoveryFolders(excluding current: URL? = nil) -> [URL] {
    allSegments().filter { item in
      guard item.folder != current, let state = item.segment.screenText else { return false }
      switch state.status {
      case .pending: return true
      case .failed: return state.attempts < LifelogScreenTextState.maximumAttempts
      case .complete: return state.deleteRequested == true && item.segment.screenDeletedAt == nil
      }
    }.map(\.folder)
  }

  /// Segments recorded before screen text existed that still have videos.
  func legacyScreenFolders(excluding current: URL? = nil) -> [URL] {
    allSegments().filter { item in
      item.folder != current && item.segment.screenText == nil && !screenVideos(for: item.segment).isEmpty
    }.map(\.folder)
  }

  func screenTextMarkdown(_ document: ScreenTextDocument) -> String {
    var output = "---\n"
    output += "segment: \(document.segmentID.uuidString)\n"
    output += "started_at: \(document.segmentStartedAt.ISO8601Format())\n"
    if let ended = document.segmentEndedAt { output += "ended_at: \(ended.ISO8601Format())\n" }
    output += "displays: \(Set(document.entries.map(\.displayID)).sorted().map(String.init).joined(separator: ", "))\n"
    output += "keyframes: \(document.stats.keyframes)\n"
    output += "characters: \(document.stats.characters)\n"
    output += "engine: \(document.engine)\n"
    output += "---\n\n"
    output += "> 本机 OCR 从屏幕录像识别的画面文字，可能有识别错误；只表示该时段屏幕上可见的内容，不代表人的关注。\n\n"
    if !document.estimatedTimeDisplays.isEmpty {
      output += "> 显示器 \(document.estimatedTimeDisplays.map(String.init).joined(separator: ", ")) 缺少首帧时间，时间按段起点估算。\n\n"
    }
    for entry in document.entries {
      let span = entry.keyframes > 1
        ? "\(clockText(entry.startedAt))–\(clockText(entry.endedAt))" : clockText(entry.startedAt)
      output += "### \(span) · 显示器 \(entry.displayID)\n\n````text\n"
      output += entry.lines.joined(separator: "\n")
      output += "\n````\n\n"
    }
    return output
  }

  /// nil for segments recorded before screen text existed.
  func screenTextSummary(_ segment: LifelogSegment, folder: URL) -> ScreenTextSummary? {
    guard let state = segment.screenText else { return nil }
    let markdown = screenTextMarkdownURL(in: folder)
    let videos = screenFolder(for: segment).flatMap {
      FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
    }
    return ScreenTextSummary(segmentID: segment.id, startedAt: segment.startedAt, status: state.status,
      preview: state.preview ?? [], characters: state.stats?.characters ?? 0, keyframes: state.stats?.keyframes ?? 0,
      error: state.error, markdownURL: FileManager.default.fileExists(atPath: markdown.path) ? markdown : nil,
      videoFolder: videos, videosDeleted: segment.screenDeletedAt != nil)
  }

  private func allSegments() -> [(segment: LifelogSegment, folder: URL)] {
    days().flatMap { segments(on: $0) }
  }
}

/// Processes one segment folder. Must run on the main actor with the audio
/// queue so `segment.json` read-modify-write steps never interleave; only the
/// extraction itself runs elsewhere.
@MainActor
enum LifelogScreenTextJob {
  typealias Extract = @Sendable (_ videos: [ScreenTextVideo], _ segmentStart: Date) async throws -> ScreenTextExtraction

  enum Outcome: Equatable {
    case complete
    case failed(String)
    /// Interrupted by quit; stays pending and restarts from the beginning.
    case cancelled
    case skipped
  }

  static let defaultExtract: Extract = { videos, start in
    try await ScreenTextExtractor.extract(videos: videos, segmentStart: start)
  }

  static func run(
    store: LifelogStore, folder: URL, deleteVideos: Bool, extract: Extract,
    now: @Sendable () -> Date = { Date() }
  ) async -> Outcome {
    guard let segment = try? store.load(folder: folder), segment.screenRelativeFolder != nil,
      let state = segment.screenText
    else { return .skipped }
    if state.status == .complete {
      guard state.deleteRequested == true, segment.screenDeletedAt == nil else { return .skipped }
      return finishDeletion(store: store, folder: folder, segment: segment, now: now)
    }
    let started = now()
    do {
      _ = try store.update(in: folder) {
        $0.screenText?.status = .pending
        $0.screenText?.startedAt = started
      }
      let videos = store.screenVideos(for: segment)
      let extraction = try await extract(videos, segment.startedAt)
      if extraction.stats.failures > 0 {
        let message = "\(extraction.stats.failures) screen keyframes could not be recognized: "
          + (extraction.failures.first ?? "")
        _ = try store.update(in: folder) {
          $0.screenText?.status = .failed
          $0.screenText?.attempts += 1
          $0.screenText?.error = message
          $0.screenText?.stats = extraction.stats
        }
        return .failed(message)
      }
      let document = ScreenTextDocument(segmentID: segment.id, segmentStartedAt: segment.startedAt,
        segmentEndedAt: segment.endedAt ?? segment.media?.endedAt, generatedAt: now(),
        engine: LifelogStore.screenTextEngine, estimatedTimeDisplays: extraction.estimatedTimeDisplays,
        stats: extraction.stats, entries: extraction.entries)
      try store.saveScreenText(document, in: folder)
      let completed = try store.update(in: folder) {
        $0.screenText?.status = .complete
        $0.screenText?.completedAt = now()
        $0.screenText?.error = nil
        $0.screenText?.stats = extraction.stats
        $0.screenText?.preview = Array(extraction.entries.flatMap(\.lines).prefix(3))
        $0.screenText?.deleteRequested = deleteVideos && !videos.isEmpty
      }
      guard completed.screenText?.deleteRequested == true else { return .complete }
      return finishDeletion(store: store, folder: folder, segment: completed, now: now)
    } catch is CancellationError {
      return .cancelled
    } catch {
      let message = error.localizedDescription
      _ = try? store.update(in: folder) {
        $0.screenText?.status = .failed
        $0.screenText?.attempts += 1
        $0.screenText?.error = message
      }
      return .failed(message)
    }
  }

  private static func finishDeletion(
    store: LifelogStore, folder: URL, segment: LifelogSegment, now: () -> Date
  ) -> Outcome {
    do {
      try store.deleteScreenVideos(for: segment)
      _ = try store.update(in: folder) {
        $0.screenDeletedAt = now()
        $0.screenText?.error = nil
      }
      return .complete
    } catch {
      // Text is saved; the videos stay and launch recovery deletes them later.
      let message = "Screen video could not be deleted: " + error.localizedDescription
      _ = try? store.update(in: folder) { $0.screenText?.error = message }
      return .failed(message)
    }
  }
}

/// Bounded screen-text evidence for selections and daily digests. Limits keep
/// OCR from crowding out speech: identical lines appear once per digest or
/// selection (first occurrence in time order), each entry contributes at most
/// 10 lines of ≤160 characters, each segment ≤3 000 and the whole input
/// ≤40 000 characters; where a limit cuts text an omission marker tells the
/// model the screen evidence is partial.
enum ScreenTextEvidence {
  static let maximumLinesPerEntry = 10
  static let maximumLineCharacters = 160
  static let maximumCharactersPerSegment = 3_000
  static let maximumCharactersTotal = 40_000
  static let omittedMarker = "…(more screen text omitted)"
  private static let separator = " / "

  struct Item: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date
    var displayID: UInt32
    var text: String
  }

  struct Budget {
    var used = 0
    var seen = Set<String>()
  }

  static func items(
    _ entries: [ScreenTextEntry], from start: Date? = nil, to end: Date? = nil, budget: inout Budget
  ) -> [Item] {
    var items: [Item] = []
    var segmentCharacters = 0
    for entry in entries.sorted(by: { $0.startedAt < $1.startedAt }) {
      if let start, entry.endedAt < start { continue }
      if let end, entry.startedAt >= end { continue }
      var lines: [String] = []
      var length = 0
      var exhausted = false
      for line in entry.lines {
        guard lines.count < maximumLinesPerEntry else { break }
        let key = ScreenTextLayout.key(line)
        guard !key.isEmpty, !budget.seen.contains(key) else { continue }
        let clipped = line.count > maximumLineCharacters ? String(line.prefix(maximumLineCharacters)) + "…" : line
        let cost = clipped.count + (lines.isEmpty ? 0 : separator.count)
        guard segmentCharacters + length + cost <= maximumCharactersPerSegment,
          budget.used + length + cost <= maximumCharactersTotal
        else { exhausted = true; break }
        budget.seen.insert(key)
        lines.append(clipped)
        length += cost
      }
      if !lines.isEmpty {
        segmentCharacters += length
        budget.used += length
        items.append(Item(startedAt: entry.startedAt, endedAt: entry.endedAt, displayID: entry.displayID,
          text: lines.joined(separator: separator)))
      }
      if exhausted {
        items.append(Item(startedAt: entry.startedAt, endedAt: entry.endedAt, displayID: entry.displayID, text: omittedMarker))
        break
      }
    }
    return items
  }

  /// The source tag is fixed English, like the `[microphone]`/`[system]` tags.
  static func line(_ item: Item, store: LifelogStore) -> String {
    "[\(store.clockText(item.startedAt))] [screen \(item.displayID)] \(item.text)"
  }
}
