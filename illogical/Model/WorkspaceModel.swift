import AppKit
import Combine
import Observation
import SwiftUI

enum PaletteMode: String, Identifiable {
    case sessions, commands, themes, directory
    var id: String { rawValue }
}

/// A transient, non-modal message shown at the bottom of the window.
struct Notice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct RenameRequest: Identifiable {
    enum Target: Equatable {
        case session(SessionKey)
        case tab(SessionKey, deck: String)
    }
    let id = UUID()
    let target: Target
    let name: String
    var title: String {
        switch target {
        case .session: "Rename Session"
        case .tab: "Rename Tab"
        }
    }
}

/// A question asked before ending running processes.
struct ClosePrompt: Equatable {
    let title: String
    let message: String
}

/// The state of one workspace window: its service connections, the
/// session/tab/pane it shows, and its overlays. Each window has its own
/// model; preferences and host profiles are shared.
@MainActor
@Observable
final class WorkspaceModel {
    // MARK: Service state

    private(set) var hosts: [HostProfile] = [.local]
    /// The latest workspace published by each host. Tests may edit it.
    var states: [String: WorkspaceState] = [:]
    /// Connection problems per host; nil once the host has greeted.
    private(set) var statuses: [String: String] = [:]
    private(set) var hostFeatures: [String: Set<String>] = [:]
    private(set) var processIdentities: [String: ChildProcess] = [:]

    // MARK: Selection

    var selectedHost = HostProfile.local.id
    var selectedSession = ""
    var selectedDeck = ""
    private(set) var focusedBlock = ""
    /// Changes whenever the focused terminal should (re)claim keyboard focus.
    private(set) var focusToken = UUID()

    // MARK: Overlays

    var palette: PaletteMode? { didSet { if palette != .directory { cancelDirectory() } } }
    var showAddHost = false
    private(set) var rename: RenameRequest?
    var migration: [TerminalTheme] = []
    private(set) var notice: Notice?
    var sidebarFilter = ""
    /// Per-window zoom over the configured font size; not persisted.
    var fontSizeDelta: Double = 0
    var peek: CGFloat = 0 { didSet { if !isPeekGestureActive { peekExpanded = peek >= 1.5 } } }
    private(set) var isPeekGestureActive = false
    private(set) var peekExpanded = false
    private(set) var searches: [String: TerminalSearchState] = [:]
    private(set) var searchFocusedBlock: String?
    private(set) var directories: [DirectoryEntry] = []
    private(set) var directoryPath = ""
    private(set) var directoryLoading = false
    private(set) var directoryError: String?

    // MARK: Window hooks, set by the window layer

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onLaunchStage: ((String) -> Void)?
    @ObservationIgnored var onRequestActivation: (() -> Void)?
    /// Closes the window, for example when its session ended.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// Presents a close confirmation and reports whether to proceed.
    @ObservationIgnored var confirmClose: ((ClosePrompt, @escaping (Bool) -> Void) -> Void)?

    // MARK: Private bookkeeping

    @ObservationIgnored let preferences = Preferences.shared
    @ObservationIgnored private let registry = WorkspaceRegistry.shared
    @ObservationIgnored private let hostStore = HostProfileStore.shared
    @ObservationIgnored private var hostSubscription: AnyCancellable?
    @ObservationIgnored private var connections: [String: ServiceConnection] = [:]
    @ObservationIgnored private var engines: [String: TerminalEngine] = [:]
    @ObservationIgnored private var engineHosts: [String: String] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var intent: WindowIntent?
    @ObservationIgnored private var awaitingInitialState = Set<String>()
    @ObservationIgnored private var rememberedDecks: [SessionKey: String] = [:]
    @ObservationIgnored private var rememberedBlocks: [String: [String: String]] = [:]
    @ObservationIgnored private var processLookups: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var processVersions: [String: String] = [:]
    /// A newly created pane that should take focus once the service lists it.
    @ObservationIgnored private var pendingBlock: String?
    /// Panes whose kill request is in flight, and who takes focus after each.
    @ObservationIgnored private var closingBlocks: [String: String?] = [:]
    @ObservationIgnored private var closePromptVisible = false
    @ObservationIgnored private var pendingPaneNavigation: (session: SessionKey, deck: String, block: String, request: String)?
    @ObservationIgnored private var keyboardFocusIntent: UUID?
    @ObservationIgnored private var peekGestureStart: CGFloat = 0
    @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
    @ObservationIgnored private var lastSearchQuery = ""
    @ObservationIgnored private var directoryContext: DirectoryContext?
    @ObservationIgnored private var directoryRequest: String?

    private struct DirectoryContext: Equatable {
        let session: SessionKey
        let deck: String
        let block: String
    }

    init() {
        hostSubscription = hostStore.$hosts.sink { [weak self] in self?.updateHosts($0) }
    }

    // MARK: Derived state

    var activeSession: Session? { states[selectedHost]?.sessions.first { $0.id == selectedSession } }
    var activeDeck: Deck? { activeSession?.windows.first { $0.id == selectedDeck } }
    var activeHost: HostProfile { hosts.first { $0.id == selectedHost } ?? .local }
    var theme: TerminalTheme { preferences.theme }
    var fontSize: Double {
        min(Preferences.fontSizes.upperBound, max(Preferences.fontSizes.lowerBound, preferences.fontSize + fontSizeDelta))
    }
    var selection: WindowSelection { WindowSelection(host: selectedHost, session: selectedSession, tab: selectedDeck) }
    /// The session this window displays, if any.
    var shownSession: SessionKey? { selectedSession.isEmpty ? nil : SessionKey(host: selectedHost, session: selectedSession) }
    var hasOverlay: Bool { palette != nil || rename != nil || peek > 0 || showAddHost || !migration.isEmpty }
    var windowTitle: String {
        guard let session = activeSession else { return "illogical" }
        guard let deck = activeDeck else { return session.name }
        return "\(session.name) · \(deckTitle(deck, host: selectedHost))"
    }

    func info(_ block: String, host: String? = nil) -> BlockInfo? {
        states[host ?? engineHosts[block] ?? selectedHost]?.blocks.first { $0.id == block }
    }

