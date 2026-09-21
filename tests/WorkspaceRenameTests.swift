import AppKit
import Darwin

nonisolated private final class RenamePeer: @unchecked Sendable {
    struct Request: Decodable {
        let id: String
        let method: String
        let session: String?
        let window: String?
        let label: String?
    }

    let path = "/tmp/ilg-rename-\(getpid()).sock"
    private let lock = NSLock()
    private var requests: [Request] = []
    private let finished = DispatchSemaphore(value: 0)

    init() {
        let listener = path.withCString { il_resource_listen($0) }
        precondition(listener >= 0)
        DispatchQueue.global().async { self.serve(listener) }
    }

    var received: [Request] { lock.lock();defer { lock.unlock() };return requests }

    func finish() async {
        let stopped = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.finished.wait(timeout: .now() + 3) == .success)
            }
        }
        unlink(path)
        precondition(stopped, "Closing the model must close the fixture socket")
    }

    private func serve(_ listener: Int32) {
        defer { finished.signal() }
        let peer = accept(listener, nil, nil)
        Darwin.close(listener)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var enabled: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        let initial = #"{"type":"hello","protocol":1,"engine":"ghostty-27e8b3fa85d9"}"# + "\n" +
            #"{"type":"state","state":{"revision":1,"sessions":[{"id":"s-a","name":"First","windows":[{"id":"w-a","name":"First tab","root":{"id":"r-a","block":"b-a"}}]},{"id":"s-b","name":"Second","windows":[{"id":"w-b","name":"Second tab","root":{"id":"r-b","block":"b-b"}}]}],"blocks":[],"clients":1}}"# + "\n"
        let hello = Data(initial.utf8)
        _ = hello.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        var framer = JSONLineFramer(maximumMessageSize: 1024 * 1024)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
            guard count > 0, let lines = try? framer.append(Data(buffer.prefix(count))) else { return }
            for line in lines {
                guard let request = try? JSONDecoder().decode(Request.self, from: line) else { continue }
                lock.lock();requests.append(request);lock.unlock()
                let reply = Data("{\"type\":\"reply\",\"id\":\"\(request.id)\"}\n".utf8)
                _ = reply.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
            }
        }
    }
}

@main
struct WorkspaceRenameTests {
    @MainActor
    static func wait(_ description: String, until predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(predicate(), description)
    }

    @MainActor
    static func main() async {
        let domain = "dev.illogical.rename-tests"
        precondition(Bundle.main.bundleIdentifier == domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let peer = RenamePeer()
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.start()
        await wait("Fixture workspace must connect") { model.states["local"]?.revision == 1 }

        model.rename(session: "s-b", host: "local")
        precondition(model.selectedSession == "s-a" && model.selectedDeck == "w-a", "Renaming an inactive session must leave the current terminal selected")
        precondition(model.showRename && model.renameValue == "Second")
        model.selectedHost = "other-host";model.selectedSession = "other-session";model.selectedDeck = "other-window"
        model.renameValue = "  Project Δ \n"
        model.finishRename()
        await wait("Session rename must reach its original host") { peer.received.contains { $0.method == "session.rename" } }
        let sessionRequest = peer.received.first { $0.method == "session.rename" }!
        precondition(sessionRequest.session == "s-b" && sessionRequest.window == nil && sessionRequest.label == "Project Δ", "Session rename must retain its captured target and trim only surrounding whitespace")
        precondition(model.selectedHost == "other-host" && model.selectedSession == "other-session", "Submitting a rename must not switch the active session")

        model.selectedHost = "local";model.selectedSession = "s-a";model.selectedDeck = "w-a"
        model.rename("window")
        model.selectedSession = "s-b";model.selectedDeck = "w-b"
        model.renameValue = "Build logs"
        model.finishRename()
        await wait("Tab rename must reach the service") { peer.received.contains { $0.method == "window.rename" } }
        let tabRequest = peer.received.first { $0.method == "window.rename" }!
        precondition(tabRequest.session == "s-a" && tabRequest.window == "w-a" && tabRequest.label == "Build logs", "Tab rename must retain the tab from when its sheet opened")

        model.rename(session: "s-b", host: "local")
        model.renameValue = " \n\t "
        precondition(!model.canRename)
        model.finishRename()
        precondition(model.showRename, "Blank names must keep the sheet open for correction")
        model.cancelRename()
        model.renameValue = "Stale submission"
        model.finishRename()
        precondition(!model.showRename)

        model.rename(session: "s-b", host: "local")
        model.states["local"]?.sessions.removeAll { $0.id == "s-b" }
        model.finishRename()
        precondition(model.notice == "This session is no longer available." && !model.showRename)
        var barrier = false
        model.send(WireRequest(method: "test.barrier"), host: "local") { _ in barrier = true }
        await wait("Invalid rename checks must drain the connection") { barrier }
        precondition(peer.received.filter { $0.method.hasSuffix(".rename") }.count == 2, "Blank, canceled and removed targets must never submit a rename")

        model.close()
        await peer.finish()
        print("Workspace rename: inactive-session selection preserved, host/session/tab targets captured across focus changes, Unicode names trimmed, and blank/canceled/removed targets rejected.")
    }
}
