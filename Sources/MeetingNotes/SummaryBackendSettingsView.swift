import SwiftUI

struct SummaryBackendSettingsView: View {
  @State private var settings = SummaryBackendSettingsStore.load()
  @State private var testing = false
  @State private var result = ""
  @State private var failed = false
  @State private var translateTranscripts = TranscriptTranslationSettingsStore.load()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Summary backend", selection: $settings.backend) {
        ForEach(SummaryBackend.allCases) { backend in
          Text(backend.label).tag(backend)
        }
      }
      if settings.backend == .command {
        TextField("Shell command (for example: claude -p)", text: $settings.command, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
        Text("Runs in your login shell. Receives the transcript and JSON schema on stdin; return the summary JSON on stdout. Model selection belongs in the command.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if settings.backend == .off {
        Text("Recordings are finalized with their transcript. Automatic summaries and summary retries are paused.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Uses the app's ChatGPT sign-in and the Codex model settings below.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button(testing ? "Testing…" : "Test") {
          let selected = settings
          testing = true
          result = ""
          Task {
            defer { testing = false }
            do {
              let summary = try await OpenAIEnricher().testBackend(selected)
              failed = false
              result = "Success: \(summary)"
            } catch {
              failed = true
              result = error.localizedDescription
            }
          }
        }
        .disabled(testing || settings.backend == .off)
        if testing { ProgressView().controlSize(.small) }
      }
      if !result.isEmpty {
        Text(result)
          .font(.caption)
          .foregroundStyle(failed ? Color.red : Color.secondary)
          .textSelection(.enabled)
      }
      Toggle("Translate foreign-language transcripts", isOn: $translateTranscripts)
        .disabled(settings.backend == .off)
      Text("When the detected transcript language differs from the meeting notes language, the finished transcript is sent to the summary backend above and a timestamped original-plus-translation copy is saved as transcript.<language>.md. Nothing is sent while the backend is Off.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .disabled(testing)
    .onChange(of: settings) {
      SummaryBackendSettingsStore.save(settings)
      result = ""
    }
    .onChange(of: translateTranscripts) {
      TranscriptTranslationSettingsStore.save(translateTranscripts)
    }
  }
}
