import Foundation
import Darwin

@MainActor
final class ServiceConnection {
    let host: HostProfile
    var onMessage: ((WireMessage) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onSendError: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var mailbox: InboundMailbox?
    private var outbox: OutboundMailbox?
    private var callbacks: [String: (WireMessage) -> Void] = [:]
    private var generation = UUID()
    private var stopped = false
    private var usesSocket = false
    private var mayUpgradeLocalHelper = false
    private var hasSubmittedRequest = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff = ReconnectBackoff()
    private static let maximumCallbacks = 1024

    var outboundUsage: (bytes: Int, items: Int, callbacks: Int) {
        let usage = outbox?.usage ?? (bytes: 0, items: 0)
        return (usage.bytes, usage.items, callbacks.count)
    }

    init(host: HostProfile) { self.host = host }
    isolated deinit { releaseTransport() }

    func connect() {
        reconnectBackoff.reset()
        startConnection()
    }

    private func startConnection() {
        generation = UUID()
        releaseTransport()
        stopped = false
        let token = generation
        if host.isLocal, let socket = openLocalSocket() {
            consumeSocket(socket, token: token)
            return
        }
        let task = Process()
        if host.isLocal {
            guard let resources = Bundle.main.resourceURL else { onStatus?("The application resources are missing."); return }
            task.executableURL = resources.appendingPathComponent("bin/illogical")
            task.arguments = ["connect"]
        } else {
            guard let resources = Bundle.main.resourceURL else { onStatus?("The application resources are missing."); return }
            task.executableURL = resources.appendingPathComponent("bin/illogical")
            task.arguments = ["remote", host.address, host.executable]
        }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        do { try task.run() } catch { retry(after: error.localizedDescription, token: token); return }
        process = task; input = stdin.fileHandleForWriting
        guard installOutbox(token: token, socket: false) else { return }
        mayUpgradeLocalHelper = host.isLocal
        let reader = stdout.fileHandleForReading
        let errorReader = stderr.fileHandleForReading
        let errors = ErrorTail()
        DispatchQueue.global(qos: .utility).async {
            let descriptor = errorReader.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            while autoreleasepool(invoking: { () -> Bool in
                guard let data = try? Self.readAvailable(descriptor, buffer: &buffer) else { return false }
                errors.append(data); return true
            }) { }
            try? errorReader.close()
        }
        consume(reader, errors: errors, token: token)
    }

    private func openLocalSocket() -> (reader: FileHandle, writer: FileHandle)? {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["ILLOGICAL_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/illogical").path
        let path = environment["ILLOGICAL_SOCKET"] ?? directory + "/daemon.sock"
        let descriptor = path.withCString { il_connect_unix($0) }
        guard descriptor >= 0 else { return nil }
        let writer = Darwin.dup(descriptor)
        guard writer >= 0 else { Darwin.close(descriptor); return nil }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), FileHandle(fileDescriptor: writer, closeOnDealloc: true))
    }

    private func consumeSocket(_ socket: (reader: FileHandle, writer: FileHandle), token: UUID) {
        usesSocket = true
        input = socket.writer
        guard installOutbox(token: token, socket: true) else { try? socket.reader.close(); return }
        consume(socket.reader, errors: ErrorTail(), token: token)
    }

    private func consume(_ reader: FileHandle, errors: ErrorTail, token: UUID) {
        let mailbox = InboundMailbox()
        self.mailbox = mailbox
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? reader.close() }
            var framer = JSONLineFramer(maximumMessageSize: 128 * 1024 * 1024)
            let decoder = JSONDecoder()
            let descriptor = reader.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var failure: String?
            func enqueue(_ event: InboundMailbox.Event, wireBytes: Int = 0) -> Bool {
                switch mailbox.enqueue(event, wireBytes: wireBytes) {
                case .cancelled: return false
                case .accepted(let schedule):
                    if schedule {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token else { mailbox.cancel(); return }
                            self.drain(mailbox, token: token)
                        }
                    }
                    return true
                }
            }
            while autoreleasepool(invoking: { () -> Bool in
                do {
                    guard let data = try Self.readAvailable(descriptor, buffer: &buffer) else { return false }
                    for line in try framer.append(data) {
                        let message = try decoder.decode(WireMessage.self, from: line)
                        guard enqueue(.message(message), wireBytes: line.count) else { return false }
                    }
                    return true
                } catch {
                    // Dropping a malformed output record would corrupt the
                    // replica. Reconnect and recover an authoritative snapshot.
                    failure = "Could not read the terminal connection: \(error.localizedDescription)"
                    return false
                }
            }) { }
            _ = enqueue(.finished(failure ?? errors.message))
        }
    }

    nonisolated private static func readAvailable(_ descriptor: Int32, buffer: inout [UInt8]) throws -> Data? {
        // Foundation read(upToCount:) fills the requested length on Darwin.
        // A socket handshake needs one POSIX read: return as soon as any bytes
        // arrive while retaining a large buffer for sustained terminal output.
        var count: Int
        repeat {
            count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        } while count < 0 && errno == EINTR
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard count > 0 else { return nil }
        return buffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) }
    }

    private func drain(_ mailbox: InboundMailbox, token: UUID) {
        guard generation == token, !stopped else { mailbox.cancel(); return }
        for event in mailbox.takeBatch() {
            guard generation == token, !stopped else { mailbox.cancel(); return }
            switch event {
            case .message(let message):
                if message.type == "hello" { reconnectBackoff.reset() }
                if message.type == "hello", mayUpgradeLocalHelper {
                    mayUpgradeLocalHelper = false
                    // The helper has started the daemon. Switch before exposing
                    // hello so watch, subscriptions and input use one transport.
                    // A request submitted early stays on its original relay.
                    if !hasSubmittedRequest, let socket = openLocalSocket() {
                        generation = UUID()
                        releaseTransport()
                        consumeSocket(socket, token: generation)
                        return
                    }
                }
                if let id = message.id, let callback = callbacks.removeValue(forKey: id) { callback(message) }
                guard generation == token, !stopped else { mailbox.cancel(); return }
                onMessage?(message)
            case .finished(let detail):
                retry(after: detail, token: token)
            }
        }
        if mailbox.finishDrain() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { mailbox.cancel(); return }
                self.drain(mailbox, token: token)
            }
        }
    }

    private func retry(after detail: String?, token: UUID) {
        guard !stopped, generation == token else { return }
        generation = UUID()
        let retryToken = generation
        releaseTransport()
        guard !stopped, generation == retryToken else { return }
        onStatus?(detail?.isEmpty == false ? detail : "Connection interrupted. Reconnecting…")
        guard !stopped, generation == retryToken else { return }
        let delay = reconnectBackoff.nextDelay()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(100))
            guard !Task.isCancelled, let self, !self.stopped, self.generation == retryToken else { return }
            self.reconnectTask = nil
            self.startConnection()
        }
    }

    private func installOutbox(token: UUID, socket: Bool) -> Bool {
        guard let input else { return false }
        do {
            outbox = try OutboundMailbox(input: input, socket: socket) { [weak self] detail in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, !self.stopped else { return }
                    self.onSendError?("The connection failed while sending. Some input may not have reached the terminal.")
                    self.retry(after: detail, token: token)
                }
            }
            return true
        } catch {
            retry(after: error.localizedDescription, token: token)
            return false
        }
    }

    @discardableResult
    func send(_ request: WireRequest, completion: ((WireMessage) -> Void)? = nil) -> Bool {
        func reject(_ detail: String) -> Bool {
            onSendError?(detail)
            completion?(WireMessage(id: request.id, type: "error", error: detail))
            return false
        }
        guard let outbox, !stopped else { return reject("The terminal is disconnected. The request was not sent.") }
        guard !request.id.isEmpty, callbacks[request.id] == nil else {
            return reject("The request identifier is missing or already awaiting a reply. The request was not sent.")
        }
        guard completion == nil || callbacks.count < Self.maximumCallbacks else {
            return reject("Too many terminal requests are waiting for replies. The request was not sent.")
        }
        do {
            var data = try JSONEncoder().encode(request); data.append(10)
            guard outbox.enqueue(data) else {
                return reject("The terminal connection is busy. The request was not sent; try again when it catches up.")
            }
            hasSubmittedRequest = true
            if let completion { callbacks[request.id] = completion }
            return true
        } catch { return reject(error.localizedDescription) }
    }

    func close() {
        stopped = true; generation = UUID()
        releaseTransport()
    }

    private func releaseTransport() {
        reconnectTask?.cancel(); reconnectTask = nil
        mailbox?.cancel(); mailbox = nil
        outbox?.cancel(); outbox = nil
        mayUpgradeLocalHelper = false; hasSubmittedRequest = false
        if usesSocket, let input { Darwin.shutdown(input.fileDescriptor, SHUT_RDWR) }
        usesSocket = false
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? input?.close(); input = nil
        // The background reader owns its close. Closing a pipe FileHandle
        // here can contend with its blocking read and stall the main actor.
        let abandoned = callbacks
        callbacks.removeAll()
        for (id, callback) in abandoned {
            callback(WireMessage(id: id, type: "error", error: "The connection closed before a reply arrived. The request was not retried."))
        }
    }

}

