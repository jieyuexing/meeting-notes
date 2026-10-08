import SwiftUI

/// Fork: Settings → Always-on. The only status surface of always-on mode;
/// the menu bar keeps showing meeting state.
struct LifelogSettingsPane: View {
  @Bindable var lifelog: LifelogController
  @State private var draft = LifelogSettings()
  @State private var rootDraft = ""
  @State private var loaded = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Always-on")
            .font(.title2.weight(.semibold))
          Text("Records the microphone continuously in segments, keeps on-device transcripts only, and writes one digest per day.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Divider()

        Toggle("Record continuously", isOn: Binding(
          get: { lifelog.settings.enabled },
          set: { enabled in Task { await lifelog.setEnabled(enabled) } }))
        statusSection

        Divider()

        Text("Segments")
          .font(.headline)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
          GridRow {
            Text("Folder")
              .gridColumnAlignment(.trailing)
            // Commits on Return only: every change of folder restarts capture.
            TextField(LifelogSettings.defaultRootPath, text: $rootDraft)
              .onSubmit { draft.rootPath = rootDraft }
          }
          GridRow {
            Text("End after silence")
            Stepper(
              "\(minutes(draft.silenceThreshold)) min", value: $draft.silenceThreshold,
              in: LifelogSettings.silenceRange, step: 30)
          }
          GridRow {
            Text("Longest segment")
            Stepper(
              "\(minutes(draft.maximumSegmentDuration)) min", value: $draft.maximumSegmentDuration,
              in: LifelogSettings.maximumSegmentRange, step: 300)
          }
        }
        Text("Microphone only, using the device chosen under Microphone. Each segment is transcribed with the final engine under Transcriptions (SenseVoice recommended; OpenAI is refused), and its audio follows the Storage retention setting. No live preview, per-segment notes, translation, sync or hooks. Recording a meeting pauses always-on capture until the meeting ends.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        Text("Daily digest")
          .font(.headline)
        Picker("Digest backend", selection: $draft.digestBackend) {
          ForEach(LifelogDigestBackend.allCases) { Text($0.label).tag($0) }
        }
        if draft.digestBackend == .command {
          TextField("Shell command; leave empty for no digest", text: $draft.digestCommand, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
        DatePicker("Daily at", selection: digestTime, displayedComponents: .hourAndMinute)
        HStack {
          Button(lifelog.digestRunning ? "Generating…" : "Generate today's digest now") {
            Task { await lifelog.generateDigest(day: lifelog.store.dayKey(Date())) }
          }
          .disabled(lifelog.digestRunning || draft.digestBackendSettings == nil)
          if lifelog.digestRunning { ProgressView().controlSize(.small) }
        }
        if !lifelog.digestStatusText.isEmpty {
          Text(lifelog.digestStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Text("Writes digest/YYYY-MM-DD.md in the folder above. A custom command follows the summary contract: the prompt and JSON schema arrive on stdin, the JSON object goes to stdout. A segment belongs to the day it started; segments finished after the digest time are added once the next day.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      draft = lifelog.settings
      rootDraft = lifelog.settings.rootPath
      loaded = true
    }
    .onChange(of: draft) {
      guard loaded else { return }
      var updated = draft
      updated.enabled = lifelog.settings.enabled
      Task { await lifelog.updateSettings(updated) }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    let stats = lifelog.todayStats
    VStack(alignment: .leading, spacing: 4) {
      Text(lifelog.statusText)
      if lifelog.phase == .recording, let started = lifelog.segmentStartedAt {
        Text("Current segment since \(started.formatted(date: .omitted, time: .standard))")
          .foregroundStyle(.secondary)
      }
      Text(
        "Today: \(stats.completeSegments) transcribed · \(stats.failedSegments) failed · \(stats.pendingSegments) waiting · \(stats.emptySegments) without speech · \(stats.silentSegmentsDiscarded) silent · \(stats.characters) characters"
      )
      .foregroundStyle(.secondary)
      Button("Retry failed transcripts (all days)") { lifelog.retryFailedSegments() }
      if let error = lifelog.lastError {
        Text(error)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
    .font(.caption)
  }

  private var digestTime: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: draft.digestMinuteOfDay / 60, minute: draft.digestMinuteOfDay % 60,
          second: 0, of: Date()) ?? Date()
      },
      set: {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
        draft.digestMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
      })
  }

  private func minutes(_ seconds: TimeInterval) -> String {
    seconds.truncatingRemainder(dividingBy: 60) == 0
      ? "\(Int(seconds / 60))" : String(format: "%.1f", seconds / 60)
  }
}
