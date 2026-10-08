// Standalone fixture dependencies for the actual FinalTranscriptionEngine source.
// No app, model, audio content, keychain, or network is loaded.
import Foundation
import Darwin

struct TranscriptTurn: Sendable {
  enum Source: Sendable { case microphone, system }
  let start: TimeInterval
  let end: TimeInterval
  let speaker: String
  let text: String
  let source: Source
}

enum Fixture {
  static func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
  }

  static func transcribe(_ url: URL) async throws -> NemotronTranscriber.Result {
    let marker = url.deletingLastPathComponent().appendingPathComponent("critical")
    let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { throw POSIXError(.EEXIST) }
    defer { close(fd); unlink(marker.path) }
    emit("entered")
    if ProcessInfo.processInfo.environment["FIXTURE_ERROR"] == "1" {
      throw CocoaError(.fileReadCorruptFile)
    }
    try await Task.sleep(for: .milliseconds(300))
    return NemotronTranscriber.Result(text: "synthetic", duration: 1, segments: [])
  }
}

actor NemotronTranscriber {
  struct Segment: Sendable { let start: TimeInterval; let end: TimeInterval; let text: String }
  struct Result: Sendable { let text: String; let duration: TimeInterval; let segments: [Segment] }
  func transcribe(_ url: URL) async throws -> Result { try await Fixture.transcribe(url) }
}

actor SenseVoiceTranscriber {
  func transcribe(_ url: URL) async throws -> NemotronTranscriber.Result {
    if ProcessInfo.processInfo.environment["FIXTURE_SENSEVOICE_FAIL"] == "1" {
      Fixture.emit("sensevoice-failed")
      throw CocoaError(.fileReadCorruptFile)
    }
    Fixture.emit("sensevoice")
    return try await Fixture.transcribe(url)
  }
}

enum TranscriptionEngineSettingsStore {
  enum Engine { case onDevice, senseVoice, openAI }
  static func load() -> Engine {
    let environment = ProcessInfo.processInfo.environment
    if environment["FIXTURE_SENSEVOICE"] == "1" { return .senseVoice }
    return environment["FIXTURE_OPENAI"] == "1" ? .openAI : .onDevice
  }
}
enum OpenAITranscribeKeychainStore { static func load() -> String? { "fixture-key" } }
enum OpenAITranscriber {
  static func transcribe(url: URL, apiKey: String) async throws -> [NemotronTranscriber.Segment] {
    if ProcessInfo.processInfo.environment["FIXTURE_OPENAI_FAIL"] == "1" {
      Fixture.emit("cloud-failed")
      throw CocoaError(.fileReadCorruptFile)
    }
    _ = try await Fixture.transcribe(url)
    return [.init(start: 0, end: 1, text: "synthetic")]
  }
}
enum VocabularyTextCorrector { static func apply(to text: String) -> String { text } }
enum FillerWordSettingsStore { static func load() -> Bool { false } }
enum FillerWordFilter { static func apply(to turns: [TranscriptTurn]) -> [TranscriptTurn] { turns } }
enum WavFile {
  static func checkedMeaningfulSignal(at url: URL) throws -> Bool {
    if url.lastPathComponent == "system.wav", ProcessInfo.processInfo.environment["FIXTURE_SYSTEM_READ_ERROR"] == "1" {
      throw CocoaError(.fileReadNoPermission)
    }
    if ProcessInfo.processInfo.environment["FIXTURE_STRICT_READ_ONCE"] == "1" {
      let marker = url.deletingLastPathComponent().appending(path: "read-failed-once")
      if !FileManager.default.fileExists(atPath: marker.path) {
        try Data().write(to: marker)
        throw CocoaError(.fileReadNoPermission)
      }
    }
    if ProcessInfo.processInfo.environment["FIXTURE_STRICT_READ_ERROR"] == "1" {
      throw CocoaError(.fileReadNoPermission)
    }
    return hasMeaningfulSignal(at: url)
  }
  static func hasMeaningfulSignal(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }
}

@main struct TranscriptionLockProbe {
  static func main() async {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let engine = FinalTranscriptionEngine(transcriber: NemotronTranscriber())
    let task = Task {
      try await engine.process(
        microphone: folder.appendingPathComponent("microphone.wav"),
        system: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_SYSTEM_FOLDER"] ?? folder.path)
          .appendingPathComponent("system.wav"),
        onDeviceOnly: ProcessInfo.processInfo.environment["FIXTURE_LOCAL_ONLY"] == "1")
    }
    if ProcessInfo.processInfo.environment["FIXTURE_CANCEL"] == "1" {
      try? await Task.sleep(for: .milliseconds(100))
      task.cancel()
    }
    do {
      let turns = try await task.value
      Fixture.emit("done:\(turns.count)")
    } catch is CancellationError {
      Fixture.emit("cancelled")
    } catch {
      Fixture.emit("error:\(error)")
      exit(1)
    }
  }
}
