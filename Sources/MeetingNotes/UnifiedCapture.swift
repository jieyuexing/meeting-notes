@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// User-facing display policy.  `.allDisplays` keeps a video stream per
/// active display; only the first stream enables system audio, preventing the
/// same system mix being stored once per monitor.
enum UnifiedCaptureDisplayPolicy: Equatable, Sendable {
  case mainDisplay
  case allDisplays
}

struct UnifiedCaptureSegment: Equatable, Sendable {
  let root: URL
  let startedAt: Date
  let systemAudioURL: URL
  let displayPolicy: UnifiedCaptureDisplayPolicy

  init(root: URL, startedAt: Date = Date(), displayPolicy: UnifiedCaptureDisplayPolicy = .allDisplays, systemAudioURL: URL? = nil) {
    self.root = root
    self.systemAudioURL = systemAudioURL ?? root.appending(path: "system.wav")
    self.startedAt = startedAt
    self.displayPolicy = displayPolicy
  }
}

struct UnifiedCaptureDisplayArtifact: Codable, Equatable, Sendable {
  var displayID: UInt32
  var videoFile: String
  var actualFirstFrameAt: Date?
  var endedAt: Date?
  var droppedFrames: Int
  var failure: String?
}

struct UnifiedCaptureMetadata: Codable, Equatable, Sendable {
  var startedAt: Date
  var endedAt: Date?
  var systemAudioFile: String
  var displays: [UnifiedCaptureDisplayArtifact]
  var gaps: [String]
  var failure: String?
}

enum UnifiedCaptureEvent: Equatable, Sendable {
  case started(UInt)
  case completed(UnifiedCaptureMetadata)
  case failed(UInt, String)
}

protocol UnifiedCaptureEventSink: Sendable {
  func receive(_ event: UnifiedCaptureEvent)
}

/// The public lifecycle seam. Caller owns the segment folder and shared
/// `CaptureClock`: this component never chooses a persistent data root and
/// never opens a microphone. A new segment must be supplied on rotation so
/// its system WAV and screen videos share the caller's logical segment.
protocol UnifiedSegmentCapturing: AnyObject, Sendable {
  var onFailure: (@Sendable (URL, String) -> Void)? { get set }
  var onSamples: (@Sendable ([Int16]) -> Void)? { get set }
  func start(segment: UnifiedCaptureSegment, clock: CaptureClock) async throws
  func rotate(to segment: UnifiedCaptureSegment, clock: CaptureClock) async throws
  func suspendImmediately()
  func stop() async throws -> UnifiedCaptureMetadata?
}

