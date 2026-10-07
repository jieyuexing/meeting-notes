import Foundation
import Sparkle
import Testing
@testable import MeetingNotes

@Test @MainActor func forkRefusesAllSparkleChecksThroughDelegate() throws {
  let delegate = UpdateChannelDelegate()
  // Do not start the updater or any application services in this test.
  let controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
  let updater = controller.updater
  #expect(delegate.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
  for check in [SPUUpdateCheck.updates, .updatesInBackground, .updateInformation] {
    do {
      try delegate.updater(updater, mayPerform: check)
      Issue.record("Fork must refuse every update check, including manual checks")
    } catch {
      #expect((error as NSError).domain == "MeetingNotes.ForkUpdates")
    }
  }
}

@Test func forkFeedCannotBeRewrittenToBetaUpstream() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let plist = try #require(
    PropertyListSerialization.propertyList(
      from: Data(contentsOf: root.appending(path: "Resources/Info.plist")), format: nil)
      as? [String: Any])
  #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
  #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
  let feed = try #require(plist["SUFeedURL"] as? String)
  #expect(feed == "https://raw.githubusercontent.com/jieyuexing/meeting-notes/jie-custom/fork-appcast.xml")
  for channel in UpdateChannel.allCases {
    #expect(channel.feedURLString(configuredFeed: feed) == nil)
  }
  let xml = try String(contentsOf: root.appending(path: "fork-appcast.xml"), encoding: .utf8)
  #expect(!xml.contains("<item"))
  #expect(!xml.contains("<enclosure"))
}
