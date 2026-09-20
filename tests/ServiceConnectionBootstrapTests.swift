import Foundation
import Darwin

@main
struct ServiceConnectionBootstrapTests {
    @MainActor
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        await check(environment["ILLOGICAL_CONNECTION_TEST_MODE"]!, path: environment["ILLOGICAL_SOCKET"]!)
    }

    @MainActor
    private static func check(_ mode: String, path: String) async {
        let log = path + ".log"
        defer {
            if let contents = try? String(contentsOfFile: log, encoding: .utf8),
               let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("daemon:") }),
               let pid = Int32(line.dropFirst("daemon:".count)) { kill(pid, SIGTERM) }
            unlink(path); unlink(log)
        }
        let connection = ServiceConnection(host: .local)
        var hellos: [String] = [], replies: [String] = [], statuses: [String] = []
        var earlyCallbacks = 0, watchCallbacks = 0
        connection.onStatus = { statuses.append($0 ?? "") }
        connection.onMessage = { message in
            if message.type == "hello" {
                hellos.append(message.client ?? "missing")
                connection.send(WireRequest(method: "watch")) { _ in watchCallbacks += 1 }
            } else if message.type == "state" { replies.append(message.client ?? "missing") }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        connection.connect()
        if mode == "early" {
            connection.send(WireRequest(method: "early")) { _ in earlyCallbacks += 1 }
        }
        let expectedReplies = mode == "early" ? 2 : 1
        while replies.count < expectedReplies && statuses.isEmpty && DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // A retired helper's EOF must neither surface nor schedule a reconnect.
        try? await Task.sleep(for: .milliseconds(100))
        connection.close()
        let contents = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let records = contents.split(separator: "\n").filter { !$0.hasPrefix("daemon:") }.map(String.init)
        let transport = mode == "handoff" ? "direct" : "helper"
        let expected = mode == "early" ? ["helper:early", "helper:watch"] : ["\(transport):watch"]
        guard hellos == [transport], replies == Array(repeating: transport, count: expectedReplies),
              statuses.isEmpty, records == expected, watchCallbacks == 1, earlyCallbacks == (mode == "early" ? 1 : 0) else {
            fputs("FAIL bootstrap \(mode): hellos=\(hellos), replies=\(replies), records=\(records), status=\(statuses), callbacks=\(earlyCallbacks)/\(watchCallbacks)\n", stderr)
            exit(1)
        }
        print("Actual ServiceConnection bootstrap \(mode): one hello, exact request/callback delivery, no stale EOF passed.")
    }
}
