import Foundation
import Testing
@testable import MeetingNotes

@Test func summaryCommandRejectsMissingJSON() {
  #expect(throws: CommandSummaryBackend.CommandError.self) {
    try CommandSummaryBackend.extractJSONObject(from: "Sorry, no structured output.")
  }
}

private let summaryJSON = #"{"summary":"Agreed on Friday.","topics":[],"decisions":[],"action_items":[],"open_questions":[],"key_statements":[]}"#

@Test func summaryCommandExtractsFencedJSON() throws {
  let extracted = try CommandSummaryBackend.extractJSONObject(from: "```json\n\(summaryJSON)\n```")
  #expect(String(decoding: extracted, as: UTF8.self) == summaryJSON)
}

@Test func summaryCommandExtractsFirstObjectAmidNoise() throws {
  let extracted = try CommandSummaryBackend.extractJSONObject(
    from: "Preparing summary…\n\(summaryJSON)\nDone.\n{\"later\":true}")
  #expect(String(decoding: extracted, as: UTF8.self) == summaryJSON)
}

@Test func summaryCommandHandlesEscapesAndNestedObjects() throws {
  let json = #"{"text":"braces { } and \"quoted\" and \\ slash","nested":{"items":[{"ok":true}]}}"#
  #expect(try String(decoding: CommandSummaryBackend.extractJSONObject(from: json), as: UTF8.self) == json)
}

@Test func summaryCommandRejectsInvalidOrTruncatedJSON() {
  for output in ["{invalid}", #"{"a":1,}"#, #"{"a":"unfinished"#, "[]"] {
    #expect(throws: CommandSummaryBackend.CommandError.self) {
      try CommandSummaryBackend.extractJSONObject(from: output)
    }
  }
  #expect(throws: CommandSummaryBackend.CommandError.self) {
    try CommandSummaryBackend.extractJSONObject(from: "{invalid}\n\(summaryJSON)")
  }
}

@Test func summaryBackendDefaultsAndRoundTrip() throws {
  let name = "MeetingNotesTests.SummaryBackend.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  #expect(SummaryBackendSettingsStore.load(from: defaults) == SummaryBackendSettings())
  for backend in SummaryBackend.allCases {
    let settings = SummaryBackendSettings(backend: backend, command: "claude -p\n# preserved verbatim")
    SummaryBackendSettingsStore.save(settings, to: defaults)
    #expect(SummaryBackendSettingsStore.load(from: defaults) == settings)
    #expect(defaults.string(forKey: "summary.backend") == backend.rawValue)
    #expect(defaults.string(forKey: "summary.command") == settings.command)
  }
  defaults.set("unknown-future-backend", forKey: "summary.backend")
  #expect(SummaryBackendSettingsStore.load(from: defaults).backend == .codex)
}

@Test func summaryCommandReceivesInstructionOnStdin() async throws {
  // A large input proves stdin cannot fill a pipe while the child writes stdout.
  let prompt = String(repeating: "Transcript data. ", count: 10_000)
  let schema = Data(#"{"type":"object"}"#.utf8)
  let data = try await CommandSummaryBackend.generate(
    command: "content=$(cat); [[ $content == *'JSON SCHEMA'* && $content == *'Do not use tools'* ]] || exit 9; printf '%s' '\(summaryJSON)'",
    prompt: prompt, schemaData: schema, timeout: 10)
  #expect(String(decoding: data, as: UTF8.self) == summaryJSON)
}

@Test func summaryCommandReportsProcessFailureAndTimeout() async throws {
  do {
    _ = try await CommandSummaryBackend.generate(
      command: "printf 'fixture failure' >&2; exit 7", prompt: "test", schemaData: Data(), timeout: 5)
    Issue.record("Expected nonzero exit to fail")
  } catch CommandSummaryBackend.CommandError.failed(let status, let detail) {
    #expect(status == 7)
    #expect(detail.contains("fixture failure"))
  }
  do {
    _ = try await CommandSummaryBackend.generate(
      command: "exec /bin/sleep 10", prompt: "test", schemaData: Data(), timeout: 0.1)
    Issue.record("Expected timeout")
  } catch CommandSummaryBackend.CommandError.timedOut { }
}

@Test func summaryCommandRejectsEmptyCommand() async {
  await #expect(throws: CommandSummaryBackend.CommandError.self) {
    try await CommandSummaryBackend.generate(command: " \n", prompt: "test", schemaData: Data())
  }
}

@Test func summaryCommandUsesProductionDecoderWithoutChatGPTLogin() async throws {
  let summary = try await OpenAIEnricher().testBackend(
    SummaryBackendSettings(backend: .command, command: "printf '%s' '\(summaryJSON)'"))
  #expect(summary == "Agreed on Friday.")
  do {
    _ = try await OpenAIEnricher().testBackend(
      SummaryBackendSettings(backend: .command, command: "printf '%s' '{\"summary\":123}'"))
    Issue.record("Expected GeneratedInsights decoding to reject wrong fields")
  } catch OpenAIEnricher.EnrichmentError.invalidResponse(let detail) {
    #expect(detail.contains("Custom command"))
  }
}

@Test func summaryOffFailsBeforeAuthenticationOrCommands() async {
  await #expect(throws: OpenAIEnricher.EnrichmentError.self) {
    try await OpenAIEnricher().testBackend(SummaryBackendSettings(backend: .off, command: "exit 99"))
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_NOTES_TEST_COMMAND"] != nil))
func liveSummaryCommandProbe() async throws {
  let command = try #require(ProcessInfo.processInfo.environment["MEETING_NOTES_TEST_COMMAND"])
  let summary = try await OpenAIEnricher().testBackend(
    SummaryBackendSettings(backend: .command, command: command))
  #expect(!summary.isEmpty)
  print("LIVE_SUMMARY_RESULT: \(summary)")
}

@Test func summaryCommandCanBeCancelled() async throws {
  let task = Task {
    try await CommandSummaryBackend.generate(
      command: "exec /bin/sleep 10", prompt: "test", schemaData: Data(), timeout: 5)
  }
  try await Task.sleep(for: .milliseconds(100))
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("Expected cancellation")
  } catch is CancellationError { }
}
