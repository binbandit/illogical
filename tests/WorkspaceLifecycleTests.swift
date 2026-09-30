import AppKit

// What a window shows as panes, tabs and sessions come and go: Ghostty's
// focus rule after a close, the neighbouring tab, the window closing with
// its session, restoration, one session per window, and close confirmation.
@main
struct WorkspaceLifecycleTests {
    typealias F = Fixture

    static func main() {
        let domain = "dev.illogical.lifecycle-tests"
        Check.that(Bundle.main.bundleIdentifier == domain, "The test needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        closingPaneFocusesPreviousPane()
        closingTabSelectsNeighbour()
        endingSessionClosesItsWindow()
        emptyServiceStartsSession()
        windowIntents()
        oneSessionPerWindow()
        closeConfirmation()
        print("Workspace lifecycle: focus after close, neighbour tabs, session-end window close, restore/new-window intents, one session per window and close confirmation passed.")
    }

    static func connect(_ peer: ServicePeer, _ intent: WindowIntent = .reopen, onClose: (() -> Void)? = nil) -> WorkspaceModel {
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.onRequestClose = onClose
        model.start(intent)
        Check.eventually("The fixture workspace must connect") { model.states["local"] != nil }
        return model
    }

    static func closingPaneFocusesPreviousPane() {
        func state(_ revision: Int, _ root: String, blocks: [String]) -> String {
            F.state(revision, sessions: [F.session("s", [F.tab("t", root), F.tab("u", F.leaf("z"))])], blocks: blocks + ["z"])
        }
        let full = F.split("root", "vertical", F.split("top", "horizontal", F.leaf("a"), F.leaf("b")), F.leaf("c"))
        let peer = ServicePeer(name: "lifecycle-pane", state: state(1, full, blocks: ["a", "b", "c"]))
        let model = connect(peer)
        model.choose(deck: "t", session: "s", host: "local")
        var revision = 1
        func publish(_ root: String, _ blocks: [String]) {
            revision += 1
            let target = UInt64(revision)
            peer.publish(state(revision, root, blocks: blocks))
            Check.eventually("State \(target) must arrive") { model.states["local"]?.revision == target }
        }

        model.focus("c")
        publish(F.split("top", "horizontal", F.leaf("a"), F.leaf("b")), ["a", "b"])
        Check.that(model.focusedBlock == "b", "Closing the last pane focuses the previous one, got \(model.focusedBlock)")
        model.focus("a")
        publish(F.leaf("b"), ["b"])
        Check.that(model.focusedBlock == "b", "Closing the first pane focuses the next one, got \(model.focusedBlock)")

        // (a | (b / c)): the previous pane in reading order, not the sibling.
        publish(F.split("root", "horizontal", F.leaf("a"), F.split("right", "vertical", F.leaf("b"), F.leaf("c"))), ["a", "b", "c"])
        model.focus("b")
        publish(F.split("root", "horizontal", F.leaf("a"), F.leaf("c")), ["a", "c"])
        Check.that(model.focusedBlock == "a", "Ghostty's rule picks the previous pane, got \(model.focusedBlock)")

        // A pane that closes while its tab is in the background.
        model.focus("c")
        model.choose(deck: "u")
        publish(F.leaf("a"), ["a"])
        model.choose(deck: "t")
        Check.that(model.focusedBlock == "a", "A background tab remembers the pane that took over")
        model.close()
    }

    static func closingTabSelectsNeighbour() {
        let tabs = ["one", "two", "three"].map { F.tab($0, F.leaf("p-\($0)")) }
        let peer = ServicePeer(name: "lifecycle-tab", state: F.state(1, sessions: [F.session("s", tabs)], blocks: ["p-one", "p-two", "p-three"]))
        let model = connect(peer)
        model.choose(deck: "two", session: "s", host: "local")
        peer.publish(F.state(2, sessions: [F.session("s", [tabs[0], tabs[2]])], blocks: ["p-one", "p-three"]))
        Check.eventually("Closing a middle tab selects its right neighbour, got \(model.selectedDeck)") {
            model.selectedDeck == "three" && model.focusedBlock == "p-three"
        }
        peer.publish(F.state(3, sessions: [F.session("s", [tabs[0]])], blocks: ["p-one"]))
        Check.eventually("Closing the rightmost tab selects its left neighbour, got \(model.selectedDeck)") {
            model.selectedDeck == "one" && model.focusedBlock == "p-one"
        }
        model.close()
    }

    /// Hammering Command-W must never start closing another project, so a
    /// window closes with its session instead of switching.
    static func endingSessionClosesItsWindow() {
        let sessions = ["a", "b"].map { F.session($0, [F.tab("t-\($0)", F.leaf("p-\($0)"))]) }
        let peer = ServicePeer(name: "lifecycle-session", state: F.state(1, sessions: sessions, blocks: ["p-a", "p-b"]))
        let model = connect(peer)
        var closed = 0
        model.onRequestClose = { closed += 1 }
        model.choose(session: "a", host: "local")
        // A session may be published empty before the service removes it.
        peer.publish(F.state(2, sessions: [F.session("a", []), sessions[1]], blocks: ["p-b"]))
        Check.eventually("A session without tabs closes its window") { closed == 1 }
        Check.that(model.selectedSession.isEmpty, "The ended session is no longer shown")
        model.close()

        let other = connect(peer)
        closed = 0
        other.onRequestClose = { closed += 1 }
        Check.eventually("Reopening shows the remaining session") { other.selectedSession == "b" }
        peer.publish(F.state(3, sessions: [], blocks: []))
        Check.eventually("A removed session closes its window") { closed == 1 }
        Check.that(peer.requests("session.new").isEmpty, "Ending the last session must not start another")
        other.close()
    }

    static func emptyServiceStartsSession() {
        let peer = ServicePeer(name: "lifecycle-empty", state: F.state(1, sessions: [], blocks: []))
        let model = connect(peer)
        var closed = 0
        model.onRequestClose = { closed += 1 }
        Check.eventually("An empty service at launch gets a new session") { peer.requests("session.new").count == 1 }
        peer.publish(F.state(2, sessions: [F.session("s", [F.tab("t", F.leaf("p"))])], blocks: ["p"]))
        Check.eventually("The new session is shown") { model.selectedSession == "s" && model.focusedBlock == "p" }
        // A restarted service with nothing in it is a fresh start, not a close.
        peer.publish(F.state(3, sessions: [], blocks: []))
        Check.eventually("The ended session closes the window") { closed == 1 }
        closed = 0
        peer.disconnect()
        Check.eventually("The workspace reconnects", timeout: 8) { peer.connections == 2 && peer.requests("session.new").count == 2 }
        Check.that(closed == 0, "A service restart must not close the window")
        model.close()
    }

    static func windowIntents() {
        let sessions = ["a", "b"].map { name in
            F.session(name, [F.tab("t-\(name)1", F.leaf("p-\(name)1")), F.tab("t-\(name)2", F.leaf("p-\(name)2"))])
        }
        let peer = ServicePeer(name: "lifecycle-intent", state: F.state(1, sessions: sessions, blocks: ["p-a1", "p-a2", "p-b1", "p-b2"]))
        let restored = connect(peer, .restore(WindowSelection(host: "local", session: "b", tab: "t-b2")))
        Check.eventually("A restored window shows its stored session and tab") {
            restored.selectedSession == "b" && restored.selectedDeck == "t-b2" && restored.focusedBlock == "p-b2"
        }
        let duplicate = connect(peer, .restore(WindowSelection(host: "local", session: "b", tab: "t-b1")))
        Check.eventually("A second window restoring the same session takes an unattached one") { duplicate.selectedSession == "a" }

        var closed = 0
        let orphan = connect(peer, .restore(WindowSelection(host: "local", session: "gone", tab: ""))) { closed += 1 }
        Check.eventually("A restored window with nothing left to show closes when others exist") { closed == 1 }
        orphan.close()

        let fresh = connect(peer, .newSession(host: "local", parentBlock: "p-a1"))
        Check.eventually("Command-N asks for a new session in the parent pane's directory") {
            peer.requests("session.new").last?.block == "p-a1"
        }
        fresh.close()
        restored.close()
        duplicate.close()
    }

    static func oneSessionPerWindow() {
        let sessions = ["a", "b"].map { F.session($0, [F.tab("t-\($0)", F.leaf("p-\($0)"))]) }
        let peer = ServicePeer(name: "lifecycle-windows", state: F.state(1, sessions: sessions, blocks: ["p-a", "p-b"]))
        let first = connect(peer, .restore(WindowSelection(host: "local", session: "a", tab: "")))
        let second = connect(peer, .restore(WindowSelection(host: "local", session: "b", tab: "")))
        Check.eventually("Each window shows its own session") { first.selectedSession == "a" && second.selectedSession == "b" }
        Check.that(second.pickerSessions.map(\.key.session) == ["b", "a"], "The picker lists sessions most recent first")
        var activated = 0
        first.onRequestActivation = { activated += 1 }
        second.choose(session: "a", host: "local")
        Check.that(second.selectedSession == "b" && activated == 1, "Choosing a session shown elsewhere brings that window forward")
        second.choose(deck: "t-a", session: "a", host: "local")
        Check.that(second.selectedSession == "b" && activated == 2, "Choosing its tab does too")
        Check.that(second.otherWindow(showing: SessionKey(host: "local", session: "a")) === first, "The picker marks it as open elsewhere")
        Check.that(second.pickerSessions.map(\.key.session) == ["a", "b"], "Using a session in its window makes it most recent")
        first.close()
        second.close()
    }

    static func closeConfirmation() {
        let idle = #""pid":10,"foregroundPID":10,"user":"u","command":["zsh"],"cwd":"/","home":"/""#
        let busy = #""pid":20,"foregroundPID":21,"user":"u","command":["zsh"],"cwd":"/","home":"/","foreground":{"pid":21,"uid":501,"name":"nvim","executable":"/usr/bin/nvim"}"#
        let root = F.split("root", "horizontal", F.leaf("idle"), F.split("right", "vertical", F.leaf("busy"), F.leaf("slow")))
        let peer = ServicePeer(name: "lifecycle-close", state: F.state(1, sessions: [F.session("s", name: "work", [F.tab("t", root)])],
                                                                        blocks: ["idle", "busy", "slow"]))
        peer.respond { request in
            guard request.method == "block.process" else { return nil }
            switch request.block {
            case "busy": return [#"{"type":"reply","id":"\#(request.id)","process":{\#(busy)}}"#]
            case "slow": return []
            default: return [#"{"type":"reply","id":"\#(request.id)","process":{\#(idle)}}"#]
            }
        }
        let model = connect(peer)
        var prompts: [ClosePrompt] = []
        var answer: ((Bool) -> Void)?
        model.confirmClose = { prompt, reply in prompts.append(prompt);answer = reply }
        func kills() -> [String] { peer.requests("block.kill").compactMap(\.block) }

        model.closePane("idle")
        Check.eventually("An idle shell closes without asking") { kills() == ["idle"] }
        Check.that(prompts.isEmpty, "No confirmation for an idle shell")

        model.closePane("busy")
        Check.eventually("A running job asks first") { prompts.count == 1 }
        Check.that(prompts[0] == ClosePrompt(title: "Close Terminal?", message: "nvim is still running. Closing will end it."),
                   "The prompt names the job: \(prompts[0])")
        model.closePane("slow")
        Check.settle(0.3)
        Check.that(prompts.count == 1, "Only one confirmation per window at a time")
        let token = model.focusToken
        answer?(false)
        Check.settle()
        Check.that(kills() == ["idle"] && model.focusToken != token, "Cancel keeps the pane and returns focus to the terminal")

        model.closePane("busy")
        Check.eventually("The prompt returns") { prompts.count == 2 }
        answer?(true)
        Check.eventually("Close ends the pane") { kills() == ["idle", "busy"] }

        model.closePane("slow")
        Check.eventually("No answer within 150 ms still asks", timeout: 1) { prompts.count == 3 }
        Check.that(prompts[2].message == "A process may still be running. Closing will end it.", "Unknown state is stated honestly")
        answer?(false)

        model.closeSession("s", host: "local")
        Check.eventually("Closing a session always asks") { prompts.count == 4 }
        Check.that(prompts[3].title == "Close Session?" && prompts[3].message.hasPrefix("This ends every terminal in “work”."),
                   "The session prompt names the session: \(prompts[3])")
        answer?(false)

        model.palette = .commands
        model.closeFocusedPane()
        Check.that(model.palette == nil && prompts.count == 4, "Command-W with the palette open only closes the palette")
        model.close()
    }
}
