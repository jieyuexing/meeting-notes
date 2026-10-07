import Foundation

enum SummaryBackend: String, CaseIterable, Identifiable, Sendable {
  case codex, command, off

  var id: Self { self }
  var label: String {
    switch self {
    case .codex: "Codex"
    case .command: "Custom command"
    case .off: "Off"
    }
  }
}

struct SummaryBackendSettings: Equatable, Sendable {
  var backend: SummaryBackend = .codex
  var command = ""
}

enum SummaryBackendSettingsStore {
  static func load(from defaults: UserDefaults = .standard) -> SummaryBackendSettings {
    SummaryBackendSettings(
      backend: defaults.string(forKey: "summary.backend").flatMap(SummaryBackend.init(rawValue:))
        ?? .codex,
      command: defaults.string(forKey: "summary.command") ?? "")
  }

  static func save(_ settings: SummaryBackendSettings, to defaults: UserDefaults = .standard) {
    defaults.set(settings.backend.rawValue, forKey: "summary.backend")
    defaults.set(settings.command, forKey: "summary.command")
  }
}
