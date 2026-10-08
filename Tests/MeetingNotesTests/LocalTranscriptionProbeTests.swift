import Foundation
import FluidAudio
import Testing

@testable import MeetingNotes

/// An opt-in, local-only retained-audio probe.  It is intentionally inert in
/// normal tests: it neither looks up a model cache nor reads audio unless the
/// caller supplies both absolute paths.  `preloadShared(from:)` only loads the
/// explicit compiled-model directory; this test never calls FluidAudio's
/// downloading API.
@Test func localRetainedNemotronProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let wavPath = environment["MEETING_NOTES_RETAINED_WAV"],
    let modelPath = environment["MEETING_NOTES_RETAINED_MODEL_DIR"],
    let outputPath = environment["MEETING_NOTES_RETAINED_OUT"]
  else { return }

  let wavURL = URL(fileURLWithPath: wavPath)
  let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
  let outputURL = URL(fileURLWithPath: outputPath)
  let requiredModelFiles = ["metadata.json", "tokenizer.json", "encoder.mlmodelc/model.mil",
                            "decoder.mlmodelc/model.mil", "joint.mlmodelc/model.mil"]
  guard FileManager.default.fileExists(atPath: wavURL.path),
    requiredModelFiles.allSatisfy({ FileManager.default.fileExists(atPath: modelURL.appendingPathComponent($0).path) })
  else {
    throw ProbeError.cachePreflightFailed
  }

  let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: modelURL)
  let original = try await runProbe(wavURL: wavURL, shared: shared)
  var report = reportForProbe(label: "original", result: original)

  if environment["MEETING_NOTES_RETAINED_GAIN18"] == "1" {
    let gainURL = outputURL.deletingLastPathComponent().appendingPathComponent("microphone-plus18dB.wav")
    try makeGain18Copy(from: wavURL, to: gainURL)
    let gained = try await runProbe(wavURL: gainURL, shared: shared)
    report += "\n\n" + reportForProbe(label: "plus18dB", result: gained)
  }
  try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try report.write(to: outputURL, atomically: true, encoding: .utf8)
}

private enum ProbeError: Error { case cachePreflightFailed, malformedWav, wouldClipGain }

private struct ProbeResult {
  let duration: TimeInterval
  let partials: [String]
  let oldAssembly: [String]
  let finalText: String
  let timings: [TokenTiming]
  let uncorrectedSegments: [FinalTranscriptSegments.Segment]
  let archive: NemotronTranscriber.Result
}

private func runProbe(
  wavURL: URL, shared: SharedNemotronMultilingualModels
) async throws -> ProbeResult {
  let audio = try pcm16Payload(from: wavURL)
  let manager = StreamingNemotronMultilingualAsrManager()
  try await manager.loadFromShared(shared)
  await manager.setLanguage("auto")
  await manager.setForcedPrefix(false)

  let samplesPerChunk = 17_920
  var partials: [String] = []
  var oldAssembly: [String] = []
  var previous = ""
  var emittedThrough: TimeInterval = 0
  var offset = 0
  while offset < audio.count {
    let end = min(offset + samplesPerChunk, audio.count)
    _ = try await manager.process(samples: Array(audio[offset..<end]))
    let current = await manager.getPartialTranscript()
    partials.append(current)
    // This is the exact former `appendDelta` state transition, with the
    // production `appendedTextDiagnosing` function used for every diff.
    let delta = NemotronTranscriber.appendedTextDiagnosing(previous: previous, current: current)
    previous = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !delta.text.isEmpty {
      let currentTime = Double(end) / 16_000
      let start = max(emittedThrough, currentTime - 1.120)
      oldAssembly.append(String(format: "%.3f...%.3f %@ [%@]", start, currentTime, delta.text,
                                delta.isContinuation ? "continuation" : "revision"))
      emittedThrough = currentTime
    }
    offset = end
  }
  let finalized = try await manager.finishWithTokenTimings()
  let duration = Double(audio.count) / 16_000
  let uncorrectedSegments = FinalTranscriptSegments.authoritative(
    text: finalized.text, tokenTimings: finalized.timings, duration: duration)
  return ProbeResult(duration: duration, partials: partials, oldAssembly: oldAssembly,
                     finalText: finalized.text, timings: finalized.timings,
                     uncorrectedSegments: uncorrectedSegments,
                     archive: NemotronTranscriber.archiveResult(
                       text: finalized.text, tokenTimings: finalized.timings, duration: duration))
}

