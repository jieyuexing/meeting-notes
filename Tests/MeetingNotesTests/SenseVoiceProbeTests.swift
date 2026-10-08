import Foundation
import Testing

@testable import MeetingNotes

/// Opt-in, local-only SenseVoice final-path probe. Inert without both
/// variables. It runs the production `SenseVoiceTranscriber` (local model
/// cache; FluidAudio downloads a missing model on first use, as the app
/// does) and writes a JSON report; it never sends audio anywhere.
@Test func localSenseVoiceFinalProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let wavs = environment["MEETING_NOTES_SENSEVOICE_WAVS"],
    let outputPath = environment["MEETING_NOTES_SENSEVOICE_OUT"]
  else { return }
  let transcriber = SenseVoiceTranscriber()
  let loadStart = ContinuousClock.now
  try await transcriber.prepare()
  let loadDuration = loadStart.duration(to: .now)
  var reports: [[String: Any]] = []
  for path in wavs.split(separator: ":").map(String.init) {
    let url = URL(fileURLWithPath: path)
    let started = ContinuousClock.now
    let result = try await transcriber.transcribe(url)
    let elapsed = started.duration(to: .now)
    let turns = FinalTranscriptionEngine.turns(from: result, source: .microphone)
    reports.append([
      "wav": path,
      "durationSeconds": result.duration,
      "elapsed": "\(elapsed)",
      "text": turns.map(\.text).joined(),
      "turns": turns.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
    ])
  }
  let report: [String: Any] = ["prepare": "\(loadDuration)", "results": reports]
  let data = try JSONSerialization.data(
    withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}
