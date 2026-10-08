import Foundation
import NaturalLanguage

/// Fork: ISO 639-1 codes for comparing the transcript language with the
/// meeting-notes language and for naming `transcript.<code>.md`.
extension MeetingNotesLanguage {
  /// `nil` for `.source`, which never asks for a translation.
  var languageCode: String? {
    switch self {
    case .source: nil
    case .arabic: "ar"
    case .chineseSimplified: "zh"
    case .danish: "da"
    case .dutch: "nl"
    case .english: "en"
    case .finnish: "fi"
    case .french: "fr"
    case .german: "de"
    case .italian: "it"
    case .japanese: "ja"
    case .korean: "ko"
    case .norwegian: "nb"
    case .polish: "pl"
    case .portuguese: "pt"
    case .spanish: "es"
    case .swedish: "sv"
    case .turkish: "tr"
    case .ukrainian: "uk"
    }
  }

  init?(languageCode: String) {
    guard let match = Self.allCases.first(where: { $0.languageCode == languageCode }) else {
      return nil
    }
    self = match
  }
}

/// Fork: determines the predominant language of a final transcript from its
/// text, for every engine. FluidAudio's `SenseVoiceManager` strips its own
/// language tag inside a private decode step, so the script mix is the
/// common signal: kana marks Japanese even in kanji-heavy text, Hangul marks
/// Korean, other CJK ideographs mark Chinese, and alphabetic text is
/// classified by `NLLanguageRecognizer` among the notes languages.
enum TranscriptLanguageDetector {
  /// Share of kana among CJK characters from which a text counts as Japanese.
  static let japaneseKanaShare = 0.15

  static func detect(_ turns: [TranscriptTurn]) -> String? {
    detect(text: turns.map(\.text).joined(separator: "\n"))
  }

  static func detect(text: String) -> String? {
    var kana = 0
    var han = 0
    var hangul = 0
    var words = 0
    var inWord = false
    for scalar in text.unicodeScalars {
      var isWordLetter = false
      switch scalar.value {
      case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF,
        0xFF66...0xFF9D:
        kana += 1
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
        han += 1
      case 0x1100...0x11FF, 0x3131...0x318E, 0xAC00...0xD7A3:
        hangul += 1
      default:
        isWordLetter = CharacterSet.letters.contains(scalar)
      }
      if isWordLetter, !inWord { words += 1 }
      inWord = isWordLetter
    }
    let cjk = kana + han
    guard max(cjk, hangul, words) > 0 else { return nil }
    if hangul >= cjk, hangul >= words { return "ko" }
    if cjk >= words {
      return Double(kana) / Double(cjk) >= japaneseKanaShare ? "ja" : "zh"
    }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = MeetingNotesLanguage.allCases
      .compactMap(\.languageCode)
      .filter { !["zh", "ja", "ko"].contains($0) }
      .map(NLLanguage.init(rawValue:))
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue
  }
}
