import Foundation
import Darwin

/// Fails without trapping, so a failing test never opens the crash reporter.
nonisolated private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #fileID, line: UInt = #line) {
    guard !condition() else { return }
    FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
    exit(1)
}

nonisolated private final class PeerFixture: @unchecked Sendable {
    enum Mode { case stalledThenReply, readWithoutReply }
    let path: String
    private let listener: Int32
    private let mode: Mode
    private let lock = NSLock()
    private var stopping = false
    private var peers: [Int32] = []
    private var methods: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    init(mode: Mode) {
        self.mode = mode
        path = "/tmp/ilg-outbound-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        listener = path.withCString { il_test_listen($0) }
        expect(listener >= 0)
        DispatchQueue.global().async { self.acceptPeers() }
    }
    var received: [String] { lock.lock(); defer { lock.unlock() }; return methods }
    func stop() {
        lock.lock(); stopping = true; let active = peers; lock.unlock()
        for peer in active { shutdown(peer, SHUT_RDWR); gate.signal() }
        shutdown(listener, SHUT_RDWR); Darwin.close(listener); unlink(path)
    }
    func breakFirstConnection() {
        lock.lock(); let first = peers.first; lock.unlock()
        if let first { shutdown(first, SHUT_RDWR); gate.signal() }
    }
    private func acceptPeers() {
        var index = 0
        while true {
            let peer = accept(listener, nil, nil)
            if peer < 0 { return }
            lock.lock()
            if stopping { lock.unlock(); Darwin.close(peer); return }
            peers.append(peer); index += 1
            lock.unlock()
            let ordinal = index
            DispatchQueue.global().async { self.serve(peer, index: ordinal) }
        }
    }
    private struct Incoming: Decodable { let id: String; let method: String }
    private func serve(_ peer: Int32, index: Int) {
        defer {
            lock.lock(); peers.removeAll { $0 == peer }; lock.unlock()
            Darwin.close(peer)
        }
        var enabled: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        let hello = Data("{\"type\":\"hello\",\"client\":\"peer\(index)\"}\n".utf8)
        _ = hello.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        if mode == .stalledThenReply && index == 1 { gate.wait(); return }
        var framer = JSONLineFramer(maximumMessageSize: 16 * 1024 * 1024)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            let data = Data(buffer.prefix(count))
            guard let lines = try? framer.append(data) else { return }
            for line in lines {
                guard let request = try? JSONDecoder().decode(Incoming.self, from: line) else { continue }
                lock.lock(); methods.append(request.method); lock.unlock()
                if mode == .stalledThenReply {
                    let reply = Data("{\"type\":\"reply\",\"id\":\"\(request.id)\"}\n".utf8)
                    _ = reply.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
                }
            }
        }
    }
}

@main struct ServiceConnectionOutboundTests {
    @MainActor static func wait(_ detail: String, seconds: Double = 3, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        guard predicate() else { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    @MainActor static func main() async {
        await stalledPeer()
        await callbackLimit()
        await writerFailure()
        print("Actual stalled Unix peer: bounded bytes/items/callbacks, visible whole-request rejection, prompt cancellation, no stale writes after turnover, and write-failure reconnect passed.")
    }
    @MainActor static func stalledPeer() async {
        let fixture = PeerFixture(mode: .stalledThenReply)
        defer { fixture.stop() }
        setenv("ILLOGICAL_SOCKET", fixture.path, 1)
        let connection = ServiceConnection(host: .local)
        var hellos: [String] = [], failures = 0, completions = 0, duplicate = false
        var completed = Set<String>()
        connection.onMessage = { if $0.type == "hello" { hellos.append($0.client!) } }
        connection.onSendError = { _ in failures += 1 }
        connection.connect()
        await wait("first hello") { hellos == ["peer1"] }
        var accepted = 0
        for index in 0..<2048 {
            let request = WireRequest(method: "old-\(index)", data: Data(repeating: 65, count: 16 * 1024))
            if connection.send(request, completion: { reply in
                completions += 1
                if !completed.insert(reply.id!).inserted { duplicate = true }
                expect(reply.error != nil)
            }) { accepted += 1 }
            let usage = connection.outboundUsage
            expect(usage.bytes <= 8 * 1024 * 1024 && usage.items <= 1024 && usage.callbacks <= 1024)
        }
        expect(accepted > 0 && accepted < 2048 && failures == 2048 - accepted)
        expect(completions == 2048 - accepted)
        let start = DispatchTime.now().uptimeNanoseconds
        connection.connect()
        let cancellationMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        expect(cancellationMS < 100, "cancelling stalled writer blocked MainActor")
        expect(completions == 2048 && !duplicate)
        await wait("new generation hello") { hellos.count == 2 }
        var freshReply = false
        expect(connection.send(WireRequest(method: "fresh")) { freshReply = $0.error == nil })
        await wait("new generation request") { freshReply }
        expect(fixture.received == ["fresh"], "old queued requests leaked into a new transport")
        connection.close()
        print("  stalled peer: \(accepted) accepted, \(failures) explicitly rejected; cancel \(Int(cancellationMS))ms; callbacks exactly once.")
    }
    @MainActor static func callbackLimit() async {
        let fixture = PeerFixture(mode: .readWithoutReply)
        defer { fixture.stop() }
        setenv("ILLOGICAL_SOCKET", fixture.path, 1)
        let connection = ServiceConnection(host: .local)
        var hello = false, errors = 0, completions = 0
        connection.onMessage = { if $0.type == "hello" { hello = true } }
        connection.onSendError = { _ in errors += 1 }
        connection.connect(); await wait("callback fixture hello") { hello }
        let duplicate = WireRequest(id: "duplicate", method: "duplicate-check")
        var duplicateCompletion = 0
        expect(connection.send(duplicate) { _ in duplicateCompletion += 1 })
        expect(!connection.send(duplicate) { reply in expect(reply.error != nil); duplicateCompletion += 1 })
        expect(duplicateCompletion == 1)
        connection.close()
        expect(duplicateCompletion == 2)
        hello = false; errors = 0
        connection.connect(); await wait("callback fixture reconnect") { hello }

        for index in 0..<2048 {
            connection.send(WireRequest(method: "pending-\(index)")) { _ in completions += 1 }
            if index % 128 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        }
        expect(connection.outboundUsage.callbacks == 1024 && errors == 1024 && completions == 1024)
        connection.close()
        expect(completions == 2048 && connection.outboundUsage.callbacks == 0)
    }
    @MainActor static func writerFailure() async {
        let fixture = PeerFixture(mode: .stalledThenReply)
        defer { fixture.stop() }
        setenv("ILLOGICAL_SOCKET", fixture.path, 1)
        let connection = ServiceConnection(host: .local)
        var hellos = 0, statuses = 0, completions = 0
        connection.onMessage = { if $0.type == "hello" { hellos += 1 } }
        connection.onStatus = { _ in statuses += 1 }
        connection.connect(); await wait("failure fixture hello") { hellos == 1 }
        for _ in 0..<8 { connection.send(WireRequest(method: "uncertain", data: Data(repeating: 66, count: 512 * 1024))) { reply in expect(reply.error != nil); completions += 1 } }
        fixture.breakFirstConnection()
        await wait("failed writer cancelled callbacks") { statuses > 0 && completions == 8 }
        await wait("failed writer reconnect", seconds: 4) { hellos == 2 }
        var replied = false
        connection.send(WireRequest(method: "after-failure")) { replied = $0.error == nil }
        await wait("reconnected writer") { replied }
        expect(fixture.received == ["after-failure"], "uncertain input was replayed automatically")
        connection.close()
    }
}
