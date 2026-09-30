import AppKit

// Keyboard navigation over tabs, sessions and panes (including zoom), the
// directory picker's stale-reply handling, pane teardown and shared hosts.
@main
struct WorkspaceNavigationTests {
    typealias F = Fixture

    static func main() {
        let domain = "dev.illogical.navigation-tests"
        Check.that(Bundle.main.bundleIdentifier == domain, "The test needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        sharedHosts()
        paneGeometry()
        zoomedNavigation()
        directoryPicker()
        paneTeardown()
        print("Workspace navigation: shared hosts, split geometry, zoom-aware focus, tab/session memory, directory replies and pane teardown passed.")
    }

    /// Two sessions; the first has a split tab (left | right) and a single tab.
    static func workspace(_ revision: Int, zoom: String? = nil, includeRight: Bool = true) -> String {
        let split = includeRight ? F.split("split", "horizontal", F.leaf("left"), F.leaf("right")) : F.leaf("left")
        let first = F.session("session", name: "Primary", [F.tab("split-tab", split, name: "Split", zoomed: zoom),
                                                            F.tab("other-tab", F.leaf("other"), name: "Other")])
        let second = F.session("second-session", name: "Second", [F.tab("second-tab", F.leaf("second"))])
        return F.state(revision, sessions: [first, second], blocks: (includeRight ? ["left", "right"] : ["left"]) + ["other", "second"])
    }

    static func connect(_ peer: ServicePeer) -> WorkspaceModel {
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.start()
        Check.eventually("The fixture workspace must connect") { model.states["local"] != nil && !model.focusedBlock.isEmpty }
        return model
    }

    /// Mutable fixture state shared with the peer's responder thread.
    nonisolated final class Zoom: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        var current: String? { lock.withLock { value } }
        func toggle(_ block: String?) { lock.withLock { value = value == block ? nil : block } }
        func set(_ block: String?) { lock.withLock { value = block } }
    }

