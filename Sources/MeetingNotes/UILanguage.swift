import Foundation

/// The language of the application chrome. This deliberately stays separate
/// from `MeetingNotesLanguage`, which controls generated meeting documents.
enum UILanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case chineseSimplified
  case english

  static let defaultsKey = "ui.language"

  var id: Self { self }

  var locale: Locale {
    switch self {
    case .system: Locale(identifier: Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en")
    case .chineseSimplified: Locale(identifier: "zh-Hans")
    case .english: Locale(identifier: "en")
    }
  }

  func label(in bundle: Bundle = .main) -> String {
    switch self {
    case .system: UIStrings.string("System Default", language: .load(), bundle: bundle)
    case .chineseSimplified: UIStrings.string("Simplified Chinese", language: .load(), bundle: bundle)
    case .english: UIStrings.string("English", language: .load(), bundle: bundle)
    }
  }

  static func load(from defaults: UserDefaults = .standard) -> UILanguage {
    defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
  }

  static func save(_ language: UILanguage, to defaults: UserDefaults = .standard) {
    defaults.set(language.rawValue, forKey: defaultsKey)
  }

  static func displayed(for locale: Locale) -> UILanguage {
    locale.identifier.lowercased().hasPrefix("zh") ? .chineseSimplified : .english
  }
}

/// Explicit lookup is required because a user-selected UI language is not the
/// process language. SwiftUI's environment covers static `Text` literals;
/// strings assembled in models, menus and alerts must use this helper.
enum UIStrings {
  static func bytes(_ value: Int64, language: UILanguage = .load()) -> String {
    value.formatted(.byteCount(style: .file).locale(language.locale))
  }
  static func format(_ key: String, language: UILanguage, _ arguments: CVarArg...) -> String {
    String(format: string(key, language: language), locale: language.locale, arguments: arguments)
  }

  static func string(_ key: String, language: UILanguage, bundle: Bundle = .main) -> String {
    let localization: String
    switch language {
    case .system:
      localization = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    case .chineseSimplified: localization = "zh-Hans"
    case .english: localization = "en"
    }
    let localizedBundle = bundle.path(forResource: localization, ofType: "lproj")
      .flatMap(Bundle.init(path:))
    let fallback = bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    let missing = "__MISSING_LOCALIZATION__"
    let translated = localizedBundle?.localizedString(forKey: key, value: missing, table: "Localizable")
    if let translated, translated != missing { return translated }
    let english = fallback?.localizedString(forKey: key, value: missing, table: "Localizable")
    return english == nil || english == missing ? key : english!
  }
}

/// A cached, bounded entry for the unified Today timeline. The source remains
/// `LifelogStore`; it never receives a MeetingStore ID or archive action.
struct TodayLifelogSummary: Identifiable, Equatable {
  let id: UUID
  let startedAt: Date
  let endedAt: Date?
  let status: LifelogSegment.Status
  let characterCount: Int
  let folder: URL
  let error: String?
  var screenFolder: URL? = nil
  var media: UnifiedCaptureMetadata? = nil
}

/// Explicit interpolation preserves the English key and never interprets user
/// text as a format string. Numerals and dates are supplied by the caller.
struct UIString: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  var key: String
  var arguments: [String]
  init(stringLiteral value: String) { key = value; arguments = [] }
  init(stringInterpolation: StringInterpolation) {
    key = stringInterpolation.key; arguments = stringInterpolation.arguments
  }
  struct StringInterpolation: StringInterpolationProtocol {
    var key = ""; var arguments: [String] = []
    init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
    mutating func appendLiteral(_ literal: String) { key += literal }
    mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
  }
}

extension UIStrings {
  static func text(_ value: UIString, language: UILanguage = .load(), bundle: Bundle = .main) -> String {
    substitute(string(value.key, language: language, bundle: bundle), arguments: value.arguments)
  }
  static func substitute(_ template: String, arguments: [String]) -> String {
    let parts = template.components(separatedBy: "%@")
    guard parts.count == arguments.count + 1 else { return template }
    return parts.enumerated().map { index, part in part + (index < arguments.count ? arguments[index] : "") }.joined()
  }
  /// Legacy model status remains English so equality checks and persisted/raw
  /// contracts do not change. Resolve only at an owned presentation boundary.
  /// Unknown OS/backend error details remain verbatim.
  static func resolve(_ value: String, language: UILanguage = .load(), bundle: Bundle = .main) -> String {
    let exact = string(value, language: language, bundle: bundle)
    if exact != value { return exact }
    for entry in templates(bundle: bundle) {
      let range = NSRange(value.startIndex..., in: value)
      guard let match = entry.regex.firstMatch(in: value, range: range) else { continue }
      let arguments = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: value).map { String(value[$0]) } }
      return substitute(string(entry.key, language: language, bundle: bundle), arguments: arguments)
    }
    return value
  }
  private struct Template {
    let key: String; let regex: NSRegularExpression
  }
  private static func templates(bundle: Bundle) -> [Template] {
    // The small immutable catalog is loaded once per bundle; no archive reads
    // or model requests occur in a SwiftUI body.
    TemplateCache.shared.get(bundle)
  }
  private final class TemplateCache: @unchecked Sendable {
    static let shared = TemplateCache()
    private let lock = NSLock()
    private var cached: [String: [Template]] = [:]
    func get(_ bundle: Bundle) -> [Template] {
      lock.withLock {
        if let value = cached[bundle.bundlePath] { return value }
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"),
          let data = try? Data(contentsOf: url),
          let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
        else { return [] }
        let value = table.keys.filter { $0.contains("%@") && $0.replacingOccurrences(of: "%@", with: "").count > 5 }
          .sorted { $0.count > $1.count }.compactMap { key -> Template? in
            let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Template(key: key, regex: regex)
          }
        cached[bundle.bundlePath] = value
        return value
      }
    }
  }
}