nonisolated struct ReconnectBackoff {
    private var next = 2.0

    mutating func reset() { next = 2 }

    mutating func nextDelay() -> Double {
        let delay = min(30, next * Double.random(in: 0.9...1.1))
        next = min(30, next * 2)
        return delay
    }
}


private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value); if data.count > 4000 { data = Data(data.suffix(4000)) } }
    var message: String? { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// One bounded mailbox owns one worker. A full socket/pipe waits on writability
// and a cancellation pipe, so no actor is blocked and no per-request closures
// accumulate behind a blocked FileHandle.write.
nonisolated private final class OutboundMailbox: @unchecked Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumItems = 1024
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "illogical.connection.write")
    private let socket: Bool
    private let failure: @Sendable (String) -> Void
    private var descriptor: Int32
    private var cancellation: [Int32]
    private var payloads: [Data] = []
    private var head = 0
    private var bytes = 0
    private var items = 0
    private var draining = false
    private var cancelled = false

    init(input: FileHandle, socket: Bool, failure: @escaping @Sendable (String) -> Void) throws {
        self.socket = socket; self.failure = failure
        descriptor = Darwin.dup(input.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        cancellation = [-1, -1]
        guard Darwin.pipe(&cancellation) == 0 else {
            Darwin.close(descriptor); throw POSIXError(.EMFILE)
        }
        _ = fcntl(cancellation[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        if !socket {
            let flags = fcntl(descriptor, F_GETFL)
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(descriptor); Darwin.close(cancellation[0]); Darwin.close(cancellation[1])
                throw error
            }
        }
    }

    var usage: (bytes: Int, items: Int) {
        lock.lock(); defer { lock.unlock() }
        return (bytes, items)
    }

    func enqueue(_ data: Data) -> Bool {
        lock.lock()
        guard !cancelled, items < Self.maximumItems, data.count <= Self.maximumBytes - bytes else {
            lock.unlock(); return false
        }
        payloads.append(data); bytes += data.count; items += 1
        let schedule = !draining
        draining = true
        lock.unlock()
        if schedule { worker.async { self.drain() } }
        return true
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        payloads.removeAll(); head = 0; bytes = 0; items = 0
        let schedule = !draining; draining = true
        // A single nonblocking byte wakes an in-flight poll. The worker owns
        // all descriptor closes, preventing descriptor reuse during a write.
        var byte: UInt8 = 1
        _ = Darwin.write(cancellation[1], &byte, 1)
        lock.unlock()
        if schedule { worker.async { self.drain() } }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private func drain() {
        while true {
            lock.lock()
            if cancelled {
                lock.unlock(); closeDescriptors(); return
            }
            if head == payloads.count {
                payloads.removeAll(keepingCapacity: true); head = 0
                draining = false; lock.unlock(); return
            }
            let data = payloads[head]
            payloads[head] = Data(); head += 1
            lock.unlock()
            do {
                guard try write(data) else { closeDescriptors(); return }
            } catch {
                let shouldReport = !isCancelled
                cancel()
                closeDescriptors()
                if shouldReport { failure("Could not write to the terminal connection: \(error.localizedDescription)") }
                return
            }
            lock.lock()
            if !cancelled { bytes -= data.count; items -= 1 }
            if head >= 512 && head >= payloads.count / 2 {
                payloads.removeFirst(head); head = 0
            }
            lock.unlock()
        }
    }

    private func write(_ data: Data) throws -> Bool {
        try data.withUnsafeBytes { storage in
            var offset = 0
            while offset < storage.count {
                if isCancelled { return false }
                let pointer = storage.baseAddress!.advanced(by: offset)
                let count = socket
                    ? Darwin.send(descriptor, pointer, storage.count - offset, MSG_DONTWAIT)
                    : Darwin.write(descriptor, pointer, storage.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var events = [pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                                  pollfd(fd: cancellation[0], events: Int16(POLLIN), revents: 0)]
                    var result: Int32
                    repeat { result = Darwin.poll(&events, nfds_t(events.count), -1) } while result < 0 && errno == EINTR
                    if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: count == 0 ? EPIPE : errno) ?? .EIO)
            }
            return true
        }
    }

    private func closeDescriptors() {
        // Invoked only on the serial worker, once cancellation or failure wins.
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        for index in cancellation.indices where cancellation[index] >= 0 {
            Darwin.close(cancellation[index]); cancellation[index] = -1
        }
    }
}