    static func zoomedNavigation() {
        let zoom = Zoom("right")
        let peer = ServicePeer(name: "navigation", state: workspace(1, zoom: "right"))
        peer.respond { request in
            switch request.method {
            case "window.zoom": zoom.toggle(request.block);return nil
            case "block.kill": return [#"{"type":"error","id":"\#(request.id)","error":"Fixture close rejected"}"#]
            default: return nil
            }
        }
        let model = connect(peer)
        var revision = 1
        func publishZoom() {
            revision += 1
            let target = revision
            peer.publish(workspace(revision, zoom: zoom.current))
            Check.eventually("Zoom state \(target) must arrive") { model.activeDeck?.zoomed == zoom.current }
            Check.settle(0.02)
        }

        Check.that(model.focusedBlock == "right", "Launch must focus the pane the zoomed tab shows")
        model.choose(deck: "other-tab")
        model.choose(deck: "split-tab")
        model.find()
        model.closeFocusedPane()
        Check.eventually("Close Pane must target the visible zoomed pane") { peer.requests("block.kill").last?.block == "right" }
        Check.eventually("A rejected close must stay visible") { model.notice?.message == "Fixture close rejected" }
        Check.that(model.focusedBlock == "right" && model.searchFocusedBlock == "right", "A rejected close keeps focus and search")

        model.choose(session: "second-session", host: "local")
        model.choose(session: "session", host: "local")
        Check.that(model.selectedDeck == "split-tab" && model.focusedBlock == "right", "Returning to a session restores its zoomed pane")
        model.selectAdjacentTab(1)
        Check.that(model.selectedDeck == "other-tab", "Next tab")
        model.selectAdjacentTab(1)
        Check.that(model.selectedDeck == "split-tab" && model.focusedBlock == "right", "Next tab wraps and restores the zoomed pane")
        model.selectAdjacentTab(-1)
        Check.that(model.selectedDeck == "other-tab", "Previous tab wraps")
        model.selectTab(0)
        Check.that(model.selectedDeck == "split-tab", "Command-1")
        model.selectTab(8)
        Check.that(model.selectedDeck == "other-tab", "Command-9 selects the last tab even with fewer than nine")
        model.selectTab(7)
        model.selectTab(-1)
        Check.that(model.selectedDeck == "other-tab", "Missing numbered tabs do nothing")
        model.choose(session: "second-session", host: "local")
        model.selectAdjacentTab(1)
        model.selectAdjacentTab(-1)
        model.selectTab(8)
        Check.that(model.selectedSession == "second-session" && model.selectedDeck == "second-tab", "Tab commands stay in their session")

        model.choose(deck: "split-tab", session: "session", host: "local")
        model.focusAdjacentPane(.left)
        model.focusAdjacentPane(.left)
        Check.eventually("A zoomed move asks the service to move the zoom") { peer.requests("window.zoom").count == 1 }
        Check.settle()
        Check.that(model.focusedBlock == "right", "Focus stays on the visible pane until the service moves the zoom")
        Check.that(peer.requests("window.zoom").map(\.block) == ["left"], "Repeating the move at the edge must not toggle zoom off")
        publishZoom()
        Check.that(model.focusedBlock == "left", "The published zoom moves focus")

        model.focusAdjacentPane(.right)
        model.focusAdjacentPane(.left)
        Check.eventually("Rapid reverse moves follow the pending target in order") {
            peer.requests("window.zoom").suffix(2).map(\.block) == ["right", "left"]
        }
        publishZoom()
        Check.that(model.activeDeck?.zoomed == "left" && model.focusedBlock == "left", "Reverse moves land back on the left pane")

        model.focusAdjacentPane(.right)
        model.selectAdjacentTab(1)
        Check.eventually("The zoom request reaches the service") { peer.requests("window.zoom").count == 4 }
        revision += 1
        peer.publish(workspace(revision, zoom: zoom.current))
        Check.eventually("State arrives") { model.states["local"]?.sessions.first?.windows.first?.zoomed == zoom.current }
        Check.that(model.selectedDeck == "other-tab" && model.focusedBlock == "other", "A late zoom reply must not steal focus from the new tab")
        model.selectAdjacentTab(-1)
        Check.that(model.focusedBlock == "right", "The tab shows its zoomed pane again")

        zoom.set(nil)
        publishZoom()
        model.focus("left")
        model.choose(deck: "other-tab")
        model.choose(deck: "split-tab")
        Check.that(model.focusedBlock == "left", "Unzoomed tabs remember their focused pane")
        model.focus("right")
        model.choose(deck: "other-tab")
        model.choose(deck: "split-tab")
        Check.that(model.focusedBlock == "right", "Pane memory follows the latest focus")
        zoom.set("left")
        publishZoom()
        Check.that(model.focusedBlock == "left", "A zoom published by another client moves focus to the visible pane")
        model.close()
    }

    static func directoryPicker() {
        let peer = ServicePeer(name: "directory", state: workspace(1))
        // Listing replies are sent by the test to control their order.
        peer.respond { $0.method == "directory.list" ? [] : nil }
        let model = connect(peer)
        model.choose(deck: "split-tab", session: "session", host: "local")
        func request() -> ServicePeer.Request {
            let before = peer.requests("directory.list").count
            model.showDirectory()
            Check.eventually("A listing must be requested") { peer.requests("directory.list").count > before }
            return peer.requests("directory.list").last!
        }
        func reply(_ request: ServicePeer.Request, path: String) {
            peer.send(#"{"type":"reply","id":"\#(request.id)","path":"\#(path)","entries":[{"name":"child","path":"\#(path)/child"}]}"#)
        }
        func settle() {
            let marker = WireRequest(method: "test.barrier")
            var done = false
            model.send(marker, host: "local") { _ in done = true }
            Check.eventually("The connection must drain") { done }
        }

        let first = request()
        reply(first, path: "/fixture/alpha")
        Check.eventually("A listing fills the picker") { model.canOpenDirectory && model.directoryPath == "/fixture/alpha" }

        model.palette = nil
        model.choose(deck: "other-tab")
        let delayed = request()
        Check.that(model.directoryLoading && model.directoryPath.isEmpty && !model.canOpenDirectory, "A new listing starts empty")
        model.openDirectory()
        settle()
        Check.that(peer.requests("window.new").isEmpty, "Return while loading must not open a tab in a stale directory")
        reply(delayed, path: "/fixture/beta")
        Check.eventually("The listing arrives") { model.canOpenDirectory }
        model.openDirectory()
        Check.eventually("Opening creates a tab in the listed directory") { peer.requests("window.new").count == 1 }
        let opened = peer.requests("window.new")[0]
        Check.that(opened.session == "session" && opened.block == "other" && opened.cwd == "/fixture/beta" && model.palette == nil,
                   "The new tab inherits the listed directory and the picker closes")

        let stale = request()
        model.palette = nil
        model.choose(deck: "split-tab")
        let current = request()
        reply(current, path: "/fixture/current")
        reply(stale, path: "/fixture/stale")
        settle()
        Check.that(model.directoryPath == "/fixture/current" && model.canOpenDirectory, "A late reply from an earlier picker is ignored")

        model.loadDirectory("/fixture/denied")
        Check.eventually("A child listing is requested") { peer.requests("directory.list").last?.cwd == "/fixture/denied" }
        peer.send(#"{"type":"reply","id":"\#(peer.requests("directory.list").last!.id)","error":"Permission denied"}"#)
        Check.eventually("A listing error is shown") { model.directoryError == "Permission denied" }
        model.openDirectory()
        Check.that(!model.canOpenDirectory && model.directoryPath.isEmpty, "An errored listing cannot be opened")

        let hostChange = request()
        model.selectedHost = "another-host"
        reply(hostChange, path: "/fixture/wrong-host")
        settle()
        model.openDirectory()
        Check.that(model.palette == nil && !model.canOpenDirectory, "Changing host invalidates the picker")

        model.choose(deck: "split-tab", session: "session", host: "local")
        let focusChange = request()
        reply(focusChange, path: "/fixture/old-focus")
        Check.eventually("The listing arrives") { model.canOpenDirectory }
        model.focus(model.focusedBlock == "left" ? "right" : "left")
        model.openDirectory()
        Check.that(model.palette == nil && !model.canOpenDirectory, "Focusing another pane cancels the picker")

        let removed = request()
        model.states["local"]?.sessions.removeAll { $0.id == "session" }
        reply(removed, path: "/fixture/removed")
        settle()
        model.openDirectory()
        settle()
        Check.that(!model.canOpenDirectory && peer.requests("window.new").count == 1, "A deleted source rejects late results")
        model.close()
    }

    /// A closing pane's replica must stop sending input and resizes as soon
    /// as the kill is requested, recover if the kill is rejected, and stay
    /// silent after the service removes it.
    static func paneTeardown() {
        nonisolated final class Kills: @unchecked Sendable {
            let lock = NSLock()
            var hold = false
            var removed = false
        }
        let kills = Kills()
        let peer = ServicePeer(name: "teardown", state: workspace(1))
        peer.respond { request in
            let (hold, removed) = kills.lock.withLock { (kills.hold, kills.removed) }
            if removed && request.block == "right" && request.method != "block.kill" {
                return [#"{"type":"error","id":"\#(request.id)","error":"terminal block not found"}"#]
            }
            if request.method == "block.kill" && hold { return [] }
            return nil
        }
        let model = connect(peer)
        model.choose(deck: "split-tab", session: "session", host: "local")
        let right = model.engine(for: "right", host: "local")
        let left = model.engine(for: "left", host: "local")
        Data("\u{1b}[?1004h".utf8).withUnsafeBytes { il_terminal_feed(right.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        right.focusChanged(true)
        func requests(for block: String, after count: Int) -> [String] {
            peer.received.dropFirst(count).filter { $0.block == block }.map(\.method)
        }
        func drain() {
            var done = false
            model.send(WireRequest(method: "test.barrier"), host: "local") { _ in done = true }
            Check.eventually("The connection must drain") { done }
        }

        kills.lock.withLock { kills.hold = true }
        model.closePane("right")
        Check.eventually("The kill is requested after the job check") { peer.requests("block.kill").count == 1 }
        let heldAt = peer.received.count
        right.onResize?(81, 24, 8, 16)
        right.focusChanged(false)
        drain()
        Check.that(!requests(for: "right", after: heldAt).contains { ["block.resize", "block.write"].contains($0) },
                   "A closing pane must stop resizing and focus reports before the kill is acknowledged")

        peer.send(#"{"type":"error","id":"\#(peer.requests("block.kill")[0].id)","error":"Fixture close rejected"}"#)
        Check.eventually("A rejected close is shown") { model.notice?.message == "Fixture close rejected" }
        model.dismissNotice()
        let resumedAt = peer.received.count
        right.onResize?(82, 24, 8, 16)
        right.focusChanged(true)
        drain()
        let resumed = requests(for: "right", after: resumedAt)
        Check.that(resumed.contains("block.resize") && resumed.contains("block.write"), "A rejected close restores input and resizing")

        kills.lock.withLock { kills.removed = true }
        model.closePane("right")
        Check.eventually("The second kill is requested") { peer.requests("block.kill").count == 2 }
        peer.send(#"{"type":"event","event":"block_closed","block":"right","session":"session","window":"split-tab"}"#)
        peer.send(#"{"type":"reply","id":"\#(peer.requests("block.kill")[1].id)"}"#)
        drain()
        let closedAt = peer.received.count
        right.onResize?(82, 25, 8, 16)
        right.focusChanged(false)
        peer.publish(workspace(2, includeRight: false))
        Check.eventually("The removal is published") { model.activeDeck?.root.blocks == ["left"] }
        right.onResize?(83, 26, 8, 16)
        right.onInput?(Data("late input".utf8))
        // SwiftUI may evaluate an outgoing pane again after its replica is gone.
        weak var outgoing: TerminalEngine?
        do {
            let engine = model.engine(for: "right", host: "local")
            outgoing = engine
            engine.onResize?(84, 27, 8, 16)
            engine.onInput?(Data("outgoing input".utf8))
            engine.onReplayGap?()
        }
        model.focus("right")
        drain()
        let late = requests(for: "right", after: closedAt)
        Check.that(late.isEmpty, "A removed pane still sends \(late)")
        Check.that(model.notice == nil && left.onResize != nil && left.onInput != nil, "The sibling stays usable without an alert")
        Check.that(outgoing == nil && model.focusedBlock == "left", "Outgoing views keep no replica and cannot reclaim focus")
        model.close()
    }

    static func paneGeometry() {
        // (a / b) | ((c | d) / e), with live ratios.
        let json = F.split("root", "horizontal", F.split("left", "vertical", F.leaf("a"), F.leaf("b"), ratio: 0.25),
                           F.split("right", "vertical", F.split("top", "horizontal", F.leaf("c"), F.leaf("d"), ratio: 0.7), F.leaf("e"), ratio: 0.6),
                           ratio: 0.3)
        let layout = try! JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))
        let model = WorkspaceModel()
        let tabs = (0..<11).map { Deck(id: "tab-\($0)", name: "Tab \($0)", root: layout) }
        model.states["local"] = WorkspaceState(revision: 1, sessions: [Session(id: "geometry", name: "Geometry", windows: tabs)], blocks: [], clients: 1)
        model.choose(deck: "tab-0", session: "geometry", host: "local")
        func check(_ source: String, _ direction: PaneDirection, _ expected: String) {
            model.focus(source)
            model.focusAdjacentPane(direction)
            Check.that(model.focusedBlock == expected, "\(source) \(direction) should focus \(expected), got \(model.focusedBlock)")
        }
        check("a", .left, "a"); check("a", .up, "a"); check("a", .down, "b"); check("a", .right, "c")
        check("b", .right, "e"); check("c", .left, "b"); check("c", .right, "d")
        check("d", .down, "e"); check("d", .right, "d"); check("e", .up, "c"); check("e", .left, "b"); check("e", .down, "e")

        model.focus("e")
        model.cyclePane(1)
        Check.that(model.focusedBlock == "a", "Command-] wraps to the first pane")
        model.cyclePane(-1)
        Check.that(model.focusedBlock == "e", "Command-[ wraps to the last pane")

        model.selectTab(8)
        Check.that(model.selectedDeck == "tab-10", "Command-9 selects the final tab with more than nine")
        model.selectTab(7)
        Check.that(model.selectedDeck == "tab-7", "Command-8")
        let resized = try! JSONDecoder().decode(SplitLayout.self, from: Data(json.replacingOccurrences(of: #""ratio":0.6"#, with: #""ratio":0.9"#).utf8))
        model.states["local"]?.sessions[0].windows[7].root = resized
        check("b", .right, "c")

        // Equalize gives every pane an equal share along each axis.
        let equal = Dictionary(uniqueKeysWithValues: layout.equalizedRatios().map { ($0.split, $0.ratio) })
        Check.that(equal["root"] == 1.0 / 3.0 && equal["left"] == 0.5 && equal["top"] == 0.5 && equal["right"] == 0.5,
                   "Equalized ratios: \(equal)")
        // Resizing moves the nearest divider on the requested axis by cells.
        let sizes: [String: (Int, Int)] = ["a": (30, 10), "b": (30, 30), "c": (35, 24), "d": (15, 24), "e": (50, 16)]
        let right = layout.resized("d", toward: .right, cells: 10) { sizes[$0] }
        Check.that(right?.split == "top" && abs((right?.ratio ?? 0) - 0.9) < 0.0001, "Resize right moves the c|d divider: \(String(describing: right))")
        let down = layout.resized("a", toward: .down, cells: 10) { sizes[$0] }
        Check.that(down?.split == "left" && abs((down?.ratio ?? 0) - 0.5) < 0.0001, "Resize down moves the a/b divider: \(String(describing: down))")
        Check.that(layout.focusTarget(afterClosing: "c", surviving: ["a", "b", "d", "e"]) == "b", "Closing picks the previous pane")
        Check.that(layout.focusTarget(afterClosing: "a", surviving: ["b", "c", "d", "e"]) == "b", "Closing the first pane picks the next")
        model.close()
    }

    static func sharedHosts() {
        let store = HostProfileStore.shared
        let first = WorkspaceModel(), second = WorkspaceModel()
        store.add(name: "Build", address: "build.invalid", executable: "illogical")
        let build = first.hosts.first { $0.name == "Build" }!
        Check.that(second.hosts.contains(build), "A new host reaches every live window immediately")
        store.add(name: "Production", address: "production.invalid", executable: "illogical")
        Check.that(first.hosts == second.hosts && first.hosts.count == 3, "Both windows list both hosts")
        Check.that(store.add(name: "", address: "-oProxyCommand=evil", executable: "") != nil, "Option-like addresses are rejected")
        let saved = try! JSONDecoder().decode([HostProfile].self, from: UserDefaults.standard.data(forKey: "hosts")!)
        Check.that(saved.map(\.name) == ["Build", "Production"], "Both hosts persist")
        second.selectedHost = build.id
        second.selectedSession = "remote-session"
        second.selectedDeck = "remote-tab"
        store.remove(build.id)
        Check.that(!second.hosts.contains(build), "Removal reaches every window")
        Check.that(second.selectedHost == "local" && second.selectedSession.isEmpty && second.selectedDeck.isEmpty && second.focusedBlock.isEmpty,
                   "Removing the shown host clears that window's selection")
        weak var released: WorkspaceModel?
        do { let temporary = WorkspaceModel();released = temporary }
        Check.that(released == nil, "The host store must not retain closed windows")
        for host in store.hosts where !host.isLocal { store.remove(host.id) }
        Check.that(first.hosts == [.local] && second.hosts == [.local], "All remote hosts removed")
        first.close()
        second.close()
    }
}
