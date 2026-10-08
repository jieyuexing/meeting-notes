import AppKit
import CoreGraphics
import Foundation

/// The conservative display prerequisite for unified capture.
///
/// macOS has no public, stable "the screen is unlocked" predicate.  In
/// particular, successful ScreenCaptureKit content enumeration is also
/// possible around the lock transition.  This gate therefore starts unknown,
/// treats every sleep/wake transition as unsafe, and requires a fresh desktop
/// session + display observation before capture can be started again.
enum DisplayCaptureGateState: Equatable, Sendable {
  case unknown
  case ready
  case paused(DisplayCapturePauseReason)
}

enum DisplayCapturePauseReason: String, Equatable, Sendable {
  case screenSleep
  case systemSleep
  case noDesktopSession
  case sessionInactive
  case noDisplay
  case unavailable
}

protocol DisplayCaptureAvailabilityProviding: Sendable {
  func availability() async -> DisplayCaptureAvailability
}

struct DisplayCaptureAvailability: Equatable, Sendable {
  var hasDesktopSession: Bool
  var hasDisplay: Bool
  var awakeDisplayIDs: [UInt32] = []

  static let unavailable = Self(hasDesktopSession: false, hasDisplay: false)
}

/// Default provider deliberately checks more than SCShareableContent: it
/// observes the current console session and the AppKit display list.  It still
/// cannot prove a human has unlocked the machine, which is why callers must
/// keep the unknown/paused policy visible in the UI rather than calling this a
/// lock-screen guarantee.
struct DesktopDisplayAvailabilityProvider: DisplayCaptureAvailabilityProviding {
  func availability() async -> DisplayCaptureAvailability {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? false
    // No public active/unlocked key exists. The observed lock bit, when present,
    // and distributed lock notifications are defensive, undocumented signals.
    // They are not a public macOS lock guarantee. Missing "active" is normal.
    let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return .unavailable }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return .unavailable }
    return DisplayCaptureAvailability(
      hasDesktopSession: onConsole && !locked,
      hasDisplay: displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 },
      awakeDisplayIDs: displays.prefix(Int(count)).filter { CGDisplayIsAsleep($0) == 0 }.sorted())
  }
}

/// Serializes display sleep/wake notifications and asynchronous availability
/// checks. `generation` makes a late pre-sleep check harmless after a newer
/// sleep, wake, stop, or explicit retry.
final class DisplayCaptureGate: @unchecked Sendable {
  private let lock = NSLock()
  private let provider: any DisplayCaptureAvailabilityProviding
  private var generation = 0
  private var hardPauses: Set<DisplayCapturePauseReason> = []
  private var displayIDs: [UInt32] = []
  var awakeDisplayIDs: [UInt32] { lock.withLock { displayIDs } }
  private var currentState: DisplayCaptureGateState = .unknown

  var onStateChange: (@Sendable (DisplayCaptureGateState) -> Void)?

  init(provider: any DisplayCaptureAvailabilityProviding = DesktopDisplayAvailabilityProvider()) {
    self.provider = provider
  }

  var state: DisplayCaptureGateState { lock.withLock { currentState } }
  var isReady: Bool { state == .ready }

  /// Invalidates any in-flight result and leaves capture closed until a caller
  /// explicitly checks the current desktop/display state.
  func begin() { transition(.unknown) }

  func screensDidSleep() { transition(.paused(.screenSleep), hard: .screenSleep) }
  func systemWillSleep() { transition(.paused(.systemSleep), hard: .systemSleep) }
  func sessionDidResignActive() { transition(.paused(.sessionInactive), hard: .sessionInactive) }
  func screensDidWake() { wake(.screenSleep) }
  func systemDidWake() { wake(.systemSleep) }
  func sessionDidBecomeActive() { wake(.sessionInactive) }

  /// Rechecks the provider. The caller may invoke this after a user presses
  /// Start; a wake notification alone is never sufficient to resume capture.
  func recheck() async -> DisplayCaptureGateState {
    let token = lock.withLock { () -> Int in guard hardPauses.isEmpty else { return -1 }; generation += 1; return generation }
    guard token >= 0 else { return state }
    let observation = await provider.availability()
    let next: DisplayCaptureGateState
    if !observation.hasDesktopSession { next = .paused(.noDesktopSession) }
    else if !observation.hasDisplay { next = .paused(.noDisplay) }
    else { next = .ready }
    let handler = lock.withLock { () -> (@Sendable (DisplayCaptureGateState) -> Void)? in
      guard token == generation, hardPauses.isEmpty else { return nil }
      currentState = next
      displayIDs = observation.awakeDisplayIDs
      return onStateChange
    }
    handler?(next)
    return state
  }

  private func wake(_ reason: DisplayCapturePauseReason) {
    let next = lock.withLock { () -> DisplayCaptureGateState in
      generation += 1
      hardPauses.remove(reason)
      currentState = hardPauses.sorted { $0.rawValue < $1.rawValue }.first.map { .paused($0) } ?? .unknown
      return currentState
    }
    onStateChange?(next)
  }

  private func transition(_ state: DisplayCaptureGateState, hard: DisplayCapturePauseReason? = nil, clearHard: Bool = false) {
    let handler = lock.withLock { () -> (@Sendable (DisplayCaptureGateState) -> Void)? in
      generation += 1
      if clearHard { hardPauses.removeAll() }
      if let hard { hardPauses.insert(hard) }
      currentState = state
      return onStateChange
    }
    handler?(state)
  }
}
