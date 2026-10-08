import SwiftUI

/// Daily recording settings; the menu provides the primary start/stop action.
struct LifelogSettingsPane: View {
  @Bindable var lifelog: LifelogController
  @Environment(\.locale) private var locale
  @State private var draft = LifelogSettings()
  @State private var rootDraft = ""
  @State private var loaded = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text(UIStrings.text("Always-on"))
            .font(.title2.weight(.semibold))
          Text(UIStrings.text("Record screen, microphone and system sound while a display is awake. T3 task evidence continues in the background. Review a time range later without recording it again."))
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Divider()

        Toggle(UIStrings.text("Record continuously"), isOn: Binding(
          get: { lifelog.settings.enabled },
          set: { enabled in Task { await lifelog.setEnabled(enabled) } }))
        Toggle(UIStrings.text("Screen and system audio"), isOn: $draft.unifiedMedia)
        Toggle(UIStrings.text("All awake displays"), isOn: $draft.allDisplays)
          .disabled(!draft.unifiedMedia)
        Stepper(UIStrings.text("Screen limit: \(draft.screenCapacityGB) GB"), value: $draft.screenCapacityGB, in: 1...1000)
        Text(UIStrings.text("Screen files are kept even without speech. At the limit, media recording pauses; nothing is automatically deleted."))
          .font(.caption).foregroundStyle(.secondary)
        Text(UIStrings.text("Screen space used: \(UIStrings.bytes(lifelog.screenBytes))"))
        Toggle(UIStrings.text("Collect T3 task evidence"), isOn: $draft.t3Enabled)
        Toggle(UIStrings.text("Keep T3 requests and final replies"), isOn: $draft.t3IncludeText)
        TextField(UIStrings.text("t3ctl executable"), text: $draft.t3ctlPath)
        Text(UIStrings.text("T3 activity shows time overlap, not human focus. Service failures are independent of media recording."))
          .font(.caption).foregroundStyle(.secondary)
        statusSection

        Divider()

        Text(UIStrings.text("Segments"))
          .font(.headline)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
          GridRow {
            Text(UIStrings.text("Folder"))
              .gridColumnAlignment(.trailing)
            // Commits on Return only; changing roots requires stopped, drained capture.
            TextField(LifelogSettings.defaultRootPath, text: $rootDraft)
              .onSubmit { draft.rootPath = rootDraft }
          }
          GridRow {
            Text(UIStrings.text("End after silence"))
            Stepper(
              UIStrings.text("\(minutes(draft.silenceThreshold)) min"), value: $draft.silenceThreshold,
              in: LifelogSettings.silenceRange, step: 30)
          }
          GridRow {
            Text(UIStrings.text("Longest segment"))
            Stepper(
              UIStrings.text("\(minutes(draft.maximumSegmentDuration)) min"), value: $draft.maximumSegmentDuration,
              in: LifelogSettings.maximumSegmentRange, step: 300)
          }
        }
        Text(UIStrings.text("Audio uses the selected microphone and local final transcription engine. Locks, display sleep and session changes pause media; T3 observation continues. Separate meeting capture temporarily takes over. Audio retention does not delete screen files. Screen capture is a replay reference, not visual recognition."))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        Text(UIStrings.text("Daily digest"))
          .font(.headline)
        Picker(UIStrings.text("Digest backend"), selection: $draft.digestBackend) {
          ForEach(LifelogDigestBackend.allCases) { Text(UIStrings.resolve($0.label)).tag($0) }
        }
        if draft.digestBackend == .command {
          TextField(UIStrings.text("Shell command; leave empty for no digest"), text: $draft.digestCommand, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
        DatePicker(UIStrings.text("Daily at"), selection: digestTime, displayedComponents: .hourAndMinute)
        HStack {
          Button(UIStrings.resolve(lifelog.digestRunning ? "Generating…" : "Generate today's digest now")) {
            Task { await lifelog.generateDigest(day: lifelog.store.dayKey(Date())) }
          }
          .disabled(lifelog.digestRunning || draft.digestBackendSettings == nil)
          if lifelog.digestRunning { ProgressView().controlSize(.small) }
        }
        if !lifelog.digestStatusText.isEmpty {
          Text(UIStrings.resolve(lifelog.digestStatusText))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Text(UIStrings.text("Writes digest/YYYY-MM-DD.md in the folder above. A custom command follows the summary contract: the prompt and JSON schema arrive on stdin, the JSON object goes to stdout. A segment belongs to the day it started; segments finished after the digest time are added once the next day."))
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
      Task {
        await lifelog.updateSettings(updated)
        // A rejected root must not keep looking like the active archive folder.
        if draft.rootPath == updated.rootPath, lifelog.settings.rootPath != updated.rootPath {
          draft.rootPath = lifelog.settings.rootPath
          rootDraft = lifelog.settings.rootPath
        }
      }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    let stats = lifelog.todayStats
    VStack(alignment: .leading, spacing: 4) {
      Text(lifelog.statusText(language: UILanguage.displayed(for: locale)))
      if lifelog.phase == .recording, let started = lifelog.segmentStartedAt {
        Text(UIStrings.text("Current segment since \(started.formatted(.dateTime.hour().minute().second().locale(locale)))"))
          .foregroundStyle(.secondary)
      }
      Text(
        UIStrings.text("Today: \(stats.completeSegments) transcribed · \(stats.failedSegments) failed · \(stats.pendingSegments) waiting · \(stats.emptySegments) without speech · \(stats.silentSegmentsDiscarded) silent · \(stats.characters) characters")
      )
      .foregroundStyle(.secondary)
      Button(UIStrings.text("Retry failed transcripts (all days)")) { lifelog.retryFailedSegments() }
      if let error = lifelog.lastError {
        Text(UIStrings.resolve(error))
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
