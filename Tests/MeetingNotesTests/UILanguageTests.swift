import Foundation
import Testing
@testable import MeetingNotes

@Test func uiLookupActuallyFallsBackToEnglishAndInterpolatesWithoutFormatConfusion() throws {
  let folder = TestTemporary.root.appending(path: "lookup-\(UUID().uuidString).bundle")
  defer { try? FileManager.default.removeItem(at: folder) }
  let resources = folder.appending(path: "Contents/Resources")
  for language in ["en", "zh-Hans"] {
    try FileManager.default.createDirectory(at: resources.appending(path: "\(language).lproj"), withIntermediateDirectories: true)
  }
  let info = ["CFBundleIdentifier":"fixture.localization.\(UUID().uuidString)", "CFBundlePackageType":"BNDL"]
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appending(path: "Contents/Info.plist"))
  try Data("\"English only\" = \"English fallback\";\n\"Count: %@\" = \"Count: %@\";".utf8)
    .write(to: resources.appending(path: "en.lproj/Localizable.strings"))
  try Data("\"Count: %@\" = \"数量：%@\";".utf8)
    .write(to: resources.appending(path: "zh-Hans.lproj/Localizable.strings"))
  let bundle = try #require(Bundle(path: folder.path))
  #expect(UIStrings.string("English only", language: .chineseSimplified, bundle: bundle) == "English fallback")
  #expect(UIStrings.text("Count: \(12)", language: .chineseSimplified, bundle: bundle) == "数量：12")
  #expect(UIStrings.text("Count: \("100% %@ 用户正文")", language: .english, bundle: bundle) == "Count: 100% %@ 用户正文")
  #expect(UIStrings.resolve("Count: 12", language: .chineseSimplified, bundle: bundle) == "数量：12")
  #expect(UIStrings.resolve("Count: 12", language: .english, bundle: bundle) == "Count: 12")
}
