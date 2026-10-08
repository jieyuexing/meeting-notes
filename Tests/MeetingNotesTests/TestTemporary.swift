import Foundation

enum TestTemporary {
  static var root: URL {
    if let path = ProcessInfo.processInfo.environment["MEETING_NOTES_TEST_TMPDIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
  }
}
