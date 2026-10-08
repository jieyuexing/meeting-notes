import AppKit
import SwiftUI

struct DailyEvidenceTimeline: View {
  @Bindable var lifelog: LifelogController
  let segments: [TodayLifelogSummary]
  let day: Date
  @Environment(\.locale) private var locale
  @State private var inspected: TodayLifelogSummary?
  /// Loaded from the bounded segment list outside `body`, refreshed when the
  /// list or any screen-text result changes.
  @State private var screenTexts: [UUID: ScreenTextSummary] = [:]
  @State private var expandedScreenText: [UUID: [String]] = [:]
  static let expandedScreenLines = 60

  private struct Row: Identifiable {
    let id: String; let date: Date; let media: TodayLifelogSummary?; let message: T3ActivityCollector.Message?; var run: T3ActivityCollector.Run? = nil
    var screen: ScreenTextSummary? = nil
  }
  private struct ScreenTextKey: Equatable { let segments: [TodayLifelogSummary]; let revision: Int }
  private var rows: [Row] {
    let messages = lifelog.t3Snapshot.messages.filter {
      Calendar.current.isDate($0.createdAt, inSameDayAs: day) || Calendar.current.isDate($0.updatedAt, inSameDayAs: day)
    }.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
    let shown = Set(messages.compactMap { $0.runId })
    let start = Calendar.current.startOfDay(for: day)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
    let runs = lifelog.t3Snapshot.runs.filter { !shown.contains($0.id) && $0.requestedAt < end && ($0.completedAt ?? Date()) >= start }.sorted { ($0.completedAt ?? $0.requestedAt) > ($1.completedAt ?? $1.requestedAt) }.prefix(12)
    // A screen-text row sits just after its segment's media row.
    let screens = segments.compactMap { screenTexts[$0.id] }.map {
      Row(id: "screen-" + $0.segmentID.uuidString, date: $0.startedAt.addingTimeInterval(0.001), media: nil, message: nil, screen: $0)
    }
    return (segments.map { Row(id: $0.id.uuidString, date: $0.startedAt, media: $0, message: nil) }
      + screens
      + messages.map { Row(id: $0.threadId + $0.id, date: $0.updatedAt, media: nil, message: $0) }
      + runs.map { Row(id: "run-" + $0.threadId + $0.id, date: $0.completedAt ?? $0.startedAt ?? $0.requestedAt, media: nil, message: nil, run: $0) })
      .sorted { $0.date > $1.date }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(UIStrings.text("Daily timeline")).font(.caption.weight(.semibold))
      Text(t3Status).font(.caption2).foregroundStyle(.secondary)
      Text(UIStrings.text("Time overlap only · no human-focus inference")).font(.caption2).foregroundStyle(.secondary)
      ForEach(rows) { row in
        HStack(alignment: .top) {
          Text(row.date, style: .time).font(.caption2.monospacedDigit())
          if let media = row.media {
            Button { inspected = media } label: {
              VStack(alignment: .leading) {
                Label(UIStrings.resolve(media.screenFolder == nil ? "Microphone" : "Screen + microphone + system"), systemImage: "waveform")
                Text(UIStrings.string(status(media.status), language: .displayed(for: locale)))
              }
            }.buttonStyle(.plain)
          } else if let message = row.message {
            VStack(alignment: .leading, spacing: 3) {
              let thread = lifelog.t3Snapshot.threads.first { $0.id == message.threadId }
              Text(UIStrings.text("T3 · \(thread?.title ?? "T3")")).fontWeight(.medium)
              Text(UIStrings.string(message.role == "user" ? "Request" : (message.status == "final" ? "Final reply" : "Reply in progress"), language: .displayed(for: locale)))
              if let text = message.text { Text(text).lineLimit(2) }
              if message.textTruncated { Text(UIStrings.text("Excerpt truncated · open original thread")) }
              if let run = lifelog.t3Snapshot.runs.first(where: { $0.id == message.runId && $0.threadId == message.threadId }) {
                Text(UIStrings.string(run.status, language: .displayed(for: locale)))
              }
              if let link = thread?.link, let url = T3ActivityCollector.threadURL(link) {
                Button(UIStrings.text("Open T3 thread")) { NSWorkspace.shared.open(url) }
              }
            }
          }
          if let screen = row.screen { screenTextRow(screen) }
          if let run = row.run {
            let thread = lifelog.t3Snapshot.threads.first { $0.id == run.threadId }
            VStack(alignment: .leading) {
              Text(UIStrings.text("T3 · \(thread?.title ?? "T3")"))
              Text(UIStrings.resolve(run.status))
              if let link = thread?.link, let url = T3ActivityCollector.threadURL(link) {
                Button(UIStrings.text("Open T3 thread")) { NSWorkspace.shared.open(url) }
              }
            }
          }
          Spacer(minLength: 0)
        }.font(.caption).padding(.vertical, 3)
      }
      if !lifelog.t3Snapshot.threads.isEmpty {
        Button(UIStrings.text("All T3 evidence…")) { NSWorkspace.shared.open(lifelog.store.root.appending(path: "t3/activity.json")) }
          .font(.caption)
      }
    }.padding(10)
      .task(id: ScreenTextKey(segments: segments, revision: lifelog.screenTextRevision)) {
        var loaded: [UUID: ScreenTextSummary] = [:]
        for segment in segments {
          if let record = try? lifelog.store.load(folder: segment.folder),
            let summary = lifelog.store.screenTextSummary(record, folder: segment.folder)
          { loaded[segment.id] = summary }
        }
        screenTexts = loaded
        expandedScreenText = expandedScreenText.filter { loaded[$0.key]?.status == .complete }
      }
      .sheet(item: $inspected) { segment in
        VStack(alignment: .leading, spacing: 12) {
          Text(UIStrings.text("Recording sources")).font(.headline)
          Text(segment.startedAt, style: .date)
          Text(UIStrings.string(status(segment.status), language: .displayed(for: locale)))
          if let error = segment.error { Text(UIStrings.resolve(error)).foregroundStyle(.orange).textSelection(.enabled) }
          Button(UIStrings.text("Open transcript / audio folder")) { NSWorkspace.shared.open(segment.folder) }
          if segment.screenFolder != nil {
            let screen = screenTexts[segment.id]
            if let markdown = screen?.markdownURL {
              Button(UIStrings.text("Open screen text")) { NSWorkspace.shared.open(markdown) }
            }
            if let folder = screen == nil ? segment.screenFolder : screen?.videoFolder {
              Button(UIStrings.text("Open screen recordings")) { NSWorkspace.shared.open(folder) }
            }
            Text(UIStrings.string(screenSourceText(screen), language: .displayed(for: locale)))
            if let media = segment.media {
              ForEach(media.displays, id: \.displayID) { display in
                Text(UIStrings.text("Display \(display.displayID) · dropped frames: \(display.droppedFrames)"))
              }
              if let failure = media.failure { Text(UIStrings.resolve(failure)).foregroundStyle(.orange) }
            } else { Text(UIStrings.text("Screen finalization is pending or was interrupted.")) }
          }
          Button(UIStrings.text("Done")) { inspected = nil }
        }.padding(24).frame(width: 500)
      }
  }
  @ViewBuilder
  private func screenTextRow(_ screen: ScreenTextSummary) -> some View {
    let language = UILanguage.displayed(for: locale)
    VStack(alignment: .leading, spacing: 3) {
      Label(UIStrings.text("Screen text"), systemImage: "text.viewfinder").fontWeight(.medium)
      switch screen.status {
      case .pending: Text(UIStrings.text("Recognizing screen text…"))
      case .failed:
        Text(UIStrings.text("Screen text failed; videos are kept for retry.")).foregroundStyle(.orange)
        if let error = screen.error { Text(UIStrings.resolve(error, language: language)).lineLimit(2) }
      case .complete where screen.characters == 0: Text(UIStrings.text("No text on screen"))
      case .complete:
        Text(UIStrings.text("\(screen.characters) characters · \(screen.keyframes) frames recognized"))
          .foregroundStyle(.secondary)
        if let lines = expandedScreenText[screen.segmentID] {
          ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).textSelection(.enabled) }
          Button(UIStrings.text("Show less")) { expandedScreenText[screen.segmentID] = nil }
        } else {
          ForEach(Array(screen.preview.enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }
          Button(UIStrings.text("Show more")) { expandScreenText(screen) }
        }
        if let markdown = screen.markdownURL {
          Button(UIStrings.text("Open screen text")) { NSWorkspace.shared.open(markdown) }
        }
      }
    }
  }

  private func expandScreenText(_ screen: ScreenTextSummary) {
    guard let segment = segments.first(where: { $0.id == screen.segmentID }) else { return }
    let lines = lifelog.store.screenTextDocument(in: segment.folder)?.entries.flatMap { entry in
      ["\(entry.startedAt.formatted(.dateTime.hour().minute().second().locale(locale))) · \(UIStrings.text("Display \(entry.displayID)"))"] + entry.lines
    } ?? []
    expandedScreenText[screen.segmentID] = Array(lines.prefix(Self.expandedScreenLines))
  }

  private func screenSourceText(_ screen: ScreenTextSummary?) -> String {
    guard let screen else { return "Recorded before screen text. Convert earlier recordings in Settings." }
    switch screen.status {
    case .pending: return "Recognizing screen text…"
    case .failed: return "Screen text failed; videos are kept for retry."
    case .complete: return screen.videosDeleted
      ? "Screen text was recognized on this Mac; the videos were deleted."
      : "Screen text was recognized on this Mac; the videos are kept."
    }
  }

  private func status(_ status: LifelogSegment.Status) -> String {
    switch status { case .recording: "Recording"; case .pending: "Transcribing"; case .complete: "Transcript ready"; case .empty: "No speech"; case .failed: "Transcription failed" }
  }
  private var t3Status: String {
    let language = UILanguage.displayed(for: locale)
    switch lifelog.t3State {
    case .stopped: return UIStrings.string("T3 observation stopped", language: language)
    case .idle: return UIStrings.string("T3 connected · updated every minute", language: language)
    case .polling: return UIStrings.string("Checking T3…", language: language)
    case .unsupported(let error), .failed(let error): return UIStrings.string("T3 unavailable: ", language: language) + UIStrings.resolve(error)
    }
  }
}

