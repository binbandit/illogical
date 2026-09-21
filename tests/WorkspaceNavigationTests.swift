import AppKit
import Darwin

nonisolated private final class NavigationPeer: @unchecked Sendable {
    struct Request: Decodable {
        let id: String
        let method: String
        let session: String?
        let window: String?
        let block: String?
        let target: String?
        let cwd: String?
    }

    let path = "/tmp/ilg-navigation-\(getpid()).sock"
    private let lock = NSLock()
    private var requests: [Request] = []
    private let finished = DispatchSemaphore(value: 0)
    var received: [Request] { lock.lock();defer { lock.unlock() };return requests }

    init() {
        let listener = path.withCString { il_resource_listen($0) }
        precondition(listener >= 0)
        DispatchQueue.global().async { self.serve(listener) }
    }

    func finish() async {
        let stopped = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.finished.wait(timeout: .now() + 3) == .success) }
        }
        unlink(path)
        precondition(stopped, "Closing the workspace must close its socket")
    }

    private func serve(_ listener: Int32) {
        defer { finished.signal() }
        let peer = accept(listener, nil, nil)
        Darwin.close(listener)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var enabled: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        func send(_ text: String) {
            let data = Data((text + "\n").utf8)
            _ = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        }
        func state(zoom: String?, revision: Int) {
            let zoomField = zoom.map { ",\"zoomed\":\"\($0)\"" } ?? ""
            send("""
            {"type":"state","state":{"revision":\(revision),"sessions":[{"id":"session","name":"Primary","windows":[{"id":"split-tab","name":"Split"\(zoomField),"root":{"id":"split","axis":"horizontal","ratio":0.5,"first":{"id":"left-root","block":"left"},"second":{"id":"right-root","block":"right"}}},{"id":"other-tab","name":"Other","root":{"id":"other-root","block":"other"}}]},{"id":"second-session","name":"Second","windows":[{"id":"second-tab","name":"Second","root":{"id":"second-root","block":"second"}}]}],"blocks":[{"id":"left","title":"sh","cwd":"/fixture/alpha","pid":1,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["sh"]},{"id":"right","title":"sh","cwd":"/fixture/alpha","pid":2,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["sh"]},{"id":"other","title":"sh","cwd":"/fixture/beta","pid":3,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["sh"]},{"id":"second","title":"sh","cwd":"/fixture/second","pid":4,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["sh"]}],"clients":1}}
            """)
        }
        send(#"{"type":"hello","protocol":1,"engine":"ghostty-27e8b3fa85d9"}"#)
        var revision = 1
        var rightRemoved = false
        var holdClose = false
        var pendingClose: String?
        var zoom: String? = "right"
        state(zoom: zoom, revision: revision)
        var framer = JSONLineFramer(maximumMessageSize: 1024 * 1024)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
            guard count > 0, let lines = try? framer.append(Data(buffer.prefix(count))) else { return }
            for line in lines {
                guard let request = try? JSONDecoder().decode(Request.self, from: line) else { continue }
                lock.lock();requests.append(request);lock.unlock()
                if rightRemoved && request.block == "right" && ["block.resize", "block.write", "block.process", "block.attach", "block.theme", "block.claim"].contains(request.method) {
                    send("{\"type\":\"error\",\"id\":\"\(request.id)\",\"error\":\"terminal block not found\"}")
                    continue
                }
                switch request.method {
                case "block.kill":
                    if holdClose { pendingClose = request.id;continue }
                    send("{\"type\":\"error\",\"id\":\"\(request.id)\",\"error\":\"Fixture close rejected\"}")
                    continue
                case "test.hold-close": holdClose = true
                case "test.reject-close":
                    send("{\"type\":\"error\",\"id\":\"\(pendingClose!)\",\"error\":\"Fixture close rejected\"}")
                    pendingClose = nil
                case "directory.list": continue // Tests control reply ordering and errors.
                case "test.directory-success":
                    send("{\"type\":\"reply\",\"id\":\"\(request.target!)\",\"path\":\"\(request.cwd!)\",\"entries\":[{\"name\":\"child\",\"path\":\"\(request.cwd!)/child\"}]}")
                case "test.directory-error":
                    send("{\"type\":\"reply\",\"id\":\"\(request.target!)\",\"error\":\"Permission denied\"}")
                case "test.zoom":
                    zoom = request.block;revision += 1;state(zoom: zoom, revision: revision)
                case "window.zoom":
                    zoom = zoom == request.block ? nil : request.block
                case "test.publish-zoom":
                    revision += 1;state(zoom: zoom, revision: revision)
                case "test.drop-right":
                    rightRemoved = true
                    send(#"{"type":"event","event":"block_closed","block":"right","session":"session","window":"split-tab"}"#)
                    if let pendingClose { send("{\"type\":\"reply\",\"id\":\"\(pendingClose)\"}") }
                    pendingClose = nil
                case "test.publish-removal":
                    send(#"{"type":"state","state":{"revision":999,"sessions":[{"id":"session","name":"Primary","windows":[{"id":"split-tab","name":"Split","root":{"id":"left-root","block":"left"}}]}],"blocks":[{"id":"left","title":"sh","cwd":"/fixture/alpha","pid":1,"cols":80,"rows":24,"parked":false,"keepOpen":true,"command":["sh"]}],"clients":1}}"#)
                default: break
                }
                send("{\"type\":\"reply\",\"id\":\"\(request.id)\"}")
            }
        }
    }
}

@main
struct WorkspaceNavigationTests {
    @MainActor
    static func wait(_ description: String, until predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(predicate(), description)
    }

    @MainActor
    static func main() async {
        let domain = "dev.illogical.navigation-tests"
        precondition(Bundle.main.bundleIdentifier == domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        await sharedHosts()
        paneGeometry()
        let peer = NavigationPeer()
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.start()
        await wait("Fixture workspace must connect") { model.states["local"]?.revision == 1 }

        func exchange(_ request: WireRequest) async {
            var replied = false
            model.send(request, host: "local") { _ in replied = true }
            await wait("Fixture request must finish") { replied }
        }
        func directories() -> [NavigationPeer.Request] { peer.received.filter { $0.method == "directory.list" } }
        func requestDirectory() async -> NavigationPeer.Request {
            let before = directories().count
            model.showDirectory()
            await wait("Directory listing must be requested") { directories().count > before }
            return directories().last!
        }
        func completeDirectory(_ request: NavigationPeer.Request, path: String) async {
            await exchange(WireRequest(method: "test.directory-success", target: request.id, cwd: path))
        }

        precondition(model.focusedBlock == "right", "Initial selection must focus the pane the zoomed tab displays")
        model.choose(deck: "other-tab");model.choose(deck: "split-tab")
        model.find();model.closeBlock()
        await exchange(WireRequest(method: "test.barrier"))
        precondition(model.focusedBlock == "right" && model.searchFocusedBlock == "right")
        precondition(peer.received.last { $0.method == "block.kill" }?.block == "right", "Close Pane must never target the hidden first pane")
        model.choose(session: "second-session", host: "local");model.choose(session: "session", host: "local")
        precondition(model.selectedDeck == "split-tab" && model.focusedBlock == "right", "Session return must preserve the zoomed pane")
        model.selectAdjacentTab(1)
        precondition(model.selectedDeck == "other-tab")
        model.selectAdjacentTab(1)
        precondition(model.selectedDeck == "split-tab" && model.focusedBlock == "right", "Next tab must wrap and restore visible zoomed focus")
        model.selectAdjacentTab(-1)
        precondition(model.selectedDeck == "other-tab", "Previous tab must wrap")
        model.selectTab(0)
        precondition(model.selectedDeck == "split-tab")
        model.selectTab(8)
        precondition(model.selectedDeck == "other-tab", "Command-9 must select the last tab even with fewer than nine")
        model.selectTab(7);model.selectTab(-1)
        precondition(model.selectedDeck == "other-tab", "Unavailable numbered tabs must do nothing")
        model.choose(session: "second-session", host: "local")
        model.selectAdjacentTab(1);model.selectAdjacentTab(-1);model.selectTab(8)
        precondition(model.selectedSession == "second-session" && model.selectedDeck == "second-tab", "Tab commands must remain in their current session")
        model.choose(deck: "split-tab", session: "session", host: "local")
        model.focusAdjacentPane(.left);model.focusAdjacentPane(.left)
        await exchange(WireRequest(method: "test.barrier"))
        precondition(model.focusedBlock == "right", "Zoomed focus must remain visible until the service publishes the requested zoom")
        var zoomRequests = peer.received.filter { $0.method == "window.zoom" }
        precondition(zoomRequests.count == 1 && zoomRequests[0].block == "left", "Repeated movement at the pending destination's edge must not toggle zoom off")
        await exchange(WireRequest(method: "test.publish-zoom"))
        precondition(model.activeDeck?.zoomed == "left" && model.focusedBlock == "left")
        model.focusAdjacentPane(.right);model.focusAdjacentPane(.left)
        await exchange(WireRequest(method: "test.barrier"))
        zoomRequests = peer.received.filter { $0.method == "window.zoom" }
        precondition(zoomRequests.suffix(2).map(\.block) == ["right", "left"], "Rapid reverse navigation must follow pending intent in order")
        await exchange(WireRequest(method: "test.publish-zoom"))
        precondition(model.activeDeck?.zoomed == "left" && model.focusedBlock == "left")
        model.focusAdjacentPane(.right);model.selectAdjacentTab(1)
        await exchange(WireRequest(method: "test.barrier"))
        await exchange(WireRequest(method: "test.publish-zoom"))
        precondition(model.selectedDeck == "other-tab" && model.focusedBlock == "other", "A delayed zoom response must not steal focus from the new tab")
        model.selectAdjacentTab(-1)
        precondition(model.activeDeck?.zoomed == "right" && model.focusedBlock == "right")
        await exchange(WireRequest(method: "test.zoom"))
        model.focus("left");model.choose(deck: "other-tab");model.choose(deck: "split-tab")
        precondition(model.focusedBlock == "left", "Unzoomed tabs must retain their last focused pane")
        model.focus("right");model.choose(deck: "other-tab");model.choose(deck: "split-tab")
        precondition(model.focusedBlock == "right", "Focus memory must update after clicking a different pane")
        await exchange(WireRequest(method: "test.zoom", block: "left"))
        precondition(model.focusedBlock == "left", "A zoom state update must move command focus to the visible pane")
        await exchange(WireRequest(method: "test.zoom"))

        let first = await requestDirectory()
        await completeDirectory(first, path: "/fixture/alpha")
        precondition(model.canOpenDirectory && model.directoryPath == "/fixture/alpha")
        model.palette = nil;model.choose(deck: "other-tab")
        let delayed = await requestDirectory()
        precondition(model.directoryLoading && model.directoryPath.isEmpty && model.directories.isEmpty && !model.canOpenDirectory)
        model.openDirectory()
        await exchange(WireRequest(method: "test.barrier"))
        precondition(!peer.received.contains { $0.method == "window.new" }, "Enter while loading must not create a terminal with stale cwd")
        await completeDirectory(delayed, path: "/fixture/beta")
        model.openDirectory()
        await exchange(WireRequest(method: "test.barrier"))
        let opened = peer.received.filter { $0.method == "window.new" }
        precondition(opened.count == 1 && opened[0].session == "session" && opened[0].block == "other" && opened[0].cwd == "/fixture/beta")
        precondition(model.palette == nil)

        let stale = await requestDirectory()
        model.palette = nil;model.choose(deck: "split-tab")
        let current = await requestDirectory()
        await completeDirectory(current, path: "/fixture/current")
        await completeDirectory(stale, path: "/fixture/stale")
        precondition(model.directoryPath == "/fixture/current" && model.canOpenDirectory, "Late replies from a previous picker must not replace current results")
        model.loadDirectory("/fixture/denied")
        await wait("Child directory request must be sent") { directories().last?.cwd == "/fixture/denied" }
        await exchange(WireRequest(method: "test.directory-error", target: directories().last!.id))
        model.openDirectory()
        precondition(!model.directoryLoading && !model.canOpenDirectory && model.directoryPath.isEmpty && model.directoryError == "Permission denied")

        let changedHost = await requestDirectory()
        model.selectedHost = "another-host"
        await completeDirectory(changedHost, path: "/fixture/wrong-host")
        model.openDirectory()
        precondition(model.palette == nil && model.directoryPath.isEmpty && !model.canOpenDirectory, "A host change must invalidate both results and actions")
        model.choose(deck: "split-tab", session: "session", host: "local")
        let changedFocus = await requestDirectory()
        await completeDirectory(changedFocus, path: "/fixture/old-focus")
        model.focus("right")
        model.openDirectory()
        precondition(model.palette == nil && !model.canOpenDirectory, "Changing the source pane must cancel the directory action")

        let removed = await requestDirectory()
        model.states["local"]?.sessions.removeAll { $0.id == "session" }
        await completeDirectory(removed, path: "/fixture/removed")
        model.openDirectory()
        await exchange(WireRequest(method: "test.barrier"))
        precondition(!model.canOpenDirectory && model.directoryPath.isEmpty, "Deleted source context must reject a late result")
        precondition(peer.received.filter { $0.method == "window.new" }.count == 1)
        // SwiftUI can retain the native view after the model removes its engine.
        model.notice = nil
        let removedEngine = model.engine(for: "right", host: "local")
        let retainedEngine = model.engine(for: "left", host: "local")
        Data("\u{1b}[?1004h".utf8).withUnsafeBytes {
            il_terminal_feed(removedEngine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        removedEngine.focusChanged(true)
        await exchange(WireRequest(method: "test.hold-close"))
        model.closeBlock("right")
        let preAckCount = peer.received.count
        removedEngine.onResize?(81, 24, 8, 16)
        removedEngine.focusChanged(false)
        await exchange(WireRequest(method: "test.barrier"))
        precondition(!peer.received.dropFirst(preAckCount).contains { $0.block == "right" && ["block.resize", "block.write"].contains($0.method) },
                     "Closing panes must stop layout and focus input before the kill acknowledgment")
        await exchange(WireRequest(method: "test.reject-close"))
        precondition(model.notice == "Fixture close rejected", "A real close failure must remain visible")
        model.notice = nil
        let resumedCount = peer.received.count
        removedEngine.onResize?(82, 24, 8, 16)
        removedEngine.focusChanged(true)
        await exchange(WireRequest(method: "test.barrier"))
        let resumed = peer.received.dropFirst(resumedCount).filter { $0.block == "right" }.map(\.method)
        precondition(resumed.contains("block.resize") && resumed.contains("block.write"), "A rejected close must restore pane input and resizing")
        model.closeBlock("right")
        await exchange(WireRequest(method: "test.drop-right"))
        let requestCount = peer.received.count
        removedEngine.onResize?(82, 25, 8, 16)
        removedEngine.focusChanged(false)
        await exchange(WireRequest(method: "test.barrier"))
        await exchange(WireRequest(method: "test.publish-removal"))
        await wait("Removed-pane state must arrive") { model.states["local"]?.revision == 999 }
        removedEngine.onResize?(83, 26, 8, 16)
        removedEngine.onInput?(Data("late input".utf8))
        // SwiftUI may evaluate an outgoing TerminalPane again after its cached
        // engine has been removed, before dismantling the old native view.
        weak var outgoingEngine: TerminalEngine?
        do {
            let outgoing = model.engine(for: "right", host: "local")
            outgoingEngine = outgoing
            outgoing.onResize?(84, 27, 8, 16)
            outgoing.onInput?(Data("outgoing view input".utf8))
            outgoing.onReplayGap?()
        }
        model.focus("right")
        await exchange(WireRequest(method: "test.barrier"))
        let lateRequests = peer.received.dropFirst(requestCount).filter { $0.block == "right" }
        precondition(lateRequests.isEmpty, "Removed native views still send stale requests: \(lateRequests.map(\.method))")
        precondition(model.notice == nil && retainedEngine.onResize != nil && retainedEngine.onInput != nil,
                     "Closing one pane must leave its sibling usable without a missing-terminal alert")
        precondition(outgoingEngine == nil && model.focusedBlock == "left", "Outgoing views must not retain a deleted replica or reclaim terminal focus")
        model.close();await peer.finish()
        print("Workspace navigation: zoomed visible-pane commands, per-tab/session focus restoration, delayed/error/reordered directory replies and deleted contexts passed.")
        print("Pane teardown: retained native-engine resize and focus-loss callbacks stop at block-close before coalesced state, and sibling callbacks remain connected.")
    }

    @MainActor
    static func paneGeometry() {
        let json = #"{"id":"root","axis":"horizontal","ratio":0.3,"first":{"id":"left","axis":"vertical","ratio":0.25,"first":{"id":"a","block":"a"},"second":{"id":"b","block":"b"}},"second":{"id":"right","axis":"vertical","ratio":0.6,"first":{"id":"top","axis":"horizontal","ratio":0.7,"first":{"id":"c","block":"c"},"second":{"id":"d","block":"d"}},"second":{"id":"e","block":"e"}}}"#
        let layout = try! JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))
        let model = WorkspaceModel()
        let tabs = (0..<11).map { Deck(id: "tab-\($0)", name: "Tab \($0)", root: layout) }
        model.states["local"] = WorkspaceState(revision: 1, sessions: [Session(id: "geometry", name: "Geometry", windows: tabs)], blocks: [], clients: 1)
        model.choose(deck: "tab-0", session: "geometry", host: "local")
        func check(_ source: String, _ direction: PaneDirection, _ expected: String) {
            model.focus(source);model.focusAdjacentPane(direction)
            precondition(model.focusedBlock == expected, "Directional geometry failed: \(source) \(direction) should focus \(expected), got \(model.focusedBlock)")
        }
        check("a", .left, "a");check("a", .up, "a");check("a", .down, "b");check("a", .right, "c")
        check("b", .right, "e");check("c", .left, "b");check("c", .right, "d")
        check("d", .down, "e");check("d", .right, "d");check("e", .up, "c");check("e", .left, "b");check("e", .down, "e")
        model.selectTab(8)
        precondition(model.selectedDeck == "tab-10", "Command-9 must select the final tab with more than nine tabs")
        model.selectTab(7)
        precondition(model.selectedDeck == "tab-7")
        let resized = try! JSONDecoder().decode(SplitLayout.self, from: Data(json.replacingOccurrences(of: "\"ratio\":0.6", with: "\"ratio\":0.9").utf8))
        model.states["local"]?.sessions[0].windows[7].root = resized
        check("b", .right, "c")
        model.close()
        print("Keyboard navigation: nested split geometry, center-line alignment, live ratios, edge no-ops, session-local tab cycling and numbered/last-tab selection passed.")
    }

    @MainActor
    static func sharedHosts() async {
        let first = WorkspaceModel(), second = WorkspaceModel()
        first.addHost(name: "Build", address: "build.invalid", executable: "illogical")
        let build = first.hosts.first { $0.name == "Build" }!
        precondition(second.hosts.contains(build), "Adding a host must synchronously reach other live windows")
        second.addHost(name: "Production", address: "production.invalid", executable: "illogical")
        let production = second.hosts.first { $0.name == "Production" }!
        precondition(first.hosts == second.hosts && first.hosts.count == 3)
        let saved = try! JSONDecoder().decode([HostProfile].self, from: UserDefaults.standard.data(forKey: "hosts")!)
        precondition(saved == [build, production], "A second window must not overwrite the first window's host")
        let reopened = WorkspaceModel()
        precondition(reopened.hosts == first.hosts)
        second.selectedHost = build.id;second.selectedSession = "remote-session";second.selectedDeck = "remote-tab";second.focusedBlock = "remote-block"
        first.removeHost(build)
        precondition(!second.hosts.contains(build) && !reopened.hosts.contains(build))
        precondition(second.selectedHost == "local" && second.selectedSession.isEmpty && second.selectedDeck.isEmpty && second.focusedBlock.isEmpty, "Removing a selected host must clear stale remote selection in every window")
        second.addHost(name: "Staging", address: "staging.invalid", executable: "illogical")
        precondition(!first.hosts.contains(build), "A later mutation from another window must not resurrect removed hosts")
        weak var released: WorkspaceModel?
        do { let temporary = WorkspaceModel();released = temporary }
        precondition(released == nil, "The shared store must not retain closed window models")
        for host in first.hosts where !host.isLocal { first.removeHost(host) }
        precondition(first.hosts == [.local] && second.hosts == [.local] && reopened.hosts == [.local])
        first.close();second.close();reopened.close()
        print("Shared hosts: two live windows retain concurrent additions/removals, persistence stays complete, selected removed hosts reset, and subscriptions do not retain models.")
    }
}
