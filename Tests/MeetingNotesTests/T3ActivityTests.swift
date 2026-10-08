import Foundation
import Testing
@testable import MeetingNotes

private actor T3Replies {
  var replies: [Data]
  private(set) var arguments: [[String]] = []
  init(_ replies: [Data]) { self.replies = replies }
  func call(_ arguments: [String]) throws -> Data {
    self.arguments.append(arguments)
    guard !replies.isEmpty else { throw CocoaError(.fileReadUnknown) }
    return replies.removeFirst()
  }
}
private func response(status: String = "final", text: String? = "final answer", cursor: String? = nil,
  incomplete: Bool = false, version: Int = 1, truncated: Bool = false) throws -> Data {
  var message: [String: Any] = ["sourceId":"m", "threadId":"t", "role":"assistant", "status":status,
    "createdAt":"2026-10-08T23:59:00.123Z", "updatedAt":"2026-10-09T00:01:00Z", "contentHash":status,
    "textTruncated":false]
  if let text { message["text"] = text }
  return try JSONSerialization.data(withJSONObject: ["schemaVersion":version,"sourceKind":"t3.projection.observe",
    "observedAt":"2026-10-09T00:02:00.234Z","incomplete":incomplete,"nextCursor":cursor as Any? ?? NSNull(),
    "items":[["thread":["threadId":"t","title":"Fixture","link":"[Fixture](t3-thread://v1/e/t)","updatedAt":"2026-10-09T00:01:00Z"],
      "messages":[message],"runs":[["sourceId":"r","threadId":"t","status":"completed","requestedAt":"2026-10-08T23:59:00Z","completedAt":"2026-10-09T00:01:00Z"]],
      "messagesTruncated":truncated,"runsTruncated":false]]])
}
private func t3Root() -> URL { TestTemporary.root.appending(path: "t3-fixture-\(UUID().uuidString)") }
private let enabled = Date(timeIntervalSince1970: 1791417600)

@Test func t3SameIDFinalUpdateDatesRestartAndMetadataMode() async throws {
  let root = t3Root(); defer { try? FileManager.default.removeItem(at: root) }
  let replies = T3Replies(try [response(status: "streaming", text: "must not retain"), response()])
  let config = T3ActivityCollector.Configuration(root: root, enabledAt: enabled, t3ctlURL: URL(fileURLWithPath: "/fixture"), mode: .includeText)
  let c = T3ActivityCollector(configuration: config, transport: { try await replies.call($0) })
  await c.pollOnce()
  #expect(await c.currentSnapshot().messages.first?.text == nil)
  await c.pollOnce()
  let snapshot = await c.currentSnapshot()
  #expect(snapshot.messages.count == 1)
  #expect(snapshot.messages.first?.text == "final answer")
  #expect(snapshot.lastSuccessObservedAt != nil)
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let yesterday = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
  #expect(await c.snapshot(for: yesterday, calendar: calendar).messages.count == 1)
  #expect(await c.snapshot(for: yesterday, calendar: calendar).runs.count == 1)
  let restarted = T3ActivityCollector(configuration: config, transport: { _ in throw CocoaError(.fileReadUnknown) })
  #expect(await restarted.currentSnapshot() == snapshot)
  let metadata = T3ActivityCollector(configuration: .init(root: root, enabledAt: enabled, t3ctlURL: config.t3ctlURL, mode: .metadata))
  #expect(await metadata.currentSnapshot().messages.first?.text == nil)
  #expect(!String(decoding: try Data(contentsOf: root.appending(path: "t3/activity.json")), as: UTF8.self).contains("final answer"))
  #expect(T3ActivityCollector.threadURL("[Fixture](t3-thread://v1/e/t)")?.absoluteString == "t3-thread://v1/e/t")
}

@Test func t3IncompleteSchemaAndPaginationNeverAdvanceWatermark() async throws {
  for data in try [response(version: 2), response(truncated: true), response(incomplete: true)] {
    let root = t3Root(); defer { try? FileManager.default.removeItem(at: root) }
    let c = T3ActivityCollector(configuration: .init(root: root, enabledAt: enabled, t3ctlURL: URL(fileURLWithPath: "/fixture"), mode: .includeText), transport: { _ in data })
    await c.pollOnce()
    #expect(await c.currentSnapshot().lastSuccessObservedAt == nil)
    #expect(await c.currentSnapshot().messages.isEmpty)
  }
  let root = t3Root(); defer { try? FileManager.default.removeItem(at: root) }
  let replies = T3Replies(try [response(cursor: "same", incomplete: true), response(cursor: "same", incomplete: true)])
  let c = T3ActivityCollector(configuration: .init(root: root, enabledAt: enabled, t3ctlURL: URL(fileURLWithPath: "/fixture"), mode: .includeText), transport: { try await replies.call($0) })
  await c.pollOnce()
  #expect(await c.currentSnapshot().lastSuccessObservedAt == nil)
  #expect(await replies.arguments.count == 2)
}

@Test func t3PipesDrainLargeOutputAndTimeoutCancellation() async throws {
  let data = try await T3ActivityCollector.processTransport(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys; sys.stdout.write('x'*200000); sys.stderr.write('e'*20000)"])
  #expect(data.count == 200000)
  await #expect(throws: (any Error).self) {
    _ = try await T3ActivityCollector.processTransport(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(10)"], timeout: 0.1)
  }
  let task = Task { try await T3ActivityCollector.processTransport(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(10)"]) }
  try await Task.sleep(for: .milliseconds(100)); task.cancel()
  do { _ = try await task.value; Issue.record("Cancelled process succeeded") } catch { #expect(error is CancellationError) }
}

@Test func t3InheritedPipeDoesNotHoldTheCollectorOpen() async throws {
  let started = Date()
  let data = try await T3ActivityCollector.processTransport(executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "sleep 3 & printf fixture"])
  #expect(String(decoding: data, as: UTF8.self) == "fixture")
  #expect(Date().timeIntervalSince(started) < 2)
}
