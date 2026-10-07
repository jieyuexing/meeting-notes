import Foundation
import Sparkle

/// Fail closed even when a previous upstream install saved automatic checking
/// or an upstream feed URL in UserDefaults. Keep this fork policy in one new file.
extension UpdateChannelDelegate {
  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    throw NSError(
      domain: "MeetingNotes.ForkUpdates", code: 1,
      userInfo: [NSLocalizedDescriptionKey:
        "Updates are disabled in this custom build. Build and install jie-custom locally."])
  }
}