    func deckTitle(_ deck: Deck, host: String? = nil) -> String {
        if !deck.name.isEmpty { return deck.name }
        let host = host ?? selectedHost
        return info(preferredBlock(in: deck, host: host), host: host)?.displayTitle ?? "Terminal"
    }

    func isConnected(_ host: String) -> Bool { connections[host] != nil && statuses[host] == nil && states[host] != nil }

    func supports(_ feature: String, host: String? = nil) -> Bool {
        hostFeatures[host ?? selectedHost]?.contains(feature) == true
    }

    func supportsViewportSync(host: String? = nil) -> Bool { supports(WireFeature.viewport, host: host) }

    /// Sessions that can be shown: those with at least one tab.
    func sessions(on host: String) -> [Session] { states[host]?.sessions.filter(\.hasTabs) ?? [] }

    /// The window other than this one that shows `session`, if any.
    func otherWindow(showing session: SessionKey) -> WorkspaceModel? {
        registry.window(showing: session, excluding: self)
    }

    // MARK: Lifecycle

    /// Connects to every host. `intent` decides what the window shows once
    /// the service answers.
    func start(_ intent: WindowIntent = .reopen) {
        guard !started else { return }
        started = true
        self.intent = intent
        registry.register(self)
        observePreferences()
        for host in hosts { connect(host) }
    }

    func close() {
        registry.unregister(self)
        pendingPaneNavigation = nil
        cancelDirectory()
        noticeDismissal?.cancel()
        for lookup in processLookups.values { lookup.cancel() }
        processLookups.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        started = false
    }

    private func connect(_ host: HostProfile) {
        onLaunchStage?("connectionStart")
        let connection = ServiceConnection(host: host)
        connections[host.id] = connection
        statuses[host.id] = "Connecting to \(host.name)…"
        connection.onStatus = { [weak self] status in self?.statuses[host.id] = status }
        connection.onMessage = { [weak self] message in self?.receive(message, from: host.id) }
        connection.connect()
    }

    private func updateHosts(_ updated: [HostProfile]) {
        let removed = hosts.filter { old in !updated.contains { $0.id == old.id } }
        let added = updated.filter { new in !hosts.contains { $0.id == new.id } }
        hosts = updated
        for host in removed { disconnect(host) }
        if started { for host in added { connect(host) } }
    }

    private func disconnect(_ host: HostProfile) {
        connections.removeValue(forKey: host.id)?.close()
        discardEngines(Set(engineHosts.filter { $0.value == host.id }.keys).union(states[host.id]?.blocks.map(\.id) ?? []))
        rememberedDecks = rememberedDecks.filter { $0.key.host != host.id }
        rememberedBlocks.removeValue(forKey: host.id)
        awaitingInitialState.remove(host.id)
        states.removeValue(forKey: host.id)
        statuses.removeValue(forKey: host.id)
        hostFeatures.removeValue(forKey: host.id)
        if selectedHost == host.id {
            selectedHost = HostProfile.local.id
            clearSelection()
            showMostRecentOrNewSession()
        }
    }

