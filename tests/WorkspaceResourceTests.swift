import AppKit

@main
struct WorkspaceResourceTests {
    @MainActor
    static func main() async {
        let domain = "dev.illogical.resource-tests"
        precondition(Bundle.main.bundleIdentifier == domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let model = WorkspaceModel()
        model.addHost(name: "Resource fixture", address: "invalid.invalid", executable: "illogical")
        let host = model.hosts.first { !$0.isLocal }!
        weak let removed = model.engine(for: "removed-block", host: host.id)
        weak let retained = model.engine(for: "retained-block", host: "local")
        model.focusedBlock = "removed-block"; model.find()
        model.searches["removed-block"]?.query = "retained query"
        model.removeHost(host)
        guard removed == nil else { fail("removing a host retains its terminal replica/history") }
        guard retained != nil else { fail("removing a host discarded another host's viewport") }
        guard model.searchFocusedBlock == nil, model.searches["removed-block"] == nil else {
            fail("removed-host search retains stale block state")
        }
        let path = "/tmp/ilg-resource-workspace-\(getpid()).sock"
        let listener = path.withCString { il_resource_listen($0) }
        precondition(listener >= 0)
        setenv("ILLOGICAL_SOCKET", path, 1)
        defer { unlink(path) }
        DispatchQueue.global().async { il_resource_serve_workspace(listener) }
        let connected = WorkspaceModel()
        weak let disappeared = connected.engine(for: "gone", host: "local")
        connected.start()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while connected.states["local"]?.revision != 1 && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard connected.states["local"]?.revision == 1, disappeared != nil else { fail("workspace fixture never attached") }
        connected.synchronizeViewports = true
        disappeared?.scrollBottom()
        var compatibilityComplete = false
        connected.send(WireRequest(id: "compatibility", method: "test.compatibility")) { _ in compatibilityComplete = true }
        while !compatibilityComplete && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard compatibilityComplete, !connected.supportsViewportSync(), connected.notice == nil else {
            fail("an older service without capabilities received unsupported viewport requests")
        }
        connected.focusedBlock = "gone"; connected.find(); connected.searches["gone"]?.query = "query"
        connected.send(WireRequest(method: "test.drop"))
        while connected.states["local"]?.revision != 2 && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        connected.close()
        guard connected.states["local"]?.revision == 2, disappeared == nil,
              connected.searchFocusedBlock == nil, connected.searches["gone"] == nil else {
            fail("a disappeared block retained its replica or search state")
        }
        print("Workspace resources: removed-host and disappeared-block replicas released, unrelated viewport retained and stale search cleared.")
        print("Service compatibility: missing capabilities preserve basic terminals without unsupported viewport requests.")
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr); exit(1)
    }
}
