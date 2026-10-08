@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// Decides, once per tick, whether the current lifelog segment continues.
struct LifelogSegmentPolicy: Sendable {
  enum Decision: Equatable, Sendable {
    case keep
    case cut(LifelogCutReason)
    /// The segment never heard meaningful signal: drop it and start afresh,
    /// so a silent night neither grows one file nor queues transcriptions.
    case discardSilence
  }

  var silenceThreshold: TimeInterval
  var maximumDuration: TimeInterval

  func decide(
    segmentStartedAt: Date, now: Date, hadSound: Bool, quietForThreshold: Bool,
    calendar: Calendar
  ) -> Decision {
    let elapsed = now.timeIntervalSince(segmentStartedAt)
    if !calendar.isDate(segmentStartedAt, inSameDayAs: now) {
      return hadSound ? .cut(.midnight) : .discardSilence
    }
    if elapsed >= maximumDuration { return hadSound ? .cut(.maximumDuration) : .discardSilence }
    if hadSound { return quietForThreshold ? .cut(.silence) : .keep }
    return elapsed >= silenceThreshold ? .discardSilence : .keep
  }
}

struct LifelogCaptureResult: Sendable {
  var url: URL
  var seconds: TimeInterval
  var writeError: String?
}

/// Microphone capture that can switch output files without stopping.
protocol LifelogCapture: AnyObject {
  var onSamples: (@Sendable ([Int16]) -> Void)? { get set }
  /// The audio engine stopped underneath us (device change or removal).
  var onInterruption: (@Sendable () -> Void)? { get set }
  var isRunning: Bool { get }
  func start(writingTo url: URL, preferredDeviceUID: String?) throws
  /// Finishes the current file and continues into `url` without an intentional engine restart: the
  /// engine keeps running and the next buffer goes to the new file.
  func rotate(to url: URL) throws -> LifelogCaptureResult
  func stop() throws -> LifelogCaptureResult?
}

/// A microphone-only recorder for always-on mode. It mirrors the device and
/// format handling of `MicrophoneRecorder.startEngine`, but owns its own
/// engine and swaps WAV files under one lock instead of restarting capture.
final class LifelogRecorder: LifelogCapture, @unchecked Sendable {
  var onSamples: (@Sendable ([Int16]) -> Void)? {
    get { lock.withLock { samplesHandler } }
    set { lock.withLock { samplesHandler = newValue } }
  }
  var onInterruption: (@Sendable () -> Void)? {
    get { lock.withLock { interruptionHandler } }
    set { lock.withLock { interruptionHandler = newValue } }
  }
  var isRunning: Bool { lock.withLock { tapping } }

  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var samplesHandler: (@Sendable ([Int16]) -> Void)?
  private var interruptionHandler: (@Sendable () -> Void)?
  private var handle: FileHandle?
  private var outputURL: URL?
  private var byteCount = 0
  private var bytesSinceCheckpoint = 0
  private var writeError: Error?
  private var tapping = false
  private var activitySamples: [Int16] = []
  private var configurationObserver: NSObjectProtocol?

