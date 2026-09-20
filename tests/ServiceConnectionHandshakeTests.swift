import Foundation
import Darwin

@main
struct ServiceConnectionHandshakeTests {
    @MainActor
    static func main() async {
        let path = "/tmp/ilg-handshake-\(getpid()).sock"
        let listener = path.withCString { il_test_listen($0) }
        precondition(listener >= 0)
        defer { unlink(path) }
        setenv("ILLOGICAL_SOCKET", path, 1)
        let peerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { il_test_serve_handshake(listener); peerFinished.signal() }
        let connection = ServiceConnection(host: .local)
        var messages: [String] = []
        connection.onMessage = { message in
            messages.append(message.type)
            if message.type == "hello" { connection.send(WireRequest(method: "watch")) }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        connection.connect()
        while messages.count < 2 && DispatchTime.now().uptimeNanoseconds - start < 1_500_000_000 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        connection.close()
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: peerFinished.wait(timeout: .now() + 2) == .success)
            }
        }
        guard messages == ["hello", "state"], finished else {
            fputs("FAIL: small socket handshake stalled with messages \(messages); peer finished: \(finished)\n", stderr)
            exit(1)
        }
        print("Actual ServiceConnection: small server-first hello/reply delivered in \(Int(milliseconds))ms before EOF; cancellation closed the idle socket.")
    }
}
