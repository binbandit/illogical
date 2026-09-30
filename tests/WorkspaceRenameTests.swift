import AppKit

// Renames apply to the session or tab captured when the sheet opened, trim
// surrounding whitespace, and never submit blank, cancelled or stale targets.
@main
struct WorkspaceRenameTests {
    typealias F = Fixture

    static func main() {
        let domain = "dev.illogical.rename-tests"
        Check.that(Bundle.main.bundleIdentifier == domain, "The test needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let sessions = [F.session("s-a", name: "First", [F.tab("w-a", F.leaf("b-a"), name: "First tab")]),
                        F.session("s-b", name: "Second", [F.tab("w-b", F.leaf("b-b"), name: "Second tab")])]
        let peer = ServicePeer(name: "rename", state: F.state(1, sessions: sessions, blocks: ["b-a", "b-b"]))
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let model = WorkspaceModel()
        model.start()
        Check.eventually("The fixture workspace must connect") { model.selectedSession == "s-a" }

        model.beginRenameSession("s-b", host: "local")
        Check.that(model.selectedSession == "s-a" && model.selectedDeck == "w-a", "Renaming another session keeps the current one shown")
        Check.that(model.rename?.name == "Second" && model.rename?.title == "Rename Session", "The sheet starts with the current name")
        model.choose(session: "s-b", host: "local")
        model.commitRename("  Project Δ \n")
        Check.eventually("The session rename reaches the service") { !peer.requests("session.rename").isEmpty }
        let sessionRename = peer.requests("session.rename")[0]
        Check.that(sessionRename.session == "s-b" && sessionRename.window == nil && sessionRename.label == "Project Δ",
                   "The captured session is renamed with surrounding whitespace trimmed")
        Check.that(model.rename == nil, "Committing closes the sheet")

        model.choose(session: "s-a", host: "local")
        model.beginRenameTab()
        model.choose(session: "s-b", host: "local")
        model.commitRename("Build logs")
        Check.eventually("The tab rename reaches the service") { !peer.requests("window.rename").isEmpty }
        let tabRename = peer.requests("window.rename")[0]
        Check.that(tabRename.session == "s-a" && tabRename.window == "w-a" && tabRename.label == "Build logs",
                   "The tab from when the sheet opened is renamed")

        model.beginRenameSession("s-b", host: "local")
        model.commitRename(" \n\t ")
        Check.that(model.rename != nil, "A blank name keeps the sheet open")
        model.cancelRename()
        model.commitRename("After cancel")
        Check.that(model.rename == nil, "Cancelling discards the request")

        model.beginRenameSession("s-b", host: "local")
        model.states["local"]?.sessions.removeAll { $0.id == "s-b" }
        model.commitRename("Gone")
        Check.that(model.notice?.message == "This session is no longer available." && model.rename == nil, "A removed session reports why")

        var drained = false
        model.send(WireRequest(method: "test.barrier"), host: "local") { _ in drained = true }
        Check.eventually("The connection must drain") { drained }
        Check.that(peer.received.filter { $0.method.hasSuffix(".rename") }.count == 2, "Blank, cancelled and removed targets never submit")
        model.close()
        print("Workspace rename: captured session and tab targets, trimming, and blank/cancelled/removed targets passed.")
    }
}