  init() {
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      let (tapping, handler) = self.lock.withLock { (self.tapping, self.interruptionHandler) }
      if tapping { handler?() }
    }
  }

  deinit {
    configurationObserver.map(NotificationCenter.default.removeObserver)
  }

  func start(writingTo url: URL, preferredDeviceUID: String?) throws {
    let created = try WavFile.create(at: url)
    lock.withLock {
      handle = created
      outputURL = url
      byteCount = 0
      bytesSinceCheckpoint = 0
      writeError = nil
      activitySamples.removeAll(keepingCapacity: true)
    }
    do { try startEngine(preferredDeviceUID: preferredDeviceUID) } catch {
      lock.withLock {
        try? handle?.close()
        handle = nil
        outputURL = nil
      }
      throw error
    }
  }

  func rotate(to url: URL) throws -> LifelogCaptureResult {
    let next = try WavFile.create(at: url)
    let (previous, bytes, previousURL, error) = lock.withLock {
      () -> (FileHandle?, Int, URL?, Error?) in
      let swapped = (handle, byteCount, outputURL, writeError)
      handle = next
      outputURL = url
      byteCount = 0
      bytesSinceCheckpoint = 0
      writeError = nil
      return swapped
    }
    guard let previous, let previousURL else { throw CocoaError(.fileNoSuchFile) }
    var failure = error
    do { try WavFile.finalize(previous, bytes: bytes) } catch {
      failure = error
      try? previous.close()
    }
    return LifelogCaptureResult(
      url: previousURL, seconds: Self.seconds(bytes), writeError: failure?.localizedDescription)
  }

  func stop() throws -> LifelogCaptureResult? {
    if lock.withLock({ tapping }) {
      engine.inputNode.removeTap(onBus: 0)
      lock.withLock { tapping = false }
      engine.stop()
    }
    let (previous, bytes, previousURL, error) = lock.withLock {
      () -> (FileHandle?, Int, URL?, Error?) in
      let taken = (handle, byteCount, outputURL, writeError)
      handle = nil
      outputURL = nil
      writeError = nil
      return taken
    }
    guard let previous, let previousURL else { return nil }
    var failure = error
    do { try WavFile.finalize(previous, bytes: bytes) } catch {
      failure = error
      try? previous.close()
    }
    return LifelogCaptureResult(
      url: previousURL, seconds: Self.seconds(bytes), writeError: failure?.localizedDescription)
  }

  private static func seconds(_ bytes: Int) -> TimeInterval {
    TimeInterval(bytes / MemoryLayout<Int16>.size) / TimeInterval(WavFile.sampleRate)
  }

  private func startEngine(preferredDeviceUID: String?) throws {
    let input = engine.inputNode
    if let preferredDeviceUID {
      guard let deviceID = MicrophoneDeviceProvider.audioDeviceID(forUID: preferredDeviceUID),
        let audioUnit = input.audioUnit
      else {
        throw NSError(
          domain: "LifelogRecorder", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The preferred microphone is unavailable"])
      }
      var selectedDevice = deviceID
      let status = AudioUnitSetProperty(
        audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
      guard status == noErr else {
        throw NSError(
          domain: "LifelogRecorder", code: Int(status),
          userInfo: [NSLocalizedDescriptionKey: "The preferred microphone could not be selected"])
      }
    }
    // Same stale-rate guard as MicrophoneRecorder: read the active device's
    // nominal rate, since a tap with a stale rate raises an ObjC exception.
    let reportedFormat = input.outputFormat(forBus: 0)
    let inputFormat = input.inputFormat(forBus: 0)
    let channelCount =
      reportedFormat.channelCount > 0 ? reportedFormat.channelCount : inputFormat.channelCount
    let sampleRate = hardwareInputSampleRate(for: input) ?? reportedFormat.sampleRate
    guard sampleRate > 0, channelCount > 0,
      let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount,
        interleaved: false),
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(WavFile.sampleRate), channels: 1,
        interleaved: false)
    else {
      throw NSError(
        domain: "LifelogRecorder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No microphone input is available"])
    }
    let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
    input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
      guard let self else { return }
      let converted: AVAudioPCMBuffer
      if let converter {
        let capacity =
          AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
          + 1
        guard let result = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
          return
        }
        var conversionError: NSError?
        let supplied = LifelogConverterInput(buffer: buffer)
        converter.convert(to: result, error: &conversionError) { _, status in
          supplied.next(status: status)
        }
        guard conversionError == nil else { return }
        converted = result
      } else {
        converted = buffer
      }
      guard let channel = converted.floatChannelData?[0] else { return }
      let samples = (0..<Int(converted.frameLength)).map { index -> Int16 in
        Int16(max(-1, min(1, channel[index])) * 32767)
      }
      self.write(samples)
      // The shared monitor needs >=50 ms. At high device sample rates a
      // converted tap can be shorter; accumulate instead of calling it silent.
      let observation = self.lock.withLock { () -> ([Int16], (@Sendable ([Int16]) -> Void)?) in
        self.activitySamples += samples
        guard self.activitySamples.count >= 1_600 else { return ([], nil) }
        let batch = self.activitySamples
        self.activitySamples.removeAll(keepingCapacity: true)
        return (batch, self.samplesHandler)
      }
      observation.1?(observation.0)
    }
    lock.withLock { tapping = true }
    engine.prepare()
    do { try engine.start() } catch {
      input.removeTap(onBus: 0)
      lock.withLock { tapping = false }
      throw error
    }
  }

  private func hardwareInputSampleRate(for input: AVAudioInputNode) -> Double? {
    guard let audioUnit = input.audioUnit else { return nil }
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(
      audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
      &deviceID, &deviceSize) == noErr, deviceID != kAudioObjectUnknown
    else { return nil }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var sampleRate = Float64(0)
    var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &sampleRateSize, &sampleRate)
      == noErr, sampleRate > 0
    else { return nil }
    return sampleRate
  }

  private func write(_ samples: [Int16]) {
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    lock.lock()
    defer { lock.unlock() }
    guard writeError == nil, let handle else { return }
    do {
      try handle.write(contentsOf: data)
      byteCount += data.count
      bytesSinceCheckpoint += data.count
      // Checkpoint every 10 s (meetings use 1 s): a crash loses at most the
      // header update, which `WavFile.repairHeader` restores on recovery.
      if bytesSinceCheckpoint >= Int(WavFile.sampleRate) * MemoryLayout<Int16>.size * 10 {
        try WavFile.checkpoint(handle, bytes: byteCount)
        bytesSinceCheckpoint = 0
      }
    } catch {
      writeError = error
    }
  }
}

private final class LifelogConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      status.pointee = .noDataNow
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}
