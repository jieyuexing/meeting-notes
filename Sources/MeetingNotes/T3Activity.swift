import Foundation
import Darwin

/// Local, read-only cache of T3 task evidence. It never infers foreground focus.
actor T3ActivityCollector {
  enum Mode: String, Codable, Sendable { case metadata, includeText }
  enum State: Equatable, Sendable { case stopped, idle, polling, unsupported(String), failed(String) }
  struct Configuration: Sendable {
    let root: URL; let enabledAt: Date; let t3ctlURL: URL; let mode: Mode; let project: String?
    init(root: URL, enabledAt: Date, t3ctlURL: URL, mode: Mode, project: String? = nil) {
      self.root = root; self.enabledAt = enabledAt; self.t3ctlURL = t3ctlURL; self.mode = mode; self.project = project
    }
  }
  struct Message: Codable, Identifiable, Equatable, Sendable {
    let id: String; var threadId: String; var runId: String?; var role: String; var status: String
    var createdAt: Date; var updatedAt: Date; var contentHash: String; var text: String?; var textTruncated: Bool = false
  }
  struct Run: Codable, Identifiable, Equatable, Sendable {
    let id: String; var threadId: String; var status: String; var requestedAt: Date; var startedAt: Date?; var completedAt: Date?
  }
  struct Thread: Codable, Identifiable, Equatable, Sendable {
    let id: String; var title: String; var link: String?; var worktreePath: String?; var updatedAt: Date
  }
  struct Snapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1; var enabledAt: Date; var lastSuccessObservedAt: Date?; var threads: [Thread] = []; var messages: [Message] = []; var runs: [Run] = []
  }
  typealias Transport = @Sendable (_ arguments: [String]) async throws -> Data
  private let configuration: Configuration; private let transport: Transport; private var snapshot: Snapshot; private var task: Task<Void, Never>?; private(set) var state: State = .stopped; private var generation = 0; private var polling = false
  init(configuration: Configuration, transport: Transport? = nil) {
    self.configuration = configuration
    self.transport = transport ?? { arguments in try await Self.processTransport(executable: configuration.t3ctlURL, arguments: arguments) }
    do {
      self.snapshot = try Self.load(from: configuration.root)
      guard self.snapshot.schemaVersion == 1 else { throw CollectorError.unsupported }
      if configuration.mode == .metadata {
        for i in self.snapshot.messages.indices { self.snapshot.messages[i].text = nil }
        try Self.save(self.snapshot, to: configuration.root)
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      self.snapshot = Snapshot(enabledAt: configuration.enabledAt)
    } catch {
      self.snapshot = Snapshot(enabledAt: configuration.enabledAt)
      self.state = .unsupported("Cannot read the existing T3 cache: " + error.localizedDescription)
    }
  }
  func start() { guard task == nil else { return }; if case .unsupported = state { return }; state = .idle; task = Task { [weak self] in while !Task.isCancelled { await self?.pollOnce(); try? await Task.sleep(for: .seconds(60)) } } }
  func stop() async { generation += 1; let previous = task; task?.cancel(); task = nil; state = .stopped; await previous?.value }
  func currentSnapshot() -> Snapshot { snapshot }
  func snapshot(for day: Date, calendar: Calendar = .autoupdatingCurrent) -> Snapshot {
    var result = snapshot; result.messages = result.messages.filter { calendar.isDate($0.updatedAt, inSameDayAs: day) || calendar.isDate($0.createdAt, inSameDayAs: day) }; result.runs = result.runs.filter { let start = calendar.startOfDay(for: day); let end = calendar.date(byAdding: .day, value: 1, to: start)!; return $0.requestedAt < end && ($0.completedAt ?? Date()) >= start }; return result
  }
  func pollOnce() async {
    guard !Task.isCancelled, !polling else { return }; if case .unsupported = state { return }; polling = true; defer { polling = false }; let epoch = generation; state = .polling
    let since = max(configuration.enabledAt, (snapshot.lastSuccessObservedAt ?? configuration.enabledAt).addingTimeInterval(-300))
    do {
      var cursor: String?; var next = snapshot; var newest: Date?; var cursors = Set<String>(); var pages = 0
      repeat {
        var arguments = ["m3max", "observe", "--since", Self.iso(since), "--limit", "50"]
        if let project = configuration.project { arguments += ["--project", project] }; if configuration.mode == .includeText { arguments.append("--include-text") }; if let cursor { arguments += ["--cursor", cursor] }
        let response = try Self.decoder.decode(Response.self, from: try await transport(arguments))
        pages += 1
        guard epoch == generation, !Task.isCancelled else { return }
        guard response.schemaVersion == 1, response.sourceKind == "t3.projection.observe", !response.items.contains(where: { $0.messagesTruncated || $0.runsTruncated }) else { state = .unsupported("T3 observation response is unsupported or truncated."); return }
        guard !(response.incomplete && response.nextCursor == nil) else { throw CollectorError.incomplete }
        // First-page observation is the conservative watermark. Later pages
        // must not move it past updates to previously read projections.
        newest = min(newest ?? response.observedAt, response.observedAt)
        for item in response.items { merge(item, into: &next) }
        cursor = response.nextCursor
        if let cursor { guard pages < 4, cursors.insert(cursor).inserted else { throw CollectorError.incomplete } }
      } while cursor != nil && !Task.isCancelled
      guard !Task.isCancelled, epoch == generation else { return }
      guard next.messages.count <= 10000, next.runs.count <= 10000 else { throw CollectorError.capacity };
      next.lastSuccessObservedAt = newest; try Self.save(next, to: configuration.root); snapshot = next; state = .idle
    } catch { if epoch == generation, !Task.isCancelled { state = .failed(error.localizedDescription) } }
  }
  private func merge(_ item: Item, into snapshot: inout Snapshot) {
    let thread = Thread(id: item.thread.threadId, title: item.thread.title ?? "T3", link: item.thread.link, worktreePath: item.thread.worktreePath, updatedAt: item.thread.updatedAt)
    snapshot.threads.removeAll { $0.id == thread.id }; snapshot.threads.append(thread)
    for message in item.messages where ["user", "assistant"].contains(message.role) { let row = Message(id: message.sourceId, threadId: message.threadId, runId: message.runId, role: message.role, status: message.status, createdAt: message.createdAt, updatedAt: message.updatedAt, contentHash: message.contentHash, text: configuration.mode == .includeText && (message.role == "user" || message.status == "final") ? message.text : nil, textTruncated: message.textTruncated); if snapshot.messages.contains(where: { $0.id == row.id && $0.threadId == row.threadId && $0.updatedAt > row.updatedAt }) { continue }; snapshot.messages.removeAll { $0.id == row.id && $0.threadId == row.threadId }; snapshot.messages.append(row) }
    for run in item.runs { let row = Run(id: run.sourceId, threadId: run.threadId, status: run.status, requestedAt: run.requestedAt, startedAt: run.startedAt, completedAt: run.completedAt); snapshot.runs.removeAll { $0.id == row.id && $0.threadId == row.threadId }; snapshot.runs.append(row) }
  }
  static func cachedSnapshot(root: URL, includeText: Bool) -> Snapshot? {
    guard var snapshot = try? load(from: root), snapshot.schemaVersion == 1 else { return nil }
    if !includeText { for index in snapshot.messages.indices { snapshot.messages[index].text = nil } }
    return snapshot
  }
  private static func file(_ root: URL) -> URL { root.appending(path: "t3/activity.json") }
  private static func load(from root: URL) throws -> Snapshot { try decoder.decode(Snapshot.self, from: Data(contentsOf: file(root))) }
  private static func save(_ snapshot: Snapshot, to root: URL) throws { let url = file(root); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: date))
    }; try encoder.encode(snapshot).write(to: url, options: .atomic) }
  private static func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
  enum CollectorError: LocalizedError {
    case unsupported, incomplete, capacity, process(Int32), timeout, outputLimit
    var errorDescription: String? {
      switch self {
      case .unsupported: "Unsupported T3 observation schema."
      case .incomplete: "T3 returned an incomplete range. The watermark was not advanced."
      case .capacity: "T3 cache limit reached. Choose a new recording root to continue."
      case .process(let code): "T3 service unavailable (exit \(code)). Check the t3ctl path and local T3 service."
      case .timeout: "T3 observation timed out."
      case .outputLimit: "T3 observation exceeded the output limit."
      }
    }
  }
  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { value in
      let text = try value.singleValueContainer().decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: text) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: text) else { throw CollectorError.unsupported }
      return date
    }
    return decoder
  }

  /// Both pipes are drained concurrently with bounded memory; waitUntilExit
  /// cannot deadlock on a full pipe. Cancellation sends TERM only once and
  /// allows t3ctl to run its session-revocation finally block.
  static func processTransport(executable: URL, arguments: [String], timeout: TimeInterval = 70) async throws -> Data {
    let process = Process(); process.executableURL = executable; process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
    process.environment = environment
    let out = Pipe(); let err = Pipe()
    process.standardOutput = out; process.standardError = err
    let output = BoundedT3Output(limit: 2_000_000)
    let errors = BoundedT3Output(limit: 32_000)
    try Task.checkCancellation()
    try process.run()
    let readers = DispatchGroup()
    let completion = T3PipeCompletion()
    for (pipe, buffer) in [(out, output), (err, errors)] {
      readers.enter()
      DispatchQueue.global(qos: .utility).async {
        defer { readers.leave() }
        // poll keeps inherited descriptors in a misconfigured helper from
        // blocking cancellation/quit forever after the owned process exits.
        let fd = pipe.fileHandleForReading.fileDescriptor
        defer { try? pipe.fileHandleForReading.close() }
        while !completion.expired {
          var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
          let ready = Darwin.poll(&descriptor, 1, 100)
          if ready == 0 { if completion.finished { return }; continue }
          if ready < 0 { if errno == EINTR { continue }; return }
          var bytes = [UInt8](repeating: 0, count: 8192)
          let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
          if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
          if count == 0 { return }
          buffer.append(Data(bytes.prefix(count)))
        }
      }
    }
    let started = Date()
    var failure: Error?
    var terminatingAt: Date?
    while process.isRunning {
      if failure == nil {
        if Task.isCancelled { failure = CancellationError() }
        else if output.exceeded || errors.exceeded { failure = CollectorError.outputLimit }
        else if Date().timeIntervalSince(started) >= timeout { failure = CollectorError.timeout }
        if failure != nil { process.terminate(); terminatingAt = Date() }
      }
      // The owned helper normally exits after its 10s bounded revoke. A stuck
      // executable cannot hang app quit forever. Forced termination is a
      // failure, never reported as successful cleanup (session TTL is fallback).
      if let terminatingAt, Date().timeIntervalSince(terminatingAt) > 25 { kill(process.processIdentifier, SIGKILL) }
      await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
    }
    completion.finish()
    await withCheckedContinuation { continuation in readers.notify(queue: .global()) { continuation.resume() } }
    if let failure { throw failure }
    guard !output.exceeded, !errors.exceeded else { throw CollectorError.outputLimit }
    guard process.terminationStatus == 0 else { throw CollectorError.process(process.terminationStatus) }
    return output.data
  }

}

