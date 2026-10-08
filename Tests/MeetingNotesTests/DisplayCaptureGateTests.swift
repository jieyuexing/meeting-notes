import Foundation
import Testing

@testable import MeetingNotes

private struct GateProvider: DisplayCaptureAvailabilityProviding {
  let observation: DisplayCaptureAvailability
  func availability() async -> DisplayCaptureAvailability { observation }
}

private struct SlowGateProvider: DisplayCaptureAvailabilityProviding {
  func availability() async -> DisplayCaptureAvailability {
    try? await Task.sleep(for: .milliseconds(30))
    return .init(hasDesktopSession: true, hasDisplay: true)
  }
}

@Test func displayCaptureGateStartsUnknownAndNeedsFreshCheck() async {
  let gate = DisplayCaptureGate(provider: GateProvider(observation: .init(hasDesktopSession: true, hasDisplay: true)))
  #expect(gate.state == .unknown)
  #expect(await gate.recheck() == .ready)
  gate.screensDidWake()
  #expect(gate.state == .unknown)
}

@Test func displayCaptureGateRejectsMissingDesktopOrDisplay() async {
  let noSession = DisplayCaptureGate(provider: GateProvider(observation: .init(hasDesktopSession: false, hasDisplay: true)))
  #expect(await noSession.recheck() == .paused(.noDesktopSession))
  let noDisplay = DisplayCaptureGate(provider: GateProvider(observation: .init(hasDesktopSession: true, hasDisplay: false)))
  #expect(await noDisplay.recheck() == .paused(.noDisplay))
}

@Test func displaySleepWinsAgainstLateReadyResult() async {
  let gate = DisplayCaptureGate(provider: SlowGateProvider())
  let check = Task { await gate.recheck() }
  await Task.yield()
  gate.systemWillSleep()
  _ = await check.value
  #expect(gate.state == .paused(.systemSleep))
}

@Test func repeatedSleepWakeLeavesGateConservativelyUnknown() {
  let gate = DisplayCaptureGate(provider: GateProvider(observation: .unavailable))
  gate.screensDidSleep()
  gate.screensDidSleep()
  #expect(gate.state == .paused(.screenSleep))
  gate.systemDidWake()
  gate.screensDidWake()
  #expect(gate.state == .unknown)
}

@Test func hardSleepLatchRejectsAProviderReadyResultUntilWake() async {
  let gate = DisplayCaptureGate(provider: GateProvider(observation: .init(hasDesktopSession: true, hasDisplay: true)))
  gate.screensDidSleep()
  #expect(await gate.recheck() == .paused(.screenSleep))
  gate.screensDidWake()
  #expect(await gate.recheck() == .ready)
}
