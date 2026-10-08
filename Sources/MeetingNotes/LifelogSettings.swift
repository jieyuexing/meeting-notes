import Foundation

/// Fork: settings of the always-on ("lifelog") mode. Lifelog recordings live
/// in their own root, never in the meeting archive or the recovery spool.
enum LifelogDigestBackend: String, CaseIterable, Identifiable, Sendable {
  case command, codex, off

  var id: Self { self }
  var label: String {
    switch self {
    case .command: "Custom command"
    case .codex: "Codex"
    case .off: "Off"
    }
  }
}

struct LifelogSettings: Equatable, Sendable {
  static let defaultRootPath = "~/jieyuexing-universe/.state/opsail/lifelog"
  static let silenceRange: ClosedRange<TimeInterval> = 30...1_800
  static let maximumSegmentRange: ClosedRange<TimeInterval> = 60...14_400
  static let chunkRange: ClosedRange<Int> = 2_000...200_000

  var enabled = false
  var rootPath = defaultRootPath
  /// Continuous quiet after speech that ends a segment.
  var silenceThreshold: TimeInterval = 180
  /// Hard upper bound of one segment, even while someone keeps talking.
  var maximumSegmentDuration: TimeInterval = 1_800
  var digestBackend: LifelogDigestBackend = .command
  /// Empty means no daily digest is generated.
  var digestCommand = ""
  /// Local minute of the day the digest of that same day is generated.
  var digestMinuteOfDay = 23 * 60 + 55
  var digestChunkCharacters = 12_000

  var rootURL: URL {
    URL(
      fileURLWithPath: (rootPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
        .expandingTildeInPath,
      isDirectory: true
    ).standardizedFileURL
  }

  /// The backend the digest is dispatched to, or nil when no digest is due:
  /// Off, or a command backend whose command is still blank.
  var digestBackendSettings: SummaryBackendSettings? {
    switch digestBackend {
    case .off: return nil
    case .codex: return SummaryBackendSettings(backend: .codex, command: "")
    case .command:
      let command = digestCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      return command.isEmpty ? nil : SummaryBackendSettings(backend: .command, command: command)
    }
  }

  var digestTimeText: String {
    String(format: "%02d:%02d", digestMinuteOfDay / 60, digestMinuteOfDay % 60)
  }

  /// Rejects relative roots and any root that equals, contains or lies inside
  /// a meeting storage location, so neither side can scan or sync the other.
  static func rootError(_ rootPath: String, reserved: [URL]) -> String? {
    let expanded = (rootPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
      .expandingTildeInPath
    guard expanded.hasPrefix("/") else { return "Choose an absolute folder for always-on records." }
    let candidate = URL(fileURLWithPath: expanded, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard candidate != "/" else { return "The filesystem root cannot store always-on records." }
    for location in reserved {
      let other = location.standardizedFileURL.resolvingSymlinksInPath().path
      if candidate == other || candidate.hasPrefix(other + "/") || other.hasPrefix(candidate + "/") {
        return "Always-on records must stay outside the meeting archive and recovery spool."
      }
    }
    return nil
  }
}

enum LifelogSettingsStore {
  private enum Key {
    static let enabled = "lifelog.enabled"
    static let rootPath = "lifelog.rootPath"
    static let silence = "lifelog.silenceSeconds"
    static let maximum = "lifelog.maximumSegmentSeconds"
    static let backend = "lifelog.digest.backend"
    static let command = "lifelog.digest.command"
    static let minute = "lifelog.digest.minuteOfDay"
    static let chunk = "lifelog.digest.chunkCharacters"
  }

  static func load(from defaults: UserDefaults = .standard) -> LifelogSettings {
    var settings = LifelogSettings()
    settings.enabled = defaults.bool(forKey: Key.enabled)
    if let path = defaults.string(forKey: Key.rootPath),
      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      settings.rootPath = path
    }
    if defaults.object(forKey: Key.silence) != nil {
      settings.silenceThreshold = clamp(defaults.double(forKey: Key.silence), LifelogSettings.silenceRange)
    }
    if defaults.object(forKey: Key.maximum) != nil {
      settings.maximumSegmentDuration = clamp(
        defaults.double(forKey: Key.maximum), LifelogSettings.maximumSegmentRange)
    }
    settings.digestBackend =
      defaults.string(forKey: Key.backend).flatMap(LifelogDigestBackend.init(rawValue:)) ?? .command
    settings.digestCommand = defaults.string(forKey: Key.command) ?? ""
    if defaults.object(forKey: Key.minute) != nil {
      let minute = defaults.integer(forKey: Key.minute)
      if (0..<(24 * 60)).contains(minute) { settings.digestMinuteOfDay = minute }
    }
    if defaults.object(forKey: Key.chunk) != nil {
      settings.digestChunkCharacters = clamp(defaults.integer(forKey: Key.chunk), LifelogSettings.chunkRange)
    }
    return settings
  }

  static func save(_ settings: LifelogSettings, to defaults: UserDefaults = .standard) {
    defaults.set(settings.enabled, forKey: Key.enabled)
    defaults.set(settings.rootPath, forKey: Key.rootPath)
    defaults.set(settings.silenceThreshold, forKey: Key.silence)
    defaults.set(settings.maximumSegmentDuration, forKey: Key.maximum)
    defaults.set(settings.digestBackend.rawValue, forKey: Key.backend)
    defaults.set(settings.digestCommand, forKey: Key.command)
    defaults.set(settings.digestMinuteOfDay, forKey: Key.minute)
    defaults.set(settings.digestChunkCharacters, forKey: Key.chunk)
  }

  private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
  }
}