extension T3ActivityCollector {
  static func threadURL(_ link: String) -> URL? {
    let raw: String
    if let range = link.range(of: "t3-thread://"), let end = link[range.lowerBound...].firstIndex(of: ")") {
      raw = String(link[range.lowerBound..<end])
    } else { raw = link }
    guard let url = URL(string: raw), url.scheme == "t3-thread" else { return nil }
    return url
  }
}

struct RecordingSelectionView: View {
  @Bindable var lifelog: LifelogController
  let day: Date
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var start = Date()
  @State private var end = Date()
  @State private var title = ""
  @State private var selection: LifelogSelection?
  @State private var output: URL?
  @State private var status = ""
  @State private var running = false
  @State private var generationTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(UIStrings.text("Review recording / mark a meeting")).font(.title2)
      TextField(UIStrings.text("Title"), text: $title).disabled(running)
      DatePicker(UIStrings.text("From"), selection: $start).disabled(running)
      DatePicker(UIStrings.text("To"), selection: $end).disabled(running)
      Text(UIStrings.text("Uses finished transcripts and recognized screen text without another recognition pass. Boundary-crossing sentences are kept in full. Pending and failed sources remain visible."))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(UIStrings.text("Load selected sources")) { readSelection() }.disabled(running)
        Button(UIStrings.text("Save marked selection")) { saveSelection() }.disabled(selection == nil || running)
        Button(UIStrings.text("Generate meeting notes")) { generate() }
          .disabled(selection == nil || running || lifelog.settings.digestBackend != .command || lifelog.settings.digestBackendSettings == nil)
      }
      if lifelog.settings.digestBackend != .command || lifelog.settings.digestBackendSettings == nil {
        Text(UIStrings.text("Configure a local daily-digest command to generate notes. Off or an unconfigured backend makes no model request."))
          .font(.caption).foregroundStyle(.orange)
      }
      if let selection {
        if selection.hasIncompleteSources { Text(UIStrings.text("Some sources are pending or failed; the notes will be incomplete.")).foregroundStyle(.orange) }
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(selection.sources, id: \.segmentID) { source in
              Text(source.relativeFolder).font(.caption.monospaced())
              Text(UIStrings.string(source.status.rawValue, language: .displayed(for: locale)))
              ForEach(source.lines, id: \.turnID) { line in
                Text(UIStrings.text("[\(line.startedAt.formatted(.dateTime.hour().minute().second().locale(locale)))] [\(UIStrings.string(line.source.rawValue, language: .displayed(for: locale)))] \(line.text)"))
                  .textSelection(.enabled)
              }
              ForEach(Array((source.screenItems ?? []).enumerated()), id: \.offset) { _, item in
                Text(UIStrings.text("[\(item.startedAt.formatted(.dateTime.hour().minute().second().locale(locale)))] [Screen \(item.displayID)] \(item.text)"))
                  .textSelection(.enabled)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 220)
      }
      if !status.isEmpty { Text(UIStrings.resolve(status)).font(.caption).textSelection(.enabled) }
      if let output { Button(UIStrings.text("Open saved selection")) { NSWorkspace.shared.open(output) } }
      HStack { if running { ProgressView().controlSize(.small) }; Spacer(); Button(UIStrings.text("Done")) { generationTask?.cancel(); dismiss() } }
    }.padding(24).frame(width: 680)
      .onAppear { start = Calendar.current.startOfDay(for: day); end = min(Date(), Calendar.current.date(byAdding: .day, value: 1, to: start)!) }
      .onChange(of: start) { selection = nil; output = nil }
      .onChange(of: end) { selection = nil; output = nil }
      .onChange(of: title) { selection?.title = title }
      .onChange(of: lifelog.settings.rootPath) { generationTask?.cancel(); selection = nil; output = nil; status = "" }
      .onDisappear { generationTask?.cancel() }
  }
  private func readSelection() {
    do {
      selection = try LifelogSelection.read(store: lifelog.store, start: start, end: end, title: title)
      status = ""; output = nil
    } catch { status = UIStrings.string("Choose a valid time range of up to 48 hours.", language: .displayed(for: locale)) }
  }
  private func saveSelection() {
    guard let selection else { return }
    output = nil
    do {
      output = try selection.save(in: lifelog.store)
      if let output {
        // Keep attribution and time overlap in a separate reference artifact.
        let messages = lifelog.t3Snapshot.messages.filter { $0.createdAt < end && $0.updatedAt >= start }
        var references = "# Replay / task references\n\nTime overlap only; not proof of human focus. Screen text is local OCR and may contain recognition errors.\n\n"
        for source in selection.sources {
          // Videos are usually deleted once their text is saved.
          if let text = source.screenTextFile { references += "- [Screen text](../../\(text))\n" }
          if let segment = try? lifelog.store.load(folder: lifelog.store.root.appending(path: source.relativeFolder)),
            let screen = segment.screenRelativeFolder,
            FileManager.default.fileExists(atPath: lifelog.store.root.appending(path: screen).path)
          { references += "- [Screen](../../\(screen))\n" }
        }
        for message in messages {
          let thread = lifelog.t3Snapshot.threads.first { $0.id == message.threadId }
          references += "\n- \(message.updatedAt.ISO8601Format()) · T3 · \(message.role) · \(message.status) · \(thread?.link ?? message.threadId)\n"
          if let text = message.text { references += "\n\(text)\n" }
        }
        for run in lifelog.t3Snapshot.runs where run.requestedAt < end && (run.completedAt ?? Date()) >= start {
          let thread = lifelog.t3Snapshot.threads.first { $0.id == run.threadId }
          references += "\n- T3 task · \(thread?.title ?? run.threadId) · \(run.status) · \(thread?.link ?? run.threadId)\n"
        }
        try Data(references.utf8).write(to: output.appending(path: "references.md"), options: .atomic)
      }
      status = UIStrings.string("Selection saved; source records unchanged.", language: .displayed(for: locale))
    } catch { status = error.localizedDescription }
  }
  private func generate() {
    guard let selection, lifelog.settings.digestBackend == .command,
      let backend = lifelog.settings.digestBackendSettings else { return }
    saveSelection()
    guard let output else { return }
    let store = lifelog.store; let settings = lifelog.settings
    running = true
    generationTask = Task {
      defer { running = false }
      do {
        let entries = try selection.digestEntries(store: store)
        let run = try await LifelogDigest.generate(store: store, day: selection.title.isEmpty ? store.dayKey(start) : selection.title,
          label: nil, chunkCharacters: settings.digestChunkCharacters, language: MeetingNotesLanguageStore.load(),
          request: LifelogDigest.request(for: backend), backendDescription: "Configured daily-digest command",
          selectedEntries: entries, outputFolder: output)
        status = run.status == .complete ? UIStrings.string("Meeting notes saved.", language: .displayed(for: locale))
          : UIStrings.string("Notes failed: ", language: .displayed(for: locale)) + (run.error ?? "")
      } catch LifelogSelection.SelectionError.noFinalText {
        status = UIStrings.string("No finished transcript in this range. Try again after transcription completes.", language: .displayed(for: locale))
      } catch is CancellationError { status = UIStrings.string("Cancelled", language: .displayed(for: locale)) }
      catch { status = error.localizedDescription }
    }
  }
}