/// One ScreenCaptureKit stream per display. The first selected display is the
/// sole system-audio stream. AVAssetWriter queues are serial and callback
/// admission is bounded: a frame is dropped and counted whenever the writer
/// is not ready instead of accumulating unbounded buffers.
final class UnifiedSegmentCapture: NSObject, UnifiedSegmentCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  var onFailure: (@Sendable (URL, String) -> Void)?
  var onSamples: (@Sendable ([Int16]) -> Void)?
  private var segmentRoot: URL?
  private let lock = NSLock()
  private let audioQueue = DispatchQueue(label: "MeetingNotes.unified-capture.audio")
  private let videoQueue = DispatchQueue(label: "MeetingNotes.unified-capture.video")
  private let sink: (any UnifiedCaptureEventSink)?
  private var generation: UInt = 0
  private var streams: [SCStream] = []
  private var active = false
  private var clock: CaptureClock?
  private var audioHandle: FileHandle?
  private var audioBytes = 0
  private var writeFailure: Error?
  private var metadata: UnifiedCaptureMetadata?
  private var writers: [UInt32: UnifiedVideoWriter] = [:]
  private var streamWriters: [ObjectIdentifier: UnifiedVideoWriter] = [:]
  private var streamGenerations: [ObjectIdentifier: UInt] = [:]
  private var needsClockAlignment = true
  private var failureReported = false

  init(sink: (any UnifiedCaptureEventSink)? = nil) { self.sink = sink }

  func start(segment: UnifiedCaptureSegment, clock: CaptureClock) async throws {
    let token = lock.withLock { () -> UInt in generation += 1; active = false; failureReported = false; return generation }
    _ = try await closeCurrent(finalize: true, preserving: token)
    guard isCurrent(token) else { throw CancellationError() }
    try FileManager.default.createDirectory(at: segment.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let audioURL = segment.systemAudioURL
    let handle = try WavFile.create(at: audioURL)
    let content: SCShareableContent
    do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
    catch { try? handle.close(); throw error }
    guard isCurrent(token) else { try? WavFile.finalize(handle, bytes: 0); throw CancellationError() }
    let displays = Self.selectedDisplays(content.displays, policy: segment.displayPolicy)
    guard !displays.isEmpty else { try? handle.close(); throw UnifiedCaptureError.noDisplay }
    let excluded = SystemAudioExclusionStore.excludedBundleIdentifiers()
    let apps = content.applications.filter { excluded.contains($0.bundleIdentifier) }
    var started: [SCStream] = []
    var writerMap: [UInt32: UnifiedVideoWriter] = [:]
    var streamWriterMap: [ObjectIdentifier: UnifiedVideoWriter] = [:]
    do {
      for (index, display) in displays.enumerated() {
        guard isCurrent(token) else { throw CancellationError() }
        let hasAudio = index == 0
        let stream = try makeStream(display: display, excludedApps: apps, includesAudio: hasAudio, root: segment.root, startedAt: segment.startedAt, clock: clock, writerMap: &writerMap)
        lock.withLock {
          if generation == token {
            segmentRoot = segment.root
            streamGenerations[ObjectIdentifier(stream)] = token
          }
        }
        guard isCurrent(token) else { throw CancellationError() }
        try await stream.startCapture()
        guard isCurrent(token) else { try? await stream.stopCapture(); throw CancellationError() }
        started.append(stream)
        if let writer = writerMap[display.displayID] { streamWriterMap[ObjectIdentifier(stream)] = writer }
      }
    } catch {
      for stream in started { try? await stream.stopCapture() }
      try? WavFile.finalize(handle, bytes: 0)
      for writer in writerMap.values { _ = try? await writer.finish() }
      throw error
    }
    let initialDisplays = displays.map { UnifiedCaptureDisplayArtifact(displayID: $0.displayID, videoFile: "screen-\($0.displayID).mp4", actualFirstFrameAt: nil, endedAt: nil, droppedFrames: 0, failure: nil) }
    let admitted = lock.withLock { () -> Bool in
      guard generation == token, !failureReported else { return false }
      self.segmentRoot = segment.root
      self.clock = clock
      self.audioHandle = handle
      self.audioBytes = 0
      self.writeFailure = nil
      self.metadata = UnifiedCaptureMetadata(startedAt: segment.startedAt, endedAt: nil, systemAudioFile: "system.wav", displays: initialDisplays, gaps: [], failure: nil)
      self.writers = writerMap
      self.streamWriters = streamWriterMap
      self.streamGenerations = Dictionary(uniqueKeysWithValues: streamWriterMap.keys.map { ($0, token) })
      self.needsClockAlignment = true
      self.streams = started
      self.active = true
      return true
    }
    guard admitted else {
      for stream in started { try? await stream.stopCapture() }
      try? WavFile.finalize(handle, bytes: 0)
      for writer in writerMap.values { _ = try? await writer.finish() }
      throw CancellationError()
    }
    sink?.receive(.started(token))
  }

  func rotate(to segment: UnifiedCaptureSegment, clock: CaptureClock) async throws {
    _ = try await stop()
    try await start(segment: segment, clock: clock)
  }

  /// Called synchronously from display/system sleep handling. Output callbacks
  /// see `active == false` before asynchronous stream/writer teardown starts.
  func suspendImmediately() { lock.withLock { active = false; generation += 1 } }

  func stop() async throws -> UnifiedCaptureMetadata? { try await closeCurrent(finalize: true) }

  private func closeCurrent(finalize: Bool, preserving token: UInt? = nil) async throws -> UnifiedCaptureMetadata? {
    let snapshot = lock.withLock { () -> (UInt, [SCStream], FileHandle?, Int, Error?, UnifiedCaptureMetadata?, [UnifiedVideoWriter]) in
      if token == nil { generation += 1 }
      active = false
      let value = (generation, streams, audioHandle, audioBytes, writeFailure, metadata, Array(writers.values))
      streams = []; audioHandle = nil; audioBytes = 0; writeFailure = nil; metadata = nil; writers = [:]; streamWriters = [:]; streamGenerations = [:]; clock = nil
      return value
    }
    guard var result = snapshot.5 else { return nil }
    var errors: [String] = []
    for stream in snapshot.1 { do { try await stream.stopCapture() } catch { errors.append(error.localizedDescription) } }
    if let handle = snapshot.2 { do { try WavFile.finalize(handle, bytes: snapshot.3) } catch { errors.append(error.localizedDescription) } }
    for writer in snapshot.6 {
      do { let artifact = try await writer.finish(); result.displays.removeAll { $0.displayID == artifact.displayID }; result.displays.append(artifact) }
      catch { errors.append(error.localizedDescription) }
    }
    result.endedAt = Date()
    if let error = snapshot.4 { errors.append(error.localizedDescription) }
    if !errors.isEmpty { result.failure = errors.joined(separator: "; "); emitFirstFailure(snapshot.0, result.failure!) }
    // `result` is emitted only after WAV and every asset writer has finished.
    sink?.receive(.completed(result))
    return result
  }

  private func makeStream(display: SCDisplay, excludedApps: [SCRunningApplication], includesAudio: Bool, root: URL, startedAt: Date, clock: CaptureClock, writerMap: inout [UInt32: UnifiedVideoWriter]) throws -> SCStream {
    let config = SCStreamConfiguration()
    let width = max(2, Int(display.width)); let height = max(2, Int(display.height))
    let scale = min(1, 1920 / Double(max(width, height)))
    config.width = max(2, Int((Double(width) * scale).rounded()) / 2 * 2)
    config.height = max(2, Int((Double(height) * scale).rounded()) / 2 * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
    config.showsCursor = true
    config.capturesAudio = includesAudio
    config.sampleRate = 16_000
    config.channelCount = 1
    config.excludesCurrentProcessAudio = true
    let writer = try UnifiedVideoWriter(displayID: display.displayID, url: root.appending(path: "screen-\(display.displayID).mp4"), width: config.width, height: config.height, startedAt: startedAt, clock: clock)
    writerMap[display.displayID] = writer
    let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []), configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
    if includesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
    return stream
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    let token = lock.withLock { streamGenerations[ObjectIdentifier(stream)] }
    guard let token, lock.withLock({ active && generation == token }) else { return }
    switch type {
    case .screen:
      // ScreenCaptureKit identifies the originating stream in the callback;
      // never guess by writer readiness, otherwise a second monitor could be
      // appended to the first monitor's file.
      let failure = lock.withLock { () -> String? in
        guard active, generation == token else { return nil }
        return streamWriters[ObjectIdentifier(stream)]?.append(sampleBuffer)
      }
      if let failure { emitFirstFailure(token, failure) }
    case .audio: appendAudio(sampleBuffer, stream: stream, token: token)
    default: break
    }
  }

  private func appendAudio(_ sampleBuffer: CMSampleBuffer, stream: SCStream, token: UInt) {
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer), let description = CMSampleBufferGetFormatDescription(sampleBuffer), let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
    let length = CMBlockBufferGetDataLength(dataBuffer); guard length > 0 else { return }
    var pointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
    guard abs(format.mSampleRate - Double(WavFile.sampleRate)) < 0.01, format.mChannelsPerFrame > 0 else { emitFirstFailure(token, UnifiedCaptureError.unsupportedAudioFormat.localizedDescription); return }
    let channels = max(1, Int(format.mChannelsPerFrame)); let samples: [Int16]
    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
      let count = length / MemoryLayout<Float>.size; let values = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
      guard (0..<count).allSatisfy({ values[$0].isFinite }) else { emitFirstFailure(token, UnifiedCaptureError.unsupportedAudioFormat.localizedDescription); return }
      samples = (0..<(count / channels)).map { frame in Int16(max(-1, min(1, (0..<channels).reduce(Float.zero) { $0 + values[frame * channels + $1] } / Float(channels))) * 32767) }
    } else if format.mBitsPerChannel == 16 {
      let count = length / MemoryLayout<Int16>.size; let values = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: count)
      samples = (0..<(count / channels)).map { frame in Int16(clamping: (0..<channels).reduce(0) { $0 + Int(values[frame * channels + $1]) } / channels) }
    } else { emitFirstFailure(token, UnifiedCaptureError.unsupportedAudioFormat.localizedDescription); return }
    let data = samples.withUnsafeBufferPointer(Data.init)
    var failure: String?; lock.lock()
    guard active, generation == token, streamGenerations[ObjectIdentifier(stream)] == token, let handle = audioHandle, writeFailure == nil else { lock.unlock(); return }
    do {
      if needsClockAlignment, let clock {
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let position = stamp.isValid && stamp.seconds.isFinite
          ? clock.samplePosition(atHostSeconds: stamp.seconds) : max(0, clock.samplePosition - samples.count)
        let missing = max(0, position - audioBytes / MemoryLayout<Int16>.size)
        if missing > 0 { let pad = WavFile.silence(samples: missing); try handle.write(contentsOf: pad); audioBytes += pad.count; metadata?.gaps.append("system-audio delayed by \(missing) samples") }
        needsClockAlignment = false
      }
      try handle.write(contentsOf: data); audioBytes += data.count
      if audioBytes % (Int(WavFile.sampleRate) * MemoryLayout<Int16>.size) < data.count { try WavFile.checkpoint(handle, bytes: audioBytes) }
    } catch { writeFailure = error; failure = error.localizedDescription }
    lock.unlock()
    if let failure { emitFirstFailure(token, failure) }
    else { onSamples?(samples) }
  }

  private func emitFirstFailure(_ token: UInt, _ message: String) {
    let notification = lock.withLock { () -> (UnifiedCaptureEvent, URL?)? in
      guard generation == token, !failureReported else { return nil }
      failureReported = true
      metadata?.failure = message
      writeFailure = NSError(domain: "UnifiedCapture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
      active = false
      return (.failed(token, message), segmentRoot)
    }
    if let notification {
      sink?.receive(notification.0)
      if let root = notification.1 { onFailure?(root, message) }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    if let token = lock.withLock({ streamGenerations[ObjectIdentifier(stream)] }) {
      emitFirstFailure(token, error.localizedDescription)
    }
  }

  private func isCurrent(_ token: UInt) -> Bool { lock.withLock { generation == token } }

  static func selectedDisplays(_ displays: [SCDisplay], policy: UnifiedCaptureDisplayPolicy) -> [SCDisplay] {
    let awake = displays.filter { CGDisplayIsAsleep($0.displayID) == 0 }
    switch policy { case .allDisplays: return awake; case .mainDisplay: return awake.first(where: { $0.displayID == CGMainDisplayID() }).map { [$0] } ?? [] }
  }

  /// Kept separate for deterministic fixtures: exactly one selected display
  /// owns the single system mix, including in a multi-display segment.
  static func systemAudioDisplayIDs(_ displayIDs: [UInt32]) -> Set<UInt32> {
    displayIDs.first.map { [$0] } ?? []
  }
}

enum UnifiedCaptureError: LocalizedError { case noDisplay, unsupportedAudioFormat
  var errorDescription: String? { switch self { case .noDisplay: return "No display is available for unified capture"; case .unsupportedAudioFormat: return "Unsupported system-audio PCM format" } }
}

private final class UnifiedVideoWriter: @unchecked Sendable {
  private let lock = NSLock(); let displayID: UInt32; let url: URL; let writer: AVAssetWriter; let input: AVAssetWriterInput
  private let clock: CaptureClock; private let startedAt: Date
  private var firstFrame: Date?; private var drops = 0; private var started = false; private var finishing = false
  init(displayID: UInt32, url: URL, width: Int, height: Int, startedAt: Date, clock: CaptureClock) throws {
    self.displayID = displayID; self.url = url; self.startedAt = startedAt; self.clock = clock
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = true; guard writer.canAdd(input) else { throw UnifiedCaptureError.noDisplay }; writer.add(input)
  }
  /// nil means accepted or deliberately dropped by backpressure. Writer
  /// failures are distinct and immediately close admission in the owner.
  func append(_ sample: CMSampleBuffer) -> String? { lock.withLock {
    guard !finishing, CMSampleBufferIsValid(sample) else { return nil }
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: raw) == .complete else { return nil }
    if !started {
      guard writer.startWriting() else { return writer.error?.localizedDescription ?? "Video writer could not start." }
      writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
      started = true; firstFrame = startedAt.addingTimeInterval(clock.elapsed(atHostSeconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
    }
    guard writer.status == .writing else { return writer.error?.localizedDescription ?? "Video writer stopped." }
    guard input.isReadyForMoreMediaData else { drops += 1; return nil }
    guard input.append(sample) else { return writer.error?.localizedDescription ?? "Video frame write failed." }
    return nil
  } }
  func finish() async throws -> UnifiedCaptureDisplayArtifact {
    let snapshot = lock.withLock { () -> (Bool, Date?, Int) in
      finishing = true
      if started { input.markAsFinished() }
      return (started, firstFrame, drops)
    }
    if snapshot.0 { await writer.finishWriting() } else { writer.cancelWriting() }
    if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return UnifiedCaptureDisplayArtifact(displayID: displayID, videoFile: url.lastPathComponent, actualFirstFrameAt: snapshot.1, endedAt: Date(), droppedFrames: snapshot.2, failure: nil)
  }
}