    /// Re-applies theme and scrolling preferences whenever they change.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.theme
            _ = preferences.synchronizeViewports
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.applyPreferences()
                self.observePreferences()
            }
        }
    }

    private func applyPreferences() {
        let theme = preferences.theme
        for (block, engine) in engines {
            let host = engineHosts[block] ?? selectedHost
            engine.applyTheme(theme)
            send(WireRequest(method: .blockTheme, block: block, theme: theme.wire), host: host)
            configureViewport(engine, block: block, host: host)
        }
    }

    // MARK: Service messages

    /// Sends a background request. Failures are not shown to the user.
    func send(_ request: WireRequest, host: String? = nil, completion: ((WireMessage) -> Void)? = nil) {
        connections[host ?? selectedHost]?.send(request, completion: completion)
    }

    /// Sends a request the user asked for; a failure appears as a notice.
    func perform(_ request: WireRequest, host: String? = nil, then completion: ((WireMessage) -> Void)? = nil) {
        let host = host ?? selectedHost
        guard let connection = connections[host] else { show("\(hosts.first { $0.id == host }?.name ?? "The host") is not connected.");return }
        connection.send(request) { [weak self] reply in
            if let error = reply.error, !error.isEmpty { self?.show(error) }
            completion?(reply)
        }
    }

    private func receive(_ message: WireMessage, from host: String) {
        switch message.type {
        case "hello": greet(message, from: host)
        case "state": if let state = message.state { apply(state, from: host) }
        case "event": handleEvent(message, from: host)
        case "focus": handleFocusRequest(message, from: host)
        case "viewport":
            if let block = message.block, let distance = message.viewport, preferences.synchronizeViewports,
               let engine = engines[block], message.stream == engine.stream { engine.receiveViewport(distance) }
        case "snapshot", "history", "output", "resize", "theme", "graphics", "resume", "resync":
            guard let block = message.block, let engine = engines[block] else { return }
            if message.type == "snapshot" { onLaunchStage?("snapshotReceived") }
            engine.receive(message)
            if message.type == "snapshot" { onLaunchStage?("snapshotRestored") }
            if message.type == "snapshot" || message.type == "resume" { configureViewport(engine, block: block, host: host) }
        case "error":
            // Replies to requests are handled by whoever sent them.
            if message.id == nil, let error = message.error, !error.isEmpty { show(error) }
        default: break
        }
    }

    private func greet(_ hello: WireMessage, from host: String) {
        onLaunchStage?("serviceHello")
        guard hello.protocol == WireCompatibility.protocolVersion, hello.engine == WireCompatibility.engine else {
            let name = hosts.first { $0.id == host }?.name ?? "This host"
            statuses[host] = "\(name) runs a different illogical build (terminal engine \(hello.engine ?? "unknown"), "
                + "protocol \(hello.protocol.map(String.init) ?? "unknown")). Install the same illogical version as this Mac there, "
                + "then reconnect."
            connections[host]?.close()
            return
        }
        statuses[host] = nil
        awaitingInitialState.insert(host)
        hostFeatures[host] = Set(hello.features ?? [])
        send(WireRequest(method: .watch), host: host)
        for (block, engineHost) in engineHosts where engineHost == host {
            send(engines[block]?.attachmentRequest() ?? WireRequest(method: .blockAttach, block: block), host: host)
        }
        if engineHosts[focusedBlock] == host {
            engines[focusedBlock]?.requestedSize = nil
            send(WireRequest(method: .blockClaim, block: focusedBlock), host: host)
        }
    }

    private func handleEvent(_ message: WireMessage, from host: String) {
        guard let block = message.block else { return }
        switch message.event {
        case "block_closed":
            if engineHosts[block] == host { retireEngine(block) }
        case "bell":
            if block == focusedBlock { requestAttention() }
        case "desktop_notification":
            if let text = message.text, !text.isEmpty { show(text);requestAttention() }
        case "clipboard_written":
            guard block == focusedBlock, let data = message.data, let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "error":
            if let text = message.text, !text.isEmpty { show(text) }
        default: break
        }
    }

    /// The service asks this client to show a pane (`illogical focus`).
    private func handleFocusRequest(_ message: WireMessage, from host: String) {
        guard let block = message.block, let session = message.session, let deck = message.window else { return }
        show(session: session, host: host, tab: deck, explicit: true)
        focus(block)
        onRequestActivation?()
    }

    private func requestAttention() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Shows a non-modal notice that dismisses itself.
    func show(_ message: String) {
        let notice = Notice(message: message)
        self.notice = notice
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.notice == notice else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: Workspace state

    private func apply(_ state: WorkspaceState, from host: String) {
        onLaunchStage?("workspaceState")
        let previous = states[host]
        let initial = awaitingInitialState.remove(host) != nil
        refreshProcessIdentities(state, host: host)
        // Revision and client count change on every broadcast; only redraw
        // when something visible changed.
        if previous?.sessions != state.sessions || previous?.blocks != state.blocks || previous == nil {
            states[host] = state
        }
        if let previous { rememberFocusTargets(from: previous, to: state, host: host) }
        resolvePendingPaneNavigation(in: state, host: host)
        let valid = Set(state.blocks.map(\.id))
        discardEngines(Set(engineHosts.filter { $0.value == host && !valid.contains($0.key) }.keys))

        if let intent, intent.host == host {
            self.intent = nil
            resolve(intent, in: state, host: host)
        } else if host == selectedHost && intent == nil {
            // While a window waits for the host it restores, other hosts'
            // states must not choose (or create) something else to show.
            if let pendingBlock {
                guard valid.contains(pendingBlock) else { return }
                self.pendingBlock = nil
                focus(pendingBlock)
            }
            reconcileSelection(previous: previous, in: state, host: host, reconnected: initial)
        }
        if palette == .directory && !directoryContextIsCurrent { palette = nil }
    }

    /// Chooses what a new window shows once its host has published a state.
    private func resolve(_ intent: WindowIntent, in state: WorkspaceState, host: String) {
        switch intent {
        case .restore(let stored):
            let key = SessionKey(host: stored.host, session: stored.session)
            if state.sessions.contains(where: { $0.id == stored.session && $0.hasTabs }), otherWindow(showing: key) == nil {
                show(session: stored.session, host: stored.host, tab: stored.tab, explicit: true)
            } else if !showMostRecentUnattachedSession() {
                // Another window already covers the user's work.
                if registry.models.count > 1 { requestClose() } else { newSession(host: host) }
            }
        case .newSession(let host, let parent):
            newSession(host: host, parentBlock: parent)
        case .reopen:
            showMostRecentOrNewSession()
        }
    }

    /// Keeps the selection valid after the service changed the workspace.
    private func reconcileSelection(previous: WorkspaceState?, in state: WorkspaceState, host: String, reconnected: Bool) {
        guard let session = state.sessions.first(where: { $0.id == selectedSession }), session.hasTabs else {
            let wasShown = previous?.sessions.contains { $0.id == selectedSession && $0.hasTabs } == true
            if reconnected || !wasShown {
                // A restarted service, or nothing chosen yet.
                if selectedSession.isEmpty || reconnected { clearSelection();showMostRecentOrNewSession() }
            } else {
                // The session ended: its windows close, like the last surface in Ghostty.
                clearSelection()
                requestClose()
            }
            return
        }
        if !session.windows.contains(where: { $0.id == selectedDeck }) {
            // Right neighbour, else left: the tab that slid into the closed one's place.
            let oldIndex = previous?.sessions.first { $0.id == selectedSession }?.windows.firstIndex { $0.id == selectedDeck }
            let index = min(oldIndex ?? 0, session.windows.count - 1)
            selectedDeck = session.windows[index].id
            rememberedDecks[SessionKey(host: host, session: session.id)] = selectedDeck
        }
        if let deck = activeDeck {
            let preferred = preferredBlock(in: deck, host: host)
            if focusedBlock != preferred { focus(preferred, explicit: false) }
        }
    }

    @discardableResult
    private func showMostRecentUnattachedSession() -> Bool {
        let candidates = hosts.flatMap { host in sessions(on: host.id).map { SessionKey(host: host.id, session: $0.id) } }
        guard let key = registry.mostRecentFirst(candidates).first(where: { otherWindow(showing: $0) == nil }) else { return false }
        show(session: key.session, host: key.host, explicit: true)
        return true
    }

    private func showMostRecentOrNewSession() {
        if !showMostRecentUnattachedSession() && states[HostProfile.local.id] != nil { newSession(host: HostProfile.local.id) }
    }

    private func clearSelection() {
        selectedSession = ""
        selectedDeck = ""
        focusedBlock = ""
    }

    private func requestClose() {
        registry.unregister(self)
        onRequestClose?()
    }

    /// Records, for every tab that lost its remembered pane, the pane that
    /// takes over: the target chosen when the close was requested, or
    /// Ghostty's previous-leaf rule when the process ended by itself.
    private func rememberFocusTargets(from previous: WorkspaceState, to state: WorkspaceState, host: String) {
        let surviving = Set(state.blocks.map(\.id))
        let oldDecks = Dictionary(previous.sessions.flatMap(\.windows).map { ($0.id, $0) }) { first, _ in first }
        let newDecks = Dictionary(state.sessions.flatMap(\.windows).map { ($0.id, $0) }) { first, _ in first }
        var remembered = rememberedBlocks[host] ?? [:]
        if host == selectedHost, !focusedBlock.isEmpty, oldDecks[selectedDeck]?.root.contains(focusedBlock) == true {
            remembered[selectedDeck] = focusedBlock
        }
        for (deckID, block) in remembered {
            guard let deck = newDecks[deckID] else { remembered.removeValue(forKey: deckID);continue }
            let current = Set(deck.root.blocks).intersection(surviving)
            guard !current.contains(block) else { continue }
            if let chosen = closingBlocks[block] ?? nil, current.contains(chosen) {
                remembered[deckID] = chosen
            } else {
                remembered[deckID] = oldDecks[deckID]?.root.focusTarget(afterClosing: block, surviving: current)
            }
        }
        rememberedBlocks[host] = remembered
    }

    private func resolvePendingPaneNavigation(in state: WorkspaceState, host: String) {
        guard let pending = pendingPaneNavigation, pending.session.host == host else { return }
        let deck = state.sessions.first { $0.id == pending.session.session }?.windows.first { $0.id == pending.deck }
        if deck?.zoomed == pending.block, shownSession == pending.session, selectedDeck == pending.deck {
            focus(pending.block)
        }
        if deck?.zoomed == pending.block || deck?.root.contains(pending.block) != true { pendingPaneNavigation = nil }
    }

    private func refreshProcessIdentities(_ state: WorkspaceState, host: String) {
        let valid = Set(state.blocks.map(\.id))
        for block in states[host]?.blocks ?? [] where !valid.contains(block.id) { forgetProcess(block.id) }
        for block in state.blocks {
            let version = "\(block.pid):\(block.title):\(block.cwd)"
            guard processVersions[block.id] != version else { continue }
            processVersions[block.id] = version
            processLookups.removeValue(forKey: block.id)?.cancel()
            processLookups[block.id] = Task { [weak self] in
                // A shell may retitle before handing the terminal to its job.
                // Coalesce that transition instead of polling.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.closingBlocks[block.id] == nil,
                      self.processVersions[block.id] == version else { return }
                self.processLookups.removeValue(forKey: block.id)
                self.send(WireRequest(method: .blockProcess, block: block.id), host: host) { [weak self] reply in
                    guard let self, self.processVersions[block.id] == version, let process = reply.process else { return }
                    self.remember(process, for: block.id)
                }
            }
        }
    }

    private func remember(_ process: ChildProcess, for block: String) {
        if processIdentities[block] != process { processIdentities[block] = process }
    }

    private func forgetProcess(_ block: String) {
        processLookups.removeValue(forKey: block)?.cancel()
        processIdentities.removeValue(forKey: block)
        processVersions.removeValue(forKey: block)
    }

    /// What a pane is running: its foreground program when known, else a
    /// guess from its title.
    func processBadge(_ block: String, host: String? = nil) -> ProcessBadge {
        if let process = processIdentities[block], process.foreground != nil || process.foregroundPID == process.pid {
            return ProcessBadge(program: process.jobName)
        }
        return ProcessBadge(title: info(block, host: host)?.title ?? "") ?? .shell
    }

    // MARK: Engines

    /// The terminal replica for `block`, created and attached on first use.
    func engine(for block: String, host: String? = nil) -> TerminalEngine {
        if let engine = engines[block] { return engine }
        let host = host ?? selectedHost
        let engine = TerminalEngine(blockID: block, theme: theme)
        // SwiftUI can evaluate an outgoing pane after the service removed it.
        // Give that view an inert replica that is neither cached nor attached.
        guard closingBlocks[block] == nil, states[host]?.blocks.contains(where: { $0.id == block }) != false else { return engine }
        engines[block] = engine
        engineHosts[block] = host
        engine.onInput = { [weak self] data in
            guard let self, self.closingBlocks[block] == nil else { return }
            self.send(WireRequest(method: .blockWrite, block: block, data: data), host: host)
        }
        engine.onResize = { [weak self] columns, rows, width, height in
            guard let self, self.closingBlocks[block] == nil else { return }
            self.send(WireRequest(method: .blockResize, block: block, cols: columns, rows: rows, cellWidth: width, cellHeight: height), host: host)
        }
        engine.onReplayGap = { [weak self] in
            guard let self, self.closingBlocks[block] == nil else { return }
            self.send(WireRequest(method: .blockAttach, block: block), host: host)
        }
        engine.onError = { [weak self] error in self?.show(error) }
        engine.onSearch = { [weak self] total, index, row in self?.searches[block]?.receive(count: total, selected: index, row: row) }
        engine.onSearchGeometry = { [weak self] spans in self?.searches[block]?.receive(spans: spans) }
        send(WireRequest(method: .blockAttach, block: block), host: host)
        send(WireRequest(method: .blockTheme, block: block, theme: theme.wire), host: host)
        return engine
    }

    private func configureViewport(_ engine: TerminalEngine, block: String, host: String) {
        guard closingBlocks[block] == nil else { return }
        guard supportsViewportSync(host: host) else { engine.onViewportChange = nil;return }
        if preferences.synchronizeViewports {
            engine.onViewportChange = { [weak self] distance in
                guard let self, self.closingBlocks[block] == nil else { return }
                self.send(WireRequest(method: .blockViewport, block: block, viewport: distance), host: host)
            }
        } else {
            engine.onViewportChange = nil
        }
        send(WireRequest(method: .blockViewport, block: block, synchronized: preferences.synchronizeViewports), host: host)
    }

    private func discardEngines(_ blocks: Set<String>) {
        guard !blocks.isEmpty else { return }
        for block in blocks {
            retireEngine(block)
            closeSearch(block)
            engines.removeValue(forKey: block)
            engineHosts.removeValue(forKey: block)
            forgetProcess(block)
            closingBlocks.removeValue(forKey: block)
        }
        if let pendingBlock, blocks.contains(pendingBlock) { self.pendingBlock = nil }
    }

    /// Stops a removed pane's replica from talking to the service. AppKit may
    /// still lay out or resign focus on its view during SwiftUI teardown.
    private func retireEngine(_ block: String) {
        guard let engine = engines[block] else { return }
        engine.onInput = nil
        engine.onResize = nil
        engine.onReplayGap = nil
        engine.onViewportChange = nil
        processLookups.removeValue(forKey: block)?.cancel()
    }

    /// Marks a pane as closing so its replica stops sending input and
    /// resizes, recording who should take focus when it is gone.
    func markClosing(_ block: String, focusTarget: String?) {
        closingBlocks[block] = .some(focusTarget)
        processLookups.removeValue(forKey: block)?.cancel()
    }

    func unmarkClosing(_ block: String) {
        closingBlocks.removeValue(forKey: block)
        engines[block]?.requestedSize = nil
        processVersions.removeValue(forKey: block)
        if let state = states[engineHosts[block] ?? selectedHost] { refreshProcessIdentities(state, host: engineHosts[block] ?? selectedHost) }
    }

    func isClosing(_ block: String) -> Bool { closingBlocks[block] != nil }

    // MARK: Selection

    /// Shows a session in this window, or brings forward the window that
    /// already shows it.
    func choose(session: String, host: String, explicit: Bool = true) {
        let key = SessionKey(host: host, session: session)
        if let other = otherWindow(showing: key) {
            dismissOverlays()
            other.onRequestActivation?()
            return
        }
        show(session: session, host: host, explicit: explicit)
    }

    /// Selects a tab, switching session (or window) when it belongs elsewhere.
    func choose(deck: String, session: String? = nil, host: String? = nil) {
        let key = SessionKey(host: host ?? selectedHost, session: session ?? selectedSession)
        if key != shownSession, let other = otherWindow(showing: key) {
            dismissOverlays()
            other.choose(deck: deck)
            other.onRequestActivation?()
            return
        }
        show(session: key.session, host: key.host, tab: deck, explicit: true)
    }

    private func show(session: String, host: String, tab: String? = nil, explicit: Bool) {
        pendingPaneNavigation = nil
        let key = SessionKey(host: host, session: session)
        selectedHost = host
        selectedSession = session
        registry.recordUse(key)
        let tabs = states[host]?.sessions.first { $0.id == session }?.windows ?? []
        let candidates = [tab, rememberedDecks[key], states[host]?.sessions.first { $0.id == session }?.focusedWindow]
        selectedDeck = candidates.compactMap { $0 }.first { id in tabs.contains { $0.id == id } } ?? tabs.first?.id ?? ""
        if !selectedDeck.isEmpty { rememberedDecks[key] = selectedDeck }
        palette = nil
        isPeekGestureActive = false
        peek = 0
        focus(activeDeck.map { preferredBlock(in: $0, host: host) } ?? "", explicit: explicit)
    }

    func selectAdjacentTab(_ offset: Int) {
        guard offset != 0, let tabs = activeSession?.windows, !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.id == selectedDeck }) else {
            choose(deck: offset > 0 ? tabs[0].id : tabs[tabs.count - 1].id)
            return
        }
        let next = ((current + offset) % tabs.count + tabs.count) % tabs.count
        if next != current { choose(deck: tabs[next].id) }
    }

    /// Command-1 to Command-8 select that tab; `index` 8 is the last tab.
    func selectTab(_ index: Int) {
        guard let tabs = activeSession?.windows, !tabs.isEmpty else { return }
        let selected = index == 8 ? tabs.count - 1 : index
        guard tabs.indices.contains(selected) else { return }
        choose(deck: tabs[selected].id)
    }

    func focusAdjacentPane(_ direction: PaneDirection) {
        guard let deck = activeDeck else { return }
        navigate(to: deck.root.adjacentBlock(from: navigationSource(in: deck), direction: direction), in: deck)
    }

    /// Command-] and Command-[: the next or previous pane in reading order.
    func cyclePane(_ offset: Int) {
        guard let deck = activeDeck else { return }
        navigate(to: deck.root.cycle(from: navigationSource(in: deck), by: offset), in: deck)
    }

    /// Moving while a zoom request is pending continues from its target.
    private func navigationSource(in deck: Deck) -> String {
        if let pending = pendingPaneNavigation, pending.session == shownSession, pending.deck == deck.id { return pending.block }
        return focusedBlock
    }

    private func navigate(to target: String?, in deck: Deck) {
        guard let target, let session = shownSession else { return }
        guard let zoomed = deck.zoomed, !zoomed.isEmpty else { focus(target);return }
        // The zoom follows focus. Keep focus on the visible pane until the
        // service publishes it; the pending target stops repeated keys from
        // toggling zoom off.
        let request = WireRequest(method: .windowZoom, window: deck.id, block: target)
        pendingPaneNavigation = (session, deck.id, target, request.id)
        send(request, host: session.host) { [weak self] reply in
            guard let self, reply.error != nil, self.pendingPaneNavigation?.request == request.id else { return }
            self.pendingPaneNavigation = nil
        }
    }

    /// The pane a tab shows focused: its zoomed pane, the pane focused there
    /// last, the service's record, then the first pane.
    func preferredBlock(in deck: Deck, host: String? = nil) -> String {
        let blocks = deck.root.blocks
        let host = host ?? selectedHost
        let candidates = [deck.zoomed, rememberedBlocks[host]?[deck.id], deck.focusedBlock]
        return candidates.compactMap { $0 }.first(where: blocks.contains) ?? blocks.first ?? ""
    }

    /// Focuses a pane of the shown tab. `explicit` focus (a click, a key,
    /// a new pane) may take keyboard focus from a text field; background
    /// reconciliation never does.
    func focus(_ block: String, explicit: Bool = true) {
        var block = block
        let host = engineHosts[block] ?? selectedHost
        if !block.isEmpty {
            guard closingBlocks[block] == nil else { return }
            if let deck = activeDeck {
                guard deck.root.contains(block) else { return }
            } else {
                guard states[host]?.blocks.contains(where: { $0.id == block }) != false else { return }
            }
        }
        if let deck = activeDeck, deck.root.contains(block) {
            if let zoomed = deck.zoomed, deck.root.contains(zoomed) { block = zoomed }
            rememberedBlocks[selectedHost, default: [:]][deck.id] = block
        }
        searchFocusedBlock = nil
        focusedBlock = block
        requestTerminalFocus(explicit: explicit)
        engines[block]?.requestedSize = nil
        if palette == .directory && !directoryContextIsCurrent { palette = nil }
        guard !block.isEmpty else { return }
        send(WireRequest(method: .blockClaim, block: block), host: engineHosts[block] ?? selectedHost)
    }

    /// Asks the focused terminal to take keyboard focus again, for example
    /// after an overlay closes.
    func requestTerminalFocus(explicit: Bool = true) {
        focusToken = UUID()
        keyboardFocusIntent = explicit ? focusToken : nil
    }

    /// Lets a terminal replace a focused text field only for the focus
    /// request that asked for it, and only once.
    func consumeKeyboardFocusIntent(_ token: UUID?) -> Bool {
        guard let token, token == keyboardFocusIntent else { return false }
        keyboardFocusIntent = nil
        return true
    }

    // MARK: Closing

    /// Command-W. Dismisses an open overlay first; with nothing to close the
    /// window closes.
    func closeFocusedPane() {
        if dismissOverlays() { return }
        guard let deck = activeDeck, deck.root.contains(focusedBlock) else { closeWindow();return }
        closePane(focusedBlock)
    }

    /// Ends a pane's process, asking first if a job is running in it. Focus
    /// then moves to the previous pane in reading order, as in Ghostty.
    func closePane(_ block: String) {
        let host = selectedHost
        guard let deck = activeDeck, deck.root.contains(block), !isClosing(block) else { return }
        let surviving = Set(deck.root.blocks).subtracting([block])
        let target = deck.root.focusTarget(afterClosing: block, surviving: surviving)
        confirmEnding([block], host: host, title: "Close Terminal?", always: false) { [weak self] in
            guard let self else { return }
            self.markClosing(block, focusTarget: target)
            self.perform(WireRequest(method: .blockKill, block: block), host: host) { [weak self] reply in
                if reply.error != nil { self?.unmarkClosing(block) }
            }
        }
    }

    /// Option-Command-W, the tab close button and context menu.
    func closeTab(_ deck: String? = nil) {
        if deck == nil, dismissOverlays() { return }
        let host = selectedHost
        let id = deck ?? selectedDeck
        guard let tab = activeSession?.windows.first(where: { $0.id == id }) else { return }
        confirmEnding(tab.root.blocks, host: host, title: "Close Tab?", always: false) { [weak self] in
            self?.perform(WireRequest(method: .windowKill, window: id), host: host)
        }
    }

    /// Ends every terminal of a session. Always confirms, since it removes a
    /// named workspace.
    func closeSession(_ session: String, host: String) {
        guard let target = states[host]?.sessions.first(where: { $0.id == session }) else { return }
        let blocks = target.windows.flatMap(\.root.blocks)
        confirmEnding(blocks, host: host, title: "Close Session?", always: true, sessionName: target.name) { [weak self] in
            self?.perform(WireRequest(method: .sessionKill, session: session), host: host)
        }
    }

    /// Shift-Command-W: detaches this window. Nothing is ended.
    func closeWindow() { onRequestClose?() }

    /// Asks the service which panes run a job, then confirms when any does
    /// (or when `always`), and finally runs `end`.
    private func confirmEnding(_ blocks: [String], host: String, title: String, always: Bool,
                               sessionName: String? = nil, end: @escaping () -> Void) {
        guard !blocks.isEmpty, !closePromptVisible else { return }
        guard isConnected(host) else { show("Can't close: host offline");return }
        closePromptVisible = true
        let query = RunningJobsQuery(blocks: blocks)
        for block in blocks {
            send(WireRequest(method: .blockProcess, block: block), host: host) { [weak self, query] reply in
                if let process = reply.process { self?.remember(process, for: block) }
                query.receive(reply.process, for: block)
            }
        }
        query.onFinish = { [weak self] jobs in
            guard let self else { return }
            guard always || jobs == nil || jobs?.isEmpty == false else {
                self.closePromptVisible = false
                end()
                return
            }
            let prompt = ClosePrompt(title: title, message: Self.closeMessage(jobs: jobs, blockCount: blocks.count, sessionName: sessionName))
            guard let confirmClose = self.confirmClose else { self.closePromptVisible = false;end();return }
            confirmClose(prompt) { [weak self] confirmed in
                guard let self else { return }
                self.closePromptVisible = false
                if confirmed { end() } else { self.requestTerminalFocus() }
            }
        }
        query.start(timeout: .milliseconds(150))
    }

    private static func closeMessage(jobs: [String]?, blockCount: Int, sessionName: String?) -> String {
        let prefix = sessionName.map { "This ends every terminal in “\($0)”. " } ?? ""
        guard let jobs else { return prefix + "A process may still be running. Closing will end it." }
        switch jobs.count {
        case 0: return prefix.trimmingCharacters(in: .whitespaces)
        case 1: return prefix + "\(jobs[0]) is still running. Closing will end it."
        default:
            let names = Array(Set(jobs)).sorted().joined(separator: ", ")
            return prefix + "\(jobs.count) terminals are running processes (\(names)). Closing will end them."
        }
    }

    /// Closes the topmost overlay. Returns whether one was open.
    @discardableResult
    func dismissOverlays() -> Bool {
        if palette != nil { dismissPalette();return true }
        if rename != nil { cancelRename();return true }
        if showAddHost { showAddHost = false;requestTerminalFocus();return true }
        if !migration.isEmpty { migration = [];requestTerminalFocus();return true }
        if peek > 0 { dismissPeek();return true }
        return false
    }

    // MARK: Layout

    func zoom(_ block: String? = nil) {
        guard let deck = activeDeck else { return }
        perform(WireRequest(method: .windowZoom, window: deck.id, block: block ?? focusedBlock))
    }

    func move(_ block: String, to target: String, axis: SplitAxis) {
        let host = selectedHost
        perform(WireRequest(method: .blockMove, block: block, target: target, axis: axis), host: host) { [weak self] in
            self?.created($0, host: host)
        }
    }

    func resizeSplit(_ split: String, ratio: Double, deck: String) {
        perform(WireRequest(method: .layoutResize, window: deck, target: split, ratio: ratio))
    }

    /// Control-Command-arrows: moves the nearest divider by ten cells.
    func resizePane(_ direction: PaneDirection) {
        guard let deck = activeDeck, deck.zoomed == nil else { return }
        let resized = deck.root.resized(focusedBlock, toward: direction, cells: 10) { [weak self] block in
            self?.info(block).map { (Int($0.cols), Int($0.rows)) }
        }
        if let resized { resizeSplit(resized.split, ratio: resized.ratio, deck: deck.id) }
    }

    /// Control-Command-=: gives every pane an equal share.
    func equalizePanes() {
        guard let deck = activeDeck else { return }
        for change in deck.root.equalizedRatios() { resizeSplit(change.split, ratio: change.ratio, deck: deck.id) }
    }

    /// Option-Shift-Command-[ and ]: swaps the tab with its neighbour.
    func moveTab(_ offset: Int) {
        guard let tabs = activeSession?.windows, let index = tabs.firstIndex(where: { $0.id == selectedDeck }),
              tabs.indices.contains(index + offset) else { return }
        guard supports(WireFeature.windowMove) else { show("Moving tabs needs a newer illogical service on \(activeHost.name).");return }
        perform(WireRequest(method: .windowMove, window: selectedDeck, target: tabs[index + offset].id))
    }

    /// Option-Command-K: erases the screen and scrollback like Ghostty's
    /// clear_screen. The service redraws the prompt when a shell is waiting.
    func clearScreen() {
        guard !focusedBlock.isEmpty else { return }
        guard supports(WireFeature.clear) else { show("Clearing needs a newer illogical service on \(activeHost.name).");return }
        perform(WireRequest(method: .blockClear, block: focusedBlock))
    }

    // MARK: Font size

    func adjustFontSize(by step: Double) { fontSizeDelta = fontSize + step - preferences.fontSize }
    func resetFontSize() { fontSizeDelta = 0 }

    // MARK: Scrolling

    func scrollToTop() { activeEngine?.scrollTo(0) }
    func scrollToBottom() { activeEngine?.scrollBottom() }
    func scrollPage(_ direction: Int) {
        guard let info = info(focusedBlock) else { return }
        activeEngine?.scroll(direction * max(1, Int(info.rows) - 1))
    }

    private var activeEngine: TerminalEngine? {
        focusedBlock.isEmpty ? nil : engine(for: focusedBlock)
    }

    // MARK: Palette

    func togglePalette(_ mode: PaletteMode) {
        if palette == mode { dismissPalette() } else { palette = mode }
    }

    /// Closes the palette without acting, returning focus to the pane.
    func dismissPalette() {
        palette = nil
        requestTerminalFocus()
    }

    /// Sessions for the picker, most recently used first.
    var pickerSessions: [(key: SessionKey, session: Session, host: HostProfile)] {
        let all = hosts.flatMap { host in sessions(on: host.id).map { (SessionKey(host: host.id, session: $0.id), $0, host) } }
        let order = WorkspaceRegistry.shared.mostRecentFirst(all.map(\.0))
        return order.compactMap { key in all.first { $0.0 == key } }
    }

    /// Reads the user's Ghostty theme settings and offers them for preview.
    func importGhosttyThemes() {
        do { migration = try GhosttyThemeImporter.importConfiguration() } catch { show(error.localizedDescription) }
    }

    // MARK: Rename

    func beginRenameSession(_ session: String? = nil, host: String? = nil) {
        let host = host ?? selectedHost
        guard let target = states[host]?.sessions.first(where: { $0.id == (session ?? selectedSession) }) else { return }
        palette = nil
        rename = RenameRequest(target: .session(SessionKey(host: host, session: target.id)), name: target.name)
    }

    func beginRenameTab(_ deck: String? = nil) {
        guard let session = shownSession, let tab = activeSession?.windows.first(where: { $0.id == (deck ?? selectedDeck) }) else { return }
        palette = nil
        rename = RenameRequest(target: .tab(session, deck: tab.id), name: deckTitle(tab))
    }

    func cancelRename() {
        rename = nil
        requestTerminalFocus()
    }

    /// Applies a rename to the target captured when it began, ignoring any
    /// selection change since. Blank names are rejected.
    func commitRename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let request = rename else { return }
        cancelRename()
        switch request.target {
        case .session(let key):
            guard states[key.host]?.sessions.contains(where: { $0.id == key.session }) == true else {
                show("This session is no longer available.");return
            }
            perform(WireRequest(method: .sessionRename, session: key.session, label: name), host: key.host)
        case .tab(let key, let deck):
            guard states[key.host]?.sessions.first(where: { $0.id == key.session })?.windows.contains(where: { $0.id == deck }) == true else {
                show("This tab is no longer available.");return
            }
            perform(WireRequest(method: .windowRename, session: key.session, window: deck, label: name), host: key.host)
        }
    }

    // MARK: Search

    /// Command-F: opens the focused pane's search, or refocuses it.
    func find() {
        guard !focusedBlock.isEmpty else { return }
        openSearch(focusedBlock).focusToken = UUID()
        searchFocusedBlock = focusedBlock
    }

    /// Command-G and Shift-Command-G. With no search open, the last query
    /// is searched again.
    func findNext(_ direction: Int32 = 1) {
        guard !focusedBlock.isEmpty else { return }
        let search = searches[focusedBlock] ?? openSearch(focusedBlock)
        if search.query.isEmpty { search.query = lastSearchQuery }
        updateSearch(focusedBlock, direction: direction)
    }

    var hasOpenSearch: Bool { searches[focusedBlock] != nil }

    @discardableResult
    private func openSearch(_ block: String) -> TerminalSearchState {
        if let search = searches[block] { return search }
        let search = TerminalSearchState()
        searches[block] = search
        return search
    }

    func focusSearch(_ block: String) {
        guard searches[block] != nil else { return }
        if focusedBlock != block { focus(block) }
        searchFocusedBlock = block
    }

    func updateSearch(_ block: String, direction: Int32 = 0) {
        guard let search = searches[block] else { return }
        if !search.query.isEmpty { lastSearchQuery = search.query }
        engine(for: block).search(search.query, direction: direction)
    }

    func closeSearch(_ block: String) {
        guard searches[block] != nil else { return }
        engines[block]?.search("")
        searches.removeValue(forKey: block)
        guard searchFocusedBlock == block else { return }
        searchFocusedBlock = nil
        requestTerminalFocus()
    }

    // MARK: Peek

    /// Tracks a three-finger gesture (or a keyboard toggle) between the
    /// terminal (0), tab peek (1) and the session overview (2).
    func setPeek(_ progress: CGFloat, finished: Bool) {
        guard progress.isFinite else { return }
        let progress = min(2, max(0, progress))
        if finished {
            let start = isPeekGestureActive ? peekGestureStart : peek
            let closeThreshold: CGFloat = start == 0 ? 0.3 : 0.55
            let expandThreshold: CGFloat = start == 2 ? 1.4 : 1.6
            let target: CGFloat = progress < closeThreshold ? 0 : (progress < expandThreshold ? 1 : 2)
            animateNavigation { isPeekGestureActive = false;peek = target }
            if target == 0 { requestTerminalFocus() }
        } else {
            if !isPeekGestureActive { peekGestureStart = peek;isPeekGestureActive = true }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { peek = progress }
        }
    }

    /// How far the terminal slides down to reveal the peek.
    func peekOffset(height: CGFloat) -> CGFloat {
        let compact = min(216, max(0, height) * 0.48)
        let progress = min(2, max(0, peek))
        return progress <= 1 ? compact * progress : compact + (max(0, height) + 20 - compact) * (progress - 1)
    }

    func animateNavigation(_ change: () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var transaction = Transaction(animation: reduceMotion ? nil : .snappy(duration: 0.24))
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction, change)
    }

    func dismissPeek() { setPeek(0, finished: true) }
    func togglePeek(_ level: CGFloat) { setPeek(peek == level ? 0 : level, finished: true) }

    // MARK: Directory picker

    /// Shift-Command-G: lists directories on the focused pane's host.
    func showDirectory() {
        cancelDirectory()
        guard let session = shownSession, let deck = activeDeck, deck.root.contains(focusedBlock) else { return }
        directoryContext = DirectoryContext(session: session, deck: deck.id, block: focusedBlock)
        palette = .directory
        loadDirectory("")
    }

    private var directoryContextIsCurrent: Bool {
        guard let context = directoryContext, palette == .directory, context.session == shownSession,
              context.deck == selectedDeck, context.block == focusedBlock,
              hosts.contains(where: { $0.id == context.session.host }),
              states[context.session.host]?.blocks.contains(where: { $0.id == context.block }) == true,
              activeDeck?.root.contains(context.block) == true else { return false }
        return true
    }

    private func cancelDirectory() {
        guard directoryContext != nil || directoryRequest != nil || directoryLoading || !directories.isEmpty
                || !directoryPath.isEmpty || directoryError != nil else { return }
        directoryRequest = nil
        directoryContext = nil
        directoryLoading = false
        directories = []
        directoryPath = ""
        directoryError = nil
    }

    var canOpenDirectory: Bool { directoryContextIsCurrent && !directoryLoading && !directoryPath.isEmpty && directoryError == nil }

    func loadDirectory(_ path: String) {
        guard directoryContextIsCurrent, let context = directoryContext else { return }
        let request = WireRequest(method: .directoryList, block: context.block, cwd: path)
        directoryRequest = request.id
        directoryLoading = true
        directories = []
        directoryPath = ""
        directoryError = nil
        send(request, host: context.session.host) { [weak self] reply in
            guard let self, self.directoryRequest == request.id, self.directoryContext == context else { return }
            guard self.directoryContextIsCurrent else { self.palette = nil;return }
            self.directoryRequest = nil
            self.directoryLoading = false
            guard reply.error == nil, let entries = reply.entries, let path = reply.path, !path.isEmpty else {
                self.directoryError = reply.error ?? "This directory is no longer available."
                return
            }
            self.directories = entries
            self.directoryPath = path
        }
    }

    /// Opens a new tab in the listed directory.
    func openDirectory() {
        guard canOpenDirectory, let context = directoryContext else { return }
        let request = WireRequest(method: .windowNew, session: context.session.session, block: context.block, cwd: directoryPath)
        palette = nil
        let host = context.session.host
        perform(request, host: host) { [weak self] in self?.created($0, host: host) }
    }

    // MARK: Creation

    private func created(_ reply: WireMessage, host: String) {
        guard reply.error == nil else { return }
        selectedHost = host
        if let session = reply.session {
            selectedSession = session
            registry.recordUse(SessionKey(host: host, session: session))
        }
        if let window = reply.window {
            selectedDeck = window
            rememberedDecks[SessionKey(host: host, session: selectedSession)] = window
        }
        if let block = reply.block {
            focusedBlock = block
            pendingBlock = block
        }
        palette = nil
        isPeekGestureActive = false
        peek = 0
        requestTerminalFocus()
    }

    /// A new session in this window. The previous session keeps running.
    func newSession(name: String = "", host: String? = nil, parentBlock: String? = nil) {
        let host = host ?? selectedHost
        let parent = parentBlock ?? (host == selectedHost && !focusedBlock.isEmpty ? focusedBlock : nil)
        perform(WireRequest(method: .sessionNew, block: parent, label: name), host: host) { [weak self] in self?.created($0, host: host) }
    }

    func newTab(cwd: String? = nil) {
        guard activeSession != nil else { newSession();return }
        let host = selectedHost
        perform(WireRequest(method: .windowNew, session: selectedSession, block: focusedBlock, cwd: cwd), host: host) { [weak self] in
            self?.created($0, host: host)
        }
    }

    func split(_ axis: SplitAxis, block: String? = nil) {
        let block = block ?? focusedBlock
        guard !block.isEmpty else { return }
        let host = selectedHost
        perform(WireRequest(method: .blockSplit, block: block, axis: axis), host: host) { [weak self] in self?.created($0, host: host) }
    }
}

/// Collects `block.process` answers for a close confirmation. Reports the
/// running jobs, or nil when the answers did not arrive in time.
@MainActor
private final class RunningJobsQuery {
    private var remaining: Set<String>
    private var jobs: [String] = []
    private var finished = false
    var onFinish: (([String]?) -> Void)?

    init(blocks: [String]) { remaining = Set(blocks) }

    func receive(_ process: ChildProcess?, for block: String) {
        guard !finished, remaining.remove(block) != nil else { return }
        if let process, process.isRunningJob { jobs.append(process.jobName) }
        if remaining.isEmpty { finish(jobs) }
    }

    func start(timeout: Duration) {
        if remaining.isEmpty { finish(jobs);return }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(nil)
        }
    }

    private func finish(_ result: [String]?) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
    }
}
