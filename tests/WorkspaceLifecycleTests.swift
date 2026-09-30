import AppKit

// Selection must follow the service when panes, tabs and sessions disappear:
// the sibling takes over a closed pane, a neighbour tab replaces a closed tab,
// the most recently used session replaces a closed session, and the window
// closes only when nothing is left.
@main
struct WorkspaceLifecycleTests {
    typealias F = Fixture

    static func main() {
        let domain = "dev.illogical.lifecycle-tests"
        Check.that(Bundle.main.bundleIdentifier == domain, "The test needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        closingPaneFocusesSibling()
        closingTabSelectsNeighbour()
        closingSessionSelectsMostRecent()
        closingEverythingClosesWindow()
        print("Workspace lifecycle: sibling focus after pane close, neighbour tab, most recent session and window close on empty passed.")
    }

    static func connect(_ peer: ServicePeer) -> WorkspaceModel {
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.start()
        Check.eventually("The fixture workspace must connect") { model.states["local"] != nil }
        return model
    }

    static func closingPaneFocusesSibling() {
        // ((a | b) / c) and a second tab.
        let full = F.split("root", "vertical", F.split("top", "horizontal", F.leaf("a"), F.leaf("b")), F.leaf("c"))
        func state(_ revision: Int, _ root: String, blocks: [String]) -> String {
            F.state(revision, sessions: [F.session("s", [F.tab("t", root), F.tab("u", F.leaf("z"))])], blocks: blocks + ["z"])
        }
        let peer = ServicePeer(name: "lifecycle-pane", state: state(1, full, blocks: ["a", "b", "c"]))
        let model = connect(peer)
        model.choose(deck: "t", session: "s", host: "local")

        model.focus("c")
        peer.publish(state(2, F.split("top", "horizontal", F.leaf("a"), F.leaf("b")), blocks: ["a", "b"]))
        Check.eventually("Closing the bottom pane must focus the nearest pane of its sibling, got \(model.focusedBlock)") {
            model.states["local"]?.revision == 2 && model.focusedBlock == "b"
        }

        model.focus("a")
        peer.publish(state(3, F.leaf("b"), blocks: ["b"]))
        Check.eventually("Closing a pane must focus the sibling that takes its space, got \(model.focusedBlock)") {
            model.states["local"]?.revision == 3 && model.focusedBlock == "b"
        }

        // A pane closed while its tab is in the background is replaced in
        // that tab's focus memory too.
        peer.publish(state(4, F.split("x", "horizontal", F.leaf("b"), F.leaf("d")), blocks: ["b", "d"]))
        Check.eventually("A split must arrive") { model.states["local"]?.revision == 4 }
        model.focus("d")
        model.choose(deck: "u")
        peer.publish(state(5, F.leaf("b"), blocks: ["b"]))
        Check.eventually("State must arrive") { model.states["local"]?.revision == 5 }
        model.choose(deck: "t")
        Check.that(model.focusedBlock == "b", "Returning to a tab whose focused pane closed must focus its sibling")
        model.close()
    }

    static func closingTabSelectsNeighbour() {
        let tabs = ["one", "two", "three"].map { F.tab($0, F.leaf("p-\($0)")) }
        let blocks = ["p-one", "p-two", "p-three"]
        let peer = ServicePeer(name: "lifecycle-tab", state: F.state(1, sessions: [F.session("s", tabs)], blocks: blocks))
        let model = connect(peer)
        model.choose(deck: "two", session: "s", host: "local")
        peer.publish(F.state(2, sessions: [F.session("s", [tabs[0], tabs[2]])], blocks: ["p-one", "p-three"]))
        Check.eventually("Closing a middle tab must select the tab that took its place, got \(model.selectedDeck)") {
            model.states["local"]?.revision == 2 && model.selectedDeck == "three" && model.focusedBlock == "p-three"
        }
        peer.publish(F.state(3, sessions: [F.session("s", [tabs[0]])], blocks: ["p-one"]))
        Check.eventually("Closing the last tab must select the new last tab, got \(model.selectedDeck)") {
            model.states["local"]?.revision == 3 && model.selectedDeck == "one" && model.focusedBlock == "p-one"
        }
        model.close()
    }

    static func closingSessionSelectsMostRecent() {
        let sessions = ["a", "b", "c"].map { F.session($0, [F.tab("t-\($0)", F.leaf("p-\($0)"))]) }
        let blocks = ["p-a", "p-b", "p-c"]
        let peer = ServicePeer(name: "lifecycle-session", state: F.state(1, sessions: sessions, blocks: blocks))
        let model = connect(peer)
        model.choose(session: "c", host: "local")
        model.choose(session: "b", host: "local")
        model.choose(session: "a", host: "local")
        // The service may briefly publish a session without tabs before it
        // removes it. Neither form may leave an empty session on screen.
        peer.publish(F.state(2, sessions: [F.session("a", []), sessions[1], sessions[2]], blocks: ["p-b", "p-c"]))
        Check.eventually("A session without tabs must be replaced by the most recent other session, got \(model.selectedSession)") {
            model.states["local"]?.revision == 2 && model.selectedSession == "b" && model.focusedBlock == "p-b"
        }
        model.choose(session: "c", host: "local")
        peer.publish(F.state(3, sessions: [sessions[1]], blocks: ["p-b"]))
        Check.eventually("A removed session must be replaced by the most recent remaining one, got \(model.selectedSession)") {
            model.states["local"]?.revision == 3 && model.selectedSession == "b" && model.selectedDeck == "t-b"
        }
        model.close()
    }

    static func closingEverythingClosesWindow() {
        let peer = ServicePeer(name: "lifecycle-empty", state: F.state(1, sessions: [], blocks: []))
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        var closeRequests = 0
        model.onRequestClose = { closeRequests += 1 }
        model.start()
        Check.eventually("An empty service at launch must get a new session instead of a closed window") {
            peer.requests("session.new").count == 1
        }
        Check.that(closeRequests == 0, "Launching into an empty service must not close the window")

        let only = F.session("s", [F.tab("t", F.leaf("p"))])
        peer.publish(F.state(2, sessions: [only], blocks: ["p"]))
        Check.eventually("The new session must be selected") { model.selectedSession == "s" && model.focusedBlock == "p" }
        peer.publish(F.state(3, sessions: [], blocks: []))
        Check.eventually("Closing the last terminal must close the window") { closeRequests == 1 }
        Check.that(peer.requests("session.new").count == 1, "Closing the last terminal must not respawn a session")

        // A restarted service with no sessions is a fresh launch, not a close.
        closeRequests = 0
        peer.disconnect()
        Check.eventually("The workspace must reconnect", timeout: 8) { peer.connections == 2 && peer.requests("session.new").count == 2 }
        Check.that(closeRequests == 0, "A service restart must not close the window")
        model.close()
    }
}
