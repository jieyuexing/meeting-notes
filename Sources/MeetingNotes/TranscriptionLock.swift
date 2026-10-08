import Darwin
import Foundation

/// A lease for final transcription of a recording folder, shared by processes.
/// Keep the inode on disk: unlinking an advisory lock lets waiters lock different
/// inodes. A leftover file is harmless; the kernel releases ownership on exit.
enum TranscriptionLock {
  final class Lease: Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
      self.descriptor = descriptor
    }

    deinit { close(descriptor) }
  }

  static func acquire(audioURLs: [URL]) async throws -> [Lease] {
    // Normally both streams share one folder. Canonical ordering also handles
    // distinct folders without AB/BA deadlock, including aliases via symlinks.
    let folders = Set(audioURLs.map {
      $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    }).sorted()
    var leases: [Lease] = []
    for folder in folders {
      try Task.checkCancellation()
      // Leave missing-audio handling to the existing transcription pipeline.
      guard FileManager.default.fileExists(atPath: folder) else { continue }
      let path = URL(fileURLWithPath: folder).appendingPathComponent(".transcription.lock").path
      let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw posixError() }
      do {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
          let code = errno
          guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
          }
          // Do not block a Swift executor thread or turn contention into a
          // failed meeting. Cancellation interrupts the wait promptly.
          try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        leases.append(Lease(descriptor: descriptor))
      } catch {
        close(descriptor)
        throw error
      }
    }
    return leases
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
