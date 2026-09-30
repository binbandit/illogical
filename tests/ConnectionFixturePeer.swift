import Foundation
import Darwin

/// A scripted stand-in for the illogical service. It accepts any number of
/// clients on a private socket, greets each with hello plus the current
/// state, records every request and answers with a plain reply unless the
/// test installs a responder. Published states and sent lines go to every
/// connected client.
nonisolated final class ServicePeer: @unchecked Sendable {
    struct Request: Decodable {
        let id: String
        let method: String
        let session: String?
        let window: String?
        let block: String?
        let target: String?
        let label: String?
        let cwd: String?
        let axis: String?
        let ratio: Double?
        let data: Data?
    }

    let path: String
    private let hello: String
    private let lock = NSLock()
    private var requests: [Request] = []
    private var peers: [Int32] = []
    private var stateJSON: String
    private var responder: (@Sendable (Request) -> [String]?)?
    private var accepted = 0

    var received: [Request] { lock.withLock { requests } }
    var connections: Int { lock.withLock { accepted } }

    /// `state` is the JSON object sent as the initial workspace state;
    /// `features` are the capabilities announced in hello.
    init(name: String, state: String, features: [String] = ["viewport"]) {
        path = "/tmp/ilg-\(name)-\(getpid()).sock"
        stateJSON = state
        hello = #"{"type":"hello","protocol":1,"engine":"ghostty-27e8b3fa85d9","features":[\#(features.map { "\"\($0)\"" }.joined(separator: ","))]}"#
        unlink(path)
        let listener = path.withCString { il_resource_listen($0) }
        guard listener >= 0 else { Self.fail("could not listen on \(path)") }
        Thread.detachNewThread { self.acceptLoop(listener) }
    }

    deinit { unlink(path) }

    /// Replaces the default reply for matching requests. Return nil to fall
    /// back to a plain reply, or an array of raw lines to send instead.
    func respond(_ responder: @escaping @Sendable (Request) -> [String]?) { lock.withLock { self.responder = responder } }

    func requests(_ method: String) -> [Request] { received.filter { $0.method == method } }

    /// Publishes a new workspace state and remembers it for reconnections.
    func publish(_ state: String) {
        lock.withLock { stateJSON = state }
        send(#"{"type":"state","state":"# + state + "}")
    }

    func send(_ line: String) {
        for descriptor in lock.withLock({ peers }) { write(line, to: descriptor) }
    }

    /// Drops every client connection, as a crashed or restarted service would.
    func disconnect() {
        let dropped = lock.withLock { () -> [Int32] in let value = peers; peers = []; return value }
        for descriptor in dropped { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    private func write(_ line: String, to descriptor: Int32) {
        let data = Data((line + "\n").utf8)
        // Writes from the test and the responder must not interleave.
        lock.withLock { _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            var enabled: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            let state = lock.withLock { () -> String in accepted += 1; return stateJSON }
            write(hello, to: descriptor)
            write(#"{"type":"state","state":"# + state + "}", to: descriptor)
            lock.withLock { peers.append(descriptor) }
            Thread.detachNewThread {
                self.serve(descriptor)
                self.lock.withLock { self.peers.removeAll { $0 == descriptor } }
                Darwin.close(descriptor)
            }
        }
    }

    private func serve(_ descriptor: Int32) {
        var framer = JSONLineFramer(maximumMessageSize: 1 << 20)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0, let lines = try? framer.append(Data(buffer.prefix(count))) else { return }
            for line in lines {
                guard let request = try? JSONDecoder().decode(Request.self, from: line) else { continue }
                let responder = lock.withLock { () -> (@Sendable (Request) -> [String]?)? in requests.append(request); return self.responder }
                for reply in responder?(request) ?? [#"{"type":"reply","id":"\#(request.id)"}"#] { write(reply, to: descriptor) }
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

/// Test assertions that exit instead of trapping, so a failure never opens
/// the macOS crash reporter.
@MainActor
enum Check {
    static func that(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { ServicePeer.fail(message()) }
    }

    /// Runs the main run loop until `predicate` holds, failing after `timeout`.
    static func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 3, _ predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        that(predicate(), message())
    }

    /// Lets queued main-thread work run without waiting for a condition.
    static func settle(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
}

/// Compact builders for workspace state JSON.
enum Fixture {
    static func leaf(_ block: String) -> String { #"{"id":"n-\#(block)","block":"\#(block)"}"# }

    static func split(_ id: String, _ axis: String, _ first: String, _ second: String, ratio: Double = 0.5) -> String {
        #"{"id":"\#(id)","axis":"\#(axis)","ratio":\#(ratio),"first":\#(first),"second":\#(second)}"#
    }

    static func tab(_ id: String, _ root: String, name: String = "", zoomed: String? = nil) -> String {
        let zoom = zoomed.map { #","zoomed":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","name":"\#(name)","root":\#(root)\#(zoom)}"#
    }

    static func session(_ id: String, name: String? = nil, _ tabs: [String]) -> String {
        #"{"id":"\#(id)","name":"\#(name ?? id)","windows":[\#(tabs.joined(separator: ","))]}"#
    }

    static func block(_ id: String, title: String = "zsh", cwd: String = "/tmp") -> String {
        #"{"id":"\#(id)","title":"\#(title)","cwd":"\#(cwd)","pid":1,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["zsh"]}"#
    }

    static func state(_ revision: Int, sessions: [String], blocks: [String]) -> String {
        #"{"revision":\#(revision),"sessions":[\#(sessions.joined(separator: ","))],"blocks":[\#(blocks.map { block($0) }.joined(separator: ","))],"clients":1}"#
    }
}