private extension T3ActivityCollector {
  struct Response: Codable { let schemaVersion: Int; let sourceKind: String; let observedAt: Date; let items: [Item]; let nextCursor: String?; let incomplete: Bool }
  struct Item: Codable { let thread: SourceThread; let messages: [SourceMessage]; let runs: [SourceRun]; let messagesTruncated: Bool; let runsTruncated: Bool }
  struct SourceThread: Codable { let threadId: String; let title: String?; let link: String?; let worktreePath: String?; let updatedAt: Date }
  struct SourceMessage: Codable { let sourceId: String; let threadId: String; let runId: String?; let role: String; let status: String; let createdAt: Date; let updatedAt: Date; let contentHash: String; let text: String?; let textTruncated: Bool }
  struct SourceRun: Codable { let sourceId: String; let threadId: String; let status: String; let requestedAt: Date; let startedAt: Date?; let completedAt: Date? }
}

private final class BoundedT3Output: @unchecked Sendable {
  let limit: Int
  private let lock = NSLock()
  private var bytes = Data()
  private var overflow = false
  init(limit: Int) { self.limit = limit }
  func append(_ data: Data) { lock.withLock { if bytes.count + data.count > limit { overflow = true }; bytes.append(data.prefix(max(0, limit - bytes.count))) } }
  var data: Data { lock.withLock { bytes } }
  var exceeded: Bool { lock.withLock { overflow } }
}

private final class T3PipeCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date?
  func finish() { lock.withLock { date = Date() } }
  var finished: Bool { lock.withLock { date != nil } }
  var expired: Bool { lock.withLock { date.map { Date().timeIntervalSince($0) > 1 } ?? false } }
}