private func pcm16Payload(from url: URL) throws -> [Float] {
  let data = try Data(contentsOf: url)
  guard data.count >= 44 else { throw ProbeError.malformedWav }
  return data.dropFirst(44).withUnsafeBytes { bytes in
    let input = bytes.bindMemory(to: Int16.self)
    return (0..<input.count).map { Float(Int16(littleEndian: input[$0])) / 32_768 }
  }
}

private func makeGain18Copy(from source: URL, to destination: URL) throws {
  let data = try Data(contentsOf: source)
  guard data.count >= 44 else { throw ProbeError.malformedWav }
  let gain = pow(10.0, 18.0 / 20.0)
  var output = Data(data.prefix(44))
  let samples: [Int16] = data.dropFirst(44).withUnsafeBytes { bytes in
    let input = bytes.bindMemory(to: Int16.self)
    return input.map { Int16(littleEndian: $0) }
  }
  for sample in samples {
    let scaled = Double(sample) * gain
    guard scaled >= Double(Int16.min), scaled <= Double(Int16.max) else { throw ProbeError.wouldClipGain }
    var little = Int16(scaled.rounded()).littleEndian
    withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
  }
  try output.write(to: destination, options: .atomic)
}

private func reportForProbe(label: String, result: ProbeResult) -> String {
  let rawRendered = result.timings.map { renderToken($0.token) }.joined()
  let detokenized = collapseSpaces(rawRendered).trimmingCharacters(in: .whitespacesAndNewlines)
  let final = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
  let timingIssue = timingValidationIssue(result.timings, duration: result.duration)
  let cause: String
  if let timingIssue { cause = "timing-invalid: \(timingIssue)" }
  else if detokenized != final { cause = "text-parity-mismatch" }
  else { cause = "timings-accepted" }
  let archived = result.archive.segments.map { String(format: "%.3f...%.3f %@", $0.start, $0.end, $0.text) }
  let uncorrected = result.uncorrectedSegments.map { String(format: "%.3f...%.3f %@", $0.start, $0.end, $0.text) }
  let timingLines = result.timings.enumerated().map { index, item in
    String(format: "%03d %.3f...%.3f %@ id=%d confidence=%.5f", index, item.startTime,
                  item.endTime, item.token, item.tokenId, item.confidence)
  }
  return """
  # \(label)
  duration: \(result.duration)
  finalText: \(result.finalText)
  rawTokenRender: \(rawRendered)
  tokenizerEquivalentRender: \(detokenized)
  fallbackCauseBeforeTokenizerParityFix: \(rawRendered.trimmingCharacters(in: .whitespacesAndNewlines) == final ? "none" : "text-parity-mismatch")
  authoritativeCauseUsingTokenizerRules: \(cause)
  uncorrectedAuthoritativeSegments:\n\(uncorrected.joined(separator: "\n"))
  finalArchiveText: \(result.archive.text)
  finalArchiveSegments:\n\(archived.joined(separator: "\n"))
  partials:\n\(result.partials.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n"))
  simulatedOldAppendDelta:\n\(result.oldAssembly.joined(separator: "\n"))
  timings:\n\(timingLines.joined(separator: "\n"))
  """
}

private func renderToken(_ token: String) -> String {
  token.hasPrefix("▁") ? " " + token.dropFirst() : token
}

private func collapseSpaces(_ text: String) -> String {
  text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
}

private func timingValidationIssue(_ timings: [TokenTiming], duration: TimeInterval) -> String? {
  guard !timings.isEmpty else { return "missing" }
  var previousStart = -Double.infinity
  var previousEnd = -Double.infinity
  for (index, timing) in timings.enumerated() {
    guard timing.startTime.isFinite, timing.endTime.isFinite else { return "nonfinite at \(index)" }
    guard timing.startTime >= 0, timing.endTime >= timing.startTime else { return "range at \(index)" }
    guard timing.startTime >= previousStart, timing.endTime >= previousEnd else { return "nonmonotonic at \(index)" }
    guard timing.startTime <= duration else { return "starts-after-duration at \(index)" }
    previousStart = timing.startTime
    previousEnd = timing.endTime
  }
  return nil
}
