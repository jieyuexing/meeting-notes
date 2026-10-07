import Foundation
import Darwin

/// The shell command is explicitly chosen by the user. Transcript contents are
/// stdin data, never interpolated into shell syntax. No CLI configuration is changed.
enum CommandSummaryBackend {
  enum CommandError: LocalizedError {
    case emptyCommand
    case noJSONObject
    case invalidJSON(String)
    case failed(Int32, String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
      switch self {
      case .emptyCommand: "Enter a summary command in Settings."
      case .noJSONObject: "The summary command did not return a complete JSON object."
      case .invalidJSON(let detail): "The summary command returned invalid JSON: \(detail)"
      case .failed(let code, let detail): "The summary command exited with status \(code): \(detail)"
      case .timedOut(let seconds): "The summary command exceeded its \(Int(seconds))-second timeout."
      }
    }
  }

  static func instruction(prompt: String, schemaData: Data) -> String {
    """
    \(ChatGPTAuthService.instruction(prompt: prompt))

    Return only one JSON object conforming to the following JSON schema.
    Include every required field. Do not wrap it in an event envelope or explanatory prose.
    JSON SCHEMA
    \(String(decoding: schemaData, as: UTF8.self))
    """
  }

  /// Finds the first balanced object, honoring strings and escaped quotes.
  /// JSON syntax is validated before the existing GeneratedInsights decoder
  /// validates the required fields. Do not silently skip a malformed object.
  static func extractJSONObject(from output: String) throws -> Data {
    var start: String.Index?
    var depth = 0
    var inString = false
    var escaped = false
    var previousToken: Character?
    for index in output.indices {
      let character = output[index]
      if start == nil {
        guard character == "{" else { continue }
        start = index
        depth = 1
        continue
      }
      if inString {
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else {
        if (character == "}" || character == "]"), previousToken == "," {
          throw CommandError.invalidJSON("Trailing commas are not valid JSON.")
        }
        if character == "\"" { inString = true }
        else if character == "{" { depth += 1 }
        else if character == "}" {
          depth -= 1
          if depth == 0, let start {
            let data = Data(output[start...index].utf8)
            do { _ = try JSONSerialization.jsonObject(with: data) }
            catch { throw CommandError.invalidJSON(error.localizedDescription) }
            return data
          }
        }
        if !character.isWhitespace { previousToken = character }
      }
    }
    throw CommandError.noJSONObject
  }

  static func generate(
    command: String, prompt: String, schemaData: Data, timeout: TimeInterval? = nil
  ) async throws -> Data {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommandError.emptyCommand
    }
    let input = instruction(prompt: prompt, schemaData: schemaData)
    let deadline = timeout ?? ChatGPTAuthService.generationTimeout(promptCharacterCount: input.count)
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appending(path: "meeting-summary-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: temporary) }
    let inputURL = temporary.appending(path: "stdin")
    let outputURL = temporary.appending(path: "stdout")
    let errorURL = temporary.appending(path: "stderr")
    try Data(input.utf8).write(to: inputURL)
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let stdin = try FileHandle(forReadingFrom: inputURL)
    let stdout = try FileHandle(forWritingTo: outputURL)
    let stderr = try FileHandle(forWritingTo: errorURL)
    defer {
      try? stdin.close()
      try? stdout.close()
      try? stderr.close()
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = temporary
    // Inherit the user's environment; in particular, do not assign CODEX_HOME.
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try Task.checkCancellation()
    try process.run()
    let clock = ContinuousClock()
    let started = clock.now
    do {
      while process.isRunning {
        try Task.checkCancellation()
        if started.duration(to: clock.now) >= .seconds(deadline) {
          throw CommandError.timedOut(deadline)
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    } catch {
      if process.isRunning { process.terminate() }
      // A command that ignores SIGTERM must not hold the summary task open.
      let stopped = clock.now
      while process.isRunning && stopped.duration(to: clock.now) < .seconds(1) {
        // Detached sleep does not inherit cancellation from the caller.
        await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      throw error
    }
    guard process.terminationStatus == 0 else {
      let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
      throw CommandError.failed(process.terminationStatus, String(detail.suffix(2_000)))
    }
    return try extractJSONObject(from: String(contentsOf: outputURL, encoding: .utf8))
  }
}
