import Foundation
import Darwin

@main
struct ResourceConnectionRetryTests {
    @MainActor
    static func main() async {
        var backoff = ReconnectBackoff()
        for attempt in 0..<100 {
            let delay = backoff.nextDelay()
            let base = min(30.0, pow(2.0, Double(min(attempt + 1, 5))))
            precondition(delay >= base * 0.9 && delay <= min(30, base * 1.1))
        }
        backoff.reset()
        precondition((1.8...2.2).contains(backoff.nextDelay()))
        let path = "/tmp/ilg-resource-retry-\(getpid()).sock"
        let listener = path.withCString { il_resource_listen($0) }
        precondition(listener >= 0)
        defer { unlink(path) }
        setenv("ILLOGICAL_SOCKET", path, 1)
        DispatchQueue.global().async { il_resource_serve_retries(listener) }
        let connection = ServiceConnection(host: .local)
        var failures: [UInt64] = []
        var hellos = 0
        connection.onStatus = { _ in failures.append(DispatchTime.now().uptimeNanoseconds) }
        connection.onMessage = { if $0.type == "hello" { hellos += 1 } }
        connection.connect()
        let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
        while failures.count < 3 && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard failures.count >= 3 else { fail("did not observe three actual reconnects") }
        let secondDelay = Double(failures[2] - failures[1]) / 1e9
        guard (3.5...4.8).contains(secondDelay) else {
            connection.close()
            fail("offline retry did not back off: second delay \(secondDelay)s")
        }
        while failures.count < 4 && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard failures.count == 4, hellos == 1 else { fail("successful greeting did not reconnect") }
        let recoveredDelay = Double(failures[3] - failures[2]) / 1e9
        guard (1.7...2.6).contains(recoveredDelay) else { fail("greeting did not reset backoff: \(recoveredDelay)s") }
        let manualStart = DispatchTime.now().uptimeNanoseconds
        connection.connect()
        while failures.count < 5 && DispatchTime.now().uptimeNanoseconds - manualStart < 1_000_000_000 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        connection.close()
        guard failures.count == 5, Double(failures[4] - manualStart) / 1e9 < 0.5 else {
            fail("explicit connect was delayed by retry backoff")
        }
        try? await Task.sleep(for: .milliseconds(2300))
        guard failures.count == 5 else { fail("close did not cancel a pending reconnect") }
        print("Actual socket retries: exponential delay, hello reset, immediate manual connect and close cancellation passed.")
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr); exit(1)
    }
}
