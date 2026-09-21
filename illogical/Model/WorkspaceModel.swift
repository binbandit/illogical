import AppKit
import Combine
import SwiftUI

enum PaletteMode: String, Identifiable { case sessions, commands, themes, directory; var id: String { rawValue } }
enum PaneDirection { case left, right, up, down }

private extension SplitLayout {
    func adjacentBlock(from block: String, direction: PaneDirection) -> String? {
        var panes: [(block: String, rect: CGRect)] = []
        func collect(_ node: SplitLayout, in rect: CGRect) {
            if let block = node.block { panes.append((block, rect));return }
            guard let first = node.first, let second = node.second else { return }
            let supplied = node.ratio ?? 0.5
            let ratio = supplied.isFinite ? max(0, min(1, supplied)) : 0.5
            var firstRect = rect, secondRect = rect
            if node.axis == "horizontal" {
                firstRect.size.width *= ratio
                secondRect.origin.x += firstRect.width;secondRect.size.width -= firstRect.width
            } else {
                firstRect.size.height *= ratio
                secondRect.origin.y += firstRect.height;secondRect.size.height -= firstRect.height
            }
            collect(first, in: firstRect);collect(second, in: secondRect)
        }
        collect(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = panes.first(where: { $0.block == block })?.rect else { return nil }
        let horizontal = direction == .left || direction == .right
        let midpoint = horizontal ? source.midY : source.midX
        let sourceMin = horizontal ? source.minY : source.minX
        let sourceMax = horizontal ? source.maxY : source.maxX
        var best: (block: String, alignment: Int, gap: CGFloat, offset: CGFloat)?
        for candidate in panes where candidate.block != block {
            let rect = candidate.rect
            let gap: CGFloat
            switch direction {
            case .left: gap = source.minX - rect.maxX
            case .right: gap = rect.minX - source.maxX
            case .up: gap = source.minY - rect.maxY
            case .down: gap = rect.minY - source.maxY
            }
            guard gap >= -0.000001 else { continue }
            let lower = horizontal ? rect.minY : rect.minX
            let upper = horizontal ? rect.maxY : rect.maxX
            let alignment = lower <= midpoint && midpoint < upper ? 0 : (min(sourceMax, upper) > max(sourceMin, lower) ? 1 : 2)
            let offset = abs((lower + upper) / 2 - midpoint)
            if let best, (best.alignment, best.gap, best.offset) <= (alignment, max(0, gap), offset) { continue }
            best = (candidate.block, alignment, max(0, gap), offset)
        }
        return best?.block
    }
}

@MainActor
private final class HostProfileStore {
    static let shared = HostProfileStore()
    @Published private(set) var hosts: [HostProfile]

    private init() {
        let saved = UserDefaults.standard.data(forKey: "hosts")
            .flatMap { try? JSONDecoder().decode([HostProfile].self, from: $0) } ?? []
        hosts = [.local] + saved.filter { !$0.isLocal }
    }

    func add(_ host: HostProfile) { save(hosts + [host]) }
    func remove(_ id: String) { save(hosts.filter { $0.id != id || $0.isLocal }) }

    private func save(_ updated: [HostProfile]) {
        guard updated != hosts, let data = try? JSONEncoder().encode(updated.filter { !$0.isLocal }) else { return }
        UserDefaults.standard.set(data, forKey: "hosts")
        hosts = updated
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var hosts: [HostProfile] = [.local]
    @Published var states: [String: WorkspaceState] = [:]
    @Published private(set) var processIdentities: [String: ChildProcess] = [:]
    @Published private(set) var hostFeatures: [String: Set<String>] = [:]
    @Published var statuses: [String: String] = [:]
    @Published var selectedHost = "local"
    @Published var selectedSession = ""
    @Published var selectedDeck = ""
    @Published var focusedBlock = ""
    @Published var focusToken = UUID()
    @Published var palette: PaletteMode? { didSet { if palette != .directory { cancelDirectory() } } }
    @Published var showSettings = false
    @Published var showAddHost = false
    @Published var showRename = false
    @Published var renameTarget = "session"
    @Published var renameValue = ""
    @Published var notice: String?
    @Published var peek: CGFloat = 0 { didSet { if !isPeekGestureActive { peekExpanded = peek >= 1.5 } } }
    @Published private(set) var isPeekGestureActive = false
    @Published private(set) var peekExpanded = false
    private var peekGestureStart: CGFloat = 0
    private var keyboardFocusIntent: UUID?
    @Published var sidebarFilter = ""
    @Published var showPaneTitles: Bool { didSet { preferences.set(showPaneTitles, forKey: "showPaneTitles") } }
    @Published private(set) var searches: [String: TerminalSearchState] = [:]
    @Published var searchFocusedBlock: String?
    @Published private(set) var directories: [DirectoryEntry] = []
    @Published private(set) var directoryPath = ""
    @Published private(set) var directoryLoading = false
    @Published private(set) var directoryError: String?
    @Published var importedThemes: [TerminalTheme] = []
    @Published var migration: [TerminalTheme] = []
    @Published var themeName: String { didSet { preferences.set(themeName,forKey:"theme");applyAppearance() } }
    @Published var followSystemAppearance: Bool {
        didSet { preferences.set(followSystemAppearance, forKey: "followSystemAppearance");applySystemAppearance() }
    }
    @Published var lightThemeName: String {
        didSet { preferences.set(lightThemeName, forKey: "lightTheme");applySystemAppearance() }
    }
    @Published var darkThemeName: String {
        didSet { preferences.set(darkThemeName, forKey: "darkTheme");applySystemAppearance() }
    }
    @Published var verticalTabs: Bool { didSet { preferences.set(verticalTabs,forKey:"verticalTabs") } }
    @Published var density: Density { didSet { preferences.set(density.rawValue,forKey:"density") } }
    @Published var interfaceStyle: InterfaceStyle { didSet { preferences.set(interfaceStyle.rawValue,forKey:"interfaceStyle") } }
    @Published var fontSize: Double { didSet { preferences.set(fontSize,forKey:"fontSize") } }
    @Published var fontName: String { didSet { preferences.set(fontName,forKey:"fontName") } }
    @Published var fontOptions: TerminalFontOptions { didSet { if let data = try? JSONEncoder().encode(fontOptions) { preferences.set(data, forKey: "fontOptions") } } }
    @Published var contrastCorrection: Bool { didSet { preferences.set(contrastCorrection,forKey:"contrastCorrection") } }
    @Published var synchronizeViewports: Bool {
        didSet {
            preferences.set(synchronizeViewports, forKey: "synchronizeViewports")
            for (block, engine) in engines {
                configureViewport(engine, block: block, host: engineHosts[block] ?? selectedHost)
            }
        }
    }
    @Published var copyOnSelection: Bool { didSet { preferences.set(copyOnSelection, forKey: "copyOnSelection") } }
    private let preferences = UserDefaults.standard
    private let hostStore = HostProfileStore.shared
    private var hostObservation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var connections: [String: ServiceConnection] = [:]
    private var engines: [String: TerminalEngine] = [:]
    private var engineHosts: [String: String] = [:]
    private var initialized = Set<String>()
    private var rememberedDecks: [String: [String: String]] = [:]
    private var rememberedBlocks: [String: [String: String]] = [:]
    private struct DirectoryContext: Equatable {
        let host: String
        let session: String
        let deck: String
        let block: String
    }
    private var directoryContext: DirectoryContext?
    private var directoryRequest: String?
    private var started = false
    private var processLookups: [String: Task<Void, Never>] = [:]
    private var processVersions: [String: String] = [:]
    private var pendingBlock: String?
    private var closingBlocks = Set<String>()
    private var pendingPaneNavigation: (host: String, session: String, deck: String, block: String, request: String)?
    private var renameContext: (host: String, session: String, window: String?)?
    var onLaunchStage: ((String) -> Void)?
    var onRequestActivation: (() -> Void)?

    init() {
        let defaults=UserDefaults.standard
        themeName=defaults.string(forKey:"theme") ?? "Merino Dark"
        followSystemAppearance=defaults.bool(forKey:"followSystemAppearance")
        lightThemeName=defaults.string(forKey:"lightTheme") ?? "Merino Light"
        darkThemeName=defaults.string(forKey:"darkTheme") ?? "Merino Dark"
        verticalTabs=defaults.bool(forKey:"verticalTabs")
        showPaneTitles=defaults.object(forKey:"showPaneTitles") as? Bool ?? true
        density=Density(rawValue:defaults.string(forKey:"density") ?? "") ?? .comfortable
        interfaceStyle=InterfaceStyle(rawValue:defaults.string(forKey:"interfaceStyle") ?? "") ?? .themed
        fontSize=defaults.object(forKey:"fontSize") as? Double ?? 13
        fontName=defaults.string(forKey:"fontName") ?? "SF Mono"
        fontOptions=defaults.data(forKey:"fontOptions").flatMap { try? JSONDecoder().decode(TerminalFontOptions.self, from:$0) } ?? .defaults
        contrastCorrection=defaults.object(forKey:"contrastCorrection") as? Bool ?? true
        copyOnSelection=defaults.bool(forKey:"copyOnSelection")
        synchronizeViewports=defaults.bool(forKey:"synchronizeViewports")
        if let data=defaults.data(forKey:"importedThemes"),let themes=try? JSONDecoder().decode([TerminalTheme].self,from:data){importedThemes=themes}
        selectedHost=defaults.string(forKey:"selectedHost") ?? "local"
        selectedSession=defaults.string(forKey:"selectedSession") ?? ""
        selectedDeck=defaults.string(forKey:"selectedDeck") ?? ""
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.applySystemAppearance() }
        }
        hostObservation = hostStore.$hosts.sink { [weak self] in self?.updateHosts($0) }
        applySystemAppearance()
    }

    func applySystemAppearance() {
        guard followSystemAppearance else { return }
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = dark ? darkThemeName : lightThemeName
        guard themes.contains(where: { $0.name == name }), themeName != name else { return }
        themeName = name
    }

    func selectTheme(_ name: String) {
        followSystemAppearance = false;themeName = name
    }

    var themes: [TerminalTheme] { TerminalTheme.builtins+importedThemes }
    var theme: TerminalTheme { themes.first{$0.name==themeName} ?? .merinoDark }
    var activeSession: Session? { states[selectedHost]?.sessions.first{$0.id==selectedSession} }
    var activeDeck: Deck? { activeSession?.windows.first{$0.id==selectedDeck} }
    var activeHost: HostProfile { hosts.first{$0.id==selectedHost} ?? .local }
    var activeEngine: TerminalEngine? { engines[focusedBlock] }
    var currentTitle: String { activeSession?.name ?? "illogical" }

    func start() { guard !started else{return};started=true;for host in hosts{connect(host)} }
    func close() { pendingPaneNavigation = nil;cancelDirectory();for lookup in processLookups.values { lookup.cancel() };processLookups.removeAll();for connection in connections.values{connection.close()};connections.removeAll();started=false }

    private func connect(_ host:HostProfile) {
        onLaunchStage?("connectionStart")
        let connection=ServiceConnection(host:host);connections[host.id]=connection
        statuses[host.id]="Connecting to \(host.name)…"
        connection.onStatus={ [weak self] status in self?.statuses[host.id]=status }
        connection.onSendError = { [weak self] error in self?.notice = error }
        connection.onMessage={ [weak self] message in self?.receive(message,host:host.id) }
        connection.connect()
    }

    private func receive(_ message:WireMessage,host:String) {
        if message.type=="hello" {
            onLaunchStage?("serviceHello")
            guard message.protocol==1,message.engine=="ghostty-27e8b3fa85d9" else{statuses[host]="This host needs the same version of illogical as this Mac.";connections[host]?.close();return}
            statuses[host]=nil
            hostFeatures[host] = Set(message.features ?? [])
            send(WireRequest(method:"watch"),host:host)
            for (id,engineHost) in engineHosts where engineHost==host { send(engines[id]?.attachmentRequest() ?? WireRequest(method:"block.attach",block:id),host:host) }
            if engineHosts[focusedBlock] == host {
                engines[focusedBlock]?.requestedSize = nil
                send(WireRequest(method:"block.claim",block:focusedBlock),host:host)
            }
        }
        if let state=message.state {
            onLaunchStage?("workspaceState")
            refreshProcessIdentities(state, host: host)
            states[host]=state
            if let pending = pendingPaneNavigation, pending.host == host {
                let deck = state.sessions.first { $0.id == pending.session }?.windows.first { $0.id == pending.deck }
                if deck?.zoomed == pending.block, selectedHost == host, selectedSession == pending.session, selectedDeck == pending.deck { focus(pending.block) }
                if deck?.zoomed == pending.block || deck?.root.blocks.contains(pending.block) != true { pendingPaneNavigation = nil }
            }
            let valid=Set(state.blocks.map(\.id))
            if let remembered = rememberedBlocks[host] { rememberedBlocks[host] = remembered.filter { valid.contains($0.value) } }
            discardEngines(engineHosts.compactMap { $0.value == host && !valid.contains($0.key) ? $0.key : nil })
            if !initialized.contains(host) {
                initialized.insert(host)
                if state.sessions.isEmpty && host=="local" { newSession(host:host);return }
            }
            if host==selectedHost {
                if let pendingBlock, valid.contains(pendingBlock) { self.pendingBlock = nil; focus(pendingBlock) }
                if pendingBlock != nil { return }
                if let session=state.sessions.first(where:{$0.id==selectedSession}) {
                    if !session.windows.contains(where:{$0.id==selectedDeck}){selectedDeck=session.windows.first?.id ?? ""}
                    if let deck=activeDeck {
                        let preferred = preferredBlock(in: deck)
                        if focusedBlock != preferred { focus(preferred, explicit: false) }
                    }
                } else if let first=state.sessions.first { choose(session:first.id,host:host,explicit:false) }
                else { selectedSession="";selectedDeck="";focusedBlock="" }
            }
            if palette == .directory && !directoryContextIsCurrent { palette = nil }
        }
        if let block=message.block {
            if message.event == "block_closed", engineHosts[block] == host { retireEngine(block) }
            if ["snapshot","history","output","resize","theme","graphics","resume","resync"].contains(message.type) {
                if message.type == "snapshot" { onLaunchStage?("snapshotReceived") }
                engines[block]?.receive(message)
                if message.type == "snapshot" { onLaunchStage?("snapshotRestored") }
            }
            else if message.type == "viewport", let distance = message.viewport,
                    synchronizeViewports, message.stream == engines[block]?.stream { engines[block]?.receiveViewport(distance) }
            else if message.type=="focus",let session=message.session,let window=message.window {
                choose(deck:window,session:session,host:host);focus(block)
                onRequestActivation?()
            }
            if ["snapshot", "resume"].contains(message.type), let engine = engines[block] {
                configureViewport(engine, block: block, host: host)
            }
            if message.event=="bell",block==focusedBlock{NSSound.beep()}
            if message.event=="desktop_notification"{notice=message.text}
            if message.event=="clipboard_written",block==focusedBlock,let data=message.data,let text=String(data:data,encoding:.utf8){NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
        }
        if let error=message.error,!error.isEmpty{notice=error}
    }

    func send(_ request:WireRequest,host:String?=nil,completion:((WireMessage)->Void)?=nil){connections[host ?? selectedHost]?.send(request,completion:completion)}

    func info(_ block:String,host:String?=nil)->BlockInfo? {
        states[host ?? engineHosts[block] ?? selectedHost]?.blocks.first{$0.id==block}
    }

    private func refreshProcessIdentities(_ state: WorkspaceState, host: String) {
        let valid = Set(state.blocks.map(\.id))
        for block in states[host]?.blocks ?? [] where !valid.contains(block.id) {
            processLookups.removeValue(forKey: block.id)?.cancel();processIdentities.removeValue(forKey: block.id);processVersions.removeValue(forKey: block.id)
        }
        for block in state.blocks {
            let version = "\(block.pid):\(block.title):\(block.cwd)"
            guard processVersions[block.id] != version else { continue }
            processVersions[block.id] = version
            processLookups.removeValue(forKey: block.id)?.cancel()
            processLookups[block.id] = Task { [weak self] in
                // Shell title changes may precede giving the job its foreground
                // process group. Coalesce that transition without polling.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, !self.closingBlocks.contains(block.id), self.processVersions[block.id] == version else { return }
                self.processLookups.removeValue(forKey: block.id)
                self.send(WireRequest(method: "block.process", block: block.id), host: host) { [weak self] message in
                    guard let self, self.processVersions[block.id] == version else { return }
                    if let process = message.process { self.processIdentities[block.id] = process }
                }
            }
        }
    }

    func processIcon(_ block: String, host: String? = nil) -> String {
        guard let process = processIdentities[block] else { return info(block, host: host)?.icon ?? "terminal" }
        if process.foreground == nil, process.foregroundPID != process.pid {
            return info(block, host: host)?.icon ?? "terminal"
        }
        let identity = process.foreground ?? process.child
        let executable = identity?.executable.map { ($0 as NSString).lastPathComponent } ?? identity?.name ?? process.command.first ?? ""
        let name = executable.lowercased()
        if name.contains("vim") || name == "nano" || name.contains("emacs") || name == "hx" { return "curlybraces" }
        if name.contains("claude") || name.contains("codex") || name.contains("aider") { return "sparkle" }
        if name == "top" || name == "htop" || name == "btop" { return "chart.bar.xaxis" }
        if name == "git" || name == "lazygit" { return "point.3.connected.trianglepath.dotted" }
        if name == "ssh" || name == "mosh" { return "network" }
        if name == "python" || name.hasPrefix("python3") { return "chevron.left.forwardslash.chevron.right" }
        return "terminal"
    }

    func deckTitle(_ deck:Deck,host:String?=nil)->String {
        if !deck.name.isEmpty{return deck.name}
        return deck.root.blocks.first.flatMap{info($0,host:host)?.displayTitle} ?? "Terminal"
    }

    func engine(for block:String,host:String?=nil)->TerminalEngine {
        if let engine=engines[block]{return engine}
        let host=host ?? selectedHost
        let engine=TerminalEngine(blockID:block,theme:theme)
        // SwiftUI can reevaluate an outgoing pane after state has deleted it.
        // Give that transient view an inert replica without caching or attaching.
        guard !closingBlocks.contains(block), states[host]?.blocks.contains(where: { $0.id == block }) != false else { return engine }
        engines[block]=engine;engineHosts[block]=host
        engine.onInput={ [weak self] data in
            guard let self, !self.closingBlocks.contains(block) else { return }
            self.send(WireRequest(method:"block.write",block:block,data:data),host:host)
        }
        engine.onResize={ [weak self] cols,rows,width,height in
            guard let self, !self.closingBlocks.contains(block) else { return }
            self.send(WireRequest(method:"block.resize",block:block,cols:cols,rows:rows,cellWidth:width,cellHeight:height),host:host)
        }
        engine.onReplayGap = { [weak self] in
            guard let self, !self.closingBlocks.contains(block) else { return }
            self.send(WireRequest(method: "block.attach", block: block), host: host)
        }
        engine.onError={ [weak self] error in self?.notice=error }
        engine.onSearch={ [weak self] total,index,row in
            self?.searches[block]?.receive(count: total, selected: index, row: row)
        }
        engine.onSearchGeometry = { [weak self] spans in self?.searches[block]?.receive(spans: spans) }
        send(WireRequest(method:"block.attach",block:block),host:host)
        send(WireRequest(method:"block.theme",block:block,theme:theme.wire),host:host)
        return engine
    }

    func supportsViewportSync(host: String? = nil) -> Bool {
        hostFeatures[host ?? selectedHost]?.contains("viewport") == true
    }

    private func configureViewport(_ engine: TerminalEngine, block: String, host: String) {
        guard !closingBlocks.contains(block) else { return }
        guard supportsViewportSync(host: host) else { engine.onViewportChange = nil;return }
        if synchronizeViewports {
            engine.onViewportChange = { [weak self] distance in
                guard let self, !self.closingBlocks.contains(block) else { return }
                self.send(WireRequest(method: "block.viewport", block: block, viewport: distance), host: host)
            }
        } else { engine.onViewportChange = nil }
        send(WireRequest(method: "block.viewport", block: block, synchronized: synchronizeViewports), host: host)
    }

    func choose(session:String,host:String,explicit:Bool = true) {
        pendingPaneNavigation = nil
        selectedHost=host;selectedSession=session
        let available=states[host]?.sessions.first{$0.id==session}?.windows ?? []
        selectedDeck=available.first{$0.id==rememberedDecks[host]?[session]}?.id ?? available.first?.id ?? ""
        palette=nil;isPeekGestureActive=false;peek=0
        saveSelection();focus(activeDeck.map(preferredBlock) ?? "", explicit: explicit)
    }

    func choose(deck:String,session:String?=nil,host:String?=nil) {
        pendingPaneNavigation = nil
        if let host{selectedHost=host};if let session{selectedSession=session}
        selectedDeck=deck;rememberedDecks[selectedHost, default: [:]][selectedSession]=deck
        palette=nil;isPeekGestureActive=false;peek=0
        saveSelection();focus(activeDeck.map(preferredBlock) ?? "")
    }

    func selectAdjacentTab(_ delta: Int) {
        guard delta != 0, let tabs = activeSession?.windows, !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.id == selectedDeck }) else {
            choose(deck: delta > 0 ? tabs[0].id : tabs[tabs.count - 1].id);return
        }
        let next = (current + delta % tabs.count + tabs.count) % tabs.count
        if next != current { choose(deck: tabs[next].id) }
    }

    func selectTab(_ index: Int) {
        guard let tabs = activeSession?.windows, !tabs.isEmpty else { return }
        let selected = index == 8 ? tabs.count - 1 : index
        guard tabs.indices.contains(selected) else { return }
        choose(deck: tabs[selected].id)
    }

    func focusAdjacentPane(_ direction: PaneDirection) {
        guard let deck = activeDeck else { return }
        let source: String
        if let pending = pendingPaneNavigation, pending.host == selectedHost, pending.session == selectedSession, pending.deck == deck.id {
            source = pending.block
        } else { source = focusedBlock }
        guard let target = deck.root.adjacentBlock(from: source, direction: direction) else { return }
        if let zoomed = deck.zoomed, !zoomed.isEmpty {
            let host = selectedHost
            let request = WireRequest(method: "window.zoom", window: deck.id, block: target)
            pendingPaneNavigation = (host, selectedSession, deck.id, target, request.id)
            // Keep focus on the visible pane until the service publishes its new
            // zoom state. Pending intent prevents repeated keys toggling zoom off.
            send(request, host: host) { [weak self] message in
                guard let self, message.error != nil, self.pendingPaneNavigation?.request == request.id else { return }
                self.pendingPaneNavigation = nil
            }
        } else { focus(target) }
    }

    private func preferredBlock(in deck: Deck) -> String {
        let blocks = deck.root.blocks
        if let zoomed = deck.zoomed, blocks.contains(zoomed) { return zoomed }
        if let remembered = rememberedBlocks[selectedHost]?[deck.id], blocks.contains(remembered) { return remembered }
        return blocks.first ?? ""
    }

    func focus(_ block:String, explicit: Bool = true) {
        var block = block
        let host = engineHosts[block] ?? selectedHost
        if !block.isEmpty {
            guard !closingBlocks.contains(block) else { return }
            if let deck = activeDeck {
                guard deck.root.blocks.contains(block) else { return }
            } else {
                guard states[host]?.blocks.contains(where: { $0.id == block }) != false else { return }
            }
        }
        if let deck = activeDeck, deck.root.blocks.contains(block) {
            if let zoomed = deck.zoomed, deck.root.blocks.contains(zoomed) { block = zoomed }
            rememberedBlocks[selectedHost, default: [:]][deck.id] = block
        }
        searchFocusedBlock = nil
        focusedBlock=block;focusToken=UUID();engines[block]?.requestedSize = nil
        keyboardFocusIntent = explicit ? focusToken : nil
        if palette == .directory && !directoryContextIsCurrent { palette = nil }
        guard !block.isEmpty else { return }
        send(WireRequest(method:"block.claim",block:block),host:engineHosts[block] ?? selectedHost)
    }

    func consumeKeyboardFocusIntent(_ token: UUID?) -> Bool {
        guard let token, token == keyboardFocusIntent else { return false }
        keyboardFocusIntent = nil
        return true
    }

    private func saveSelection(){preferences.set(selectedHost,forKey:"selectedHost");preferences.set(selectedSession,forKey:"selectedSession");preferences.set(selectedDeck,forKey:"selectedDeck")}

    private func created(_ message:WireMessage,host:String) {
        guard message.error==nil else{return}
        selectedHost=host
        if let session=message.session{selectedSession=session}
        if let window=message.window{selectedDeck=window;rememberedDecks[host, default: [:]][selectedSession]=window}
        if let block=message.block{focusedBlock=block;pendingBlock=block}
        saveSelection();palette=nil;isPeekGestureActive=false;peek=0;focusToken=UUID();keyboardFocusIntent=focusToken
    }

    func newSession(name:String="",host:String?=nil) {
        let host=host ?? selectedHost
        send(WireRequest(method:"session.new",label:name),host:host){ [weak self] in self?.created($0,host:host) }
    }
    func newTab(cwd:String?=nil) {
        guard activeSession != nil else{newSession();return}
        let host=selectedHost
        send(WireRequest(method:"window.new",session:selectedSession,block:focusedBlock,cwd:cwd),host:host){ [weak self] in self?.created($0,host:host) }
    }
    func split(_ axis:String,block:String?=nil) {
        let host=selectedHost
        send(WireRequest(method:"block.split",block:block ?? focusedBlock,axis:axis),host:host){ [weak self] in self?.created($0,host:host) }
    }
    func closeBlock(_ block: String? = nil) {
        let block = block ?? focusedBlock
        let host = engineHosts[block] ?? selectedHost
        guard !block.isEmpty, let connection = connections[host], closingBlocks.insert(block).inserted else { return }
        processLookups.removeValue(forKey: block)?.cancel()
        connection.send(WireRequest(method: "block.kill", block: block)) { [weak self] message in
            guard let self, message.error != nil else { return }
            self.closingBlocks.remove(block)
            self.engines[block]?.requestedSize = nil
            self.processVersions.removeValue(forKey: block)
            if let state = self.states[host] { self.refreshProcessIdentities(state, host: host) }
        }
    }
    func closeDeck(_ deck:String){send(WireRequest(method:"window.kill",window:deck))}
    func killSession(_ session:String,host:String){send(WireRequest(method:"session.kill",session:session),host:host)}
    func zoom(_ block:String?=nil){send(WireRequest(method:"window.zoom",window:selectedDeck,block:block ?? focusedBlock))}
    func move(_ block:String,to target:String,axis:String){send(WireRequest(method:"block.move",block:block,target:target,axis:axis)){[weak self] in self?.created($0,host:self?.selectedHost ?? "local")}}
    func resizeSplit(_ id:String,ratio:Double,deck:String){send(WireRequest(method:"layout.resize",window:deck,target:id,ratio:ratio))}

    func rename(_ target: String) {
        if target == "session" { rename(session: selectedSession, host: selectedHost); return }
        guard target == "window", let deck = activeDeck else { return }
        renameContext = (selectedHost, selectedSession, deck.id)
        renameTarget = "window";renameValue = deckTitle(deck);palette = nil;showRename = true
    }

    func rename(session: String, host: String) {
        guard let session = states[host]?.sessions.first(where: { $0.id == session }) else { return }
        renameContext = (host, session.id, nil)
        renameTarget = "session";renameValue = session.name;palette = nil;showRename = true
    }

    var canRename: Bool { !renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func cancelRename() {
        showRename = false;renameContext = nil;focusToken = UUID()
    }

    func finishRename() {
        let name = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let context = renameContext else { return }
        guard let session = states[context.host]?.sessions.first(where: { $0.id == context.session }),
              context.window == nil || session.windows.contains(where: { $0.id == context.window }) else {
            notice = context.window == nil ? "This session is no longer available." : "This tab is no longer available."
            cancelRename();return
        }
        send(WireRequest(method: context.window == nil ? "session.rename" : "window.rename", session: context.session, window: context.window, label: name), host: context.host)
        cancelRename()
    }
    func find() {
        guard !focusedBlock.isEmpty else { return }
        if searches[focusedBlock] == nil { searches[focusedBlock] = TerminalSearchState() }
        searchFocusedBlock = focusedBlock
        searches[focusedBlock]?.focusToken = UUID()
    }
    func focusSearch(_ block: String) {
        guard searches[block] != nil else { return }
        if focusedBlock != block { focus(block) }
        searchFocusedBlock = block
    }
    func updateSearch(_ block: String, direction: Int32 = 0) {
        guard let search = searches[block] else { return }
        engines[block]?.search(search.query, direction: direction)
    }
    func closeSearch(_ block: String) {
        engines[block]?.search("")
        searches.removeValue(forKey: block)
        if searchFocusedBlock == block { searchFocusedBlock = nil; focusToken = UUID() }
    }
    func setPeek(_ progress: CGFloat, finished: Bool) {
        guard progress.isFinite else { return }
        let progress = min(2, max(0, progress))
        if finished {
            let start = isPeekGestureActive ? peekGestureStart : peek
            let closeThreshold: CGFloat = start == 0 ? 0.3 : 0.55
            let expandThreshold: CGFloat = start == 2 ? 1.4 : 1.6
            let target: CGFloat = progress < closeThreshold ? 0 : (progress < expandThreshold ? 1 : 2)
            animateNavigation { isPeekGestureActive = false;peek = target }
            if target == 0 { focusToken = UUID();keyboardFocusIntent = focusToken }
        } else {
            if !isPeekGestureActive { peekGestureStart = peek;isPeekGestureActive = true }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { peek = progress }
        }
    }

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
    func showDirectory() {
        cancelDirectory()
        guard let deck = activeDeck, deck.root.blocks.contains(focusedBlock) else { return }
        directoryContext = DirectoryContext(host: selectedHost, session: selectedSession, deck: deck.id, block: focusedBlock)
        palette = .directory
        loadDirectory("")
    }

    private var directoryContextIsCurrent: Bool {
        guard let context = directoryContext, palette == .directory,
              context.host == selectedHost, context.session == selectedSession,
              context.deck == selectedDeck, context.block == focusedBlock,
              hosts.contains(where: { $0.id == context.host }),
              states[context.host]?.blocks.contains(where: { $0.id == context.block }) == true,
              activeDeck?.root.blocks.contains(context.block) == true else { return false }
        return true
    }

    var canOpenDirectory: Bool { directoryContextIsCurrent && !directoryLoading && !directoryPath.isEmpty && directoryError == nil }

    private func cancelDirectory() {
        guard directoryContext != nil || directoryRequest != nil || directoryLoading ||
                !directories.isEmpty || !directoryPath.isEmpty || directoryError != nil else { return }
        directoryRequest = nil;directoryContext = nil;directoryLoading = false
        directories = [];directoryPath = "";directoryError = nil
    }

    func loadDirectory(_ path: String) {
        guard directoryContextIsCurrent, let context = directoryContext else { return }
        let request = WireRequest(method: "directory.list", block: context.block, cwd: path)
        directoryRequest = request.id;directoryLoading = true
        directories = [];directoryPath = "";directoryError = nil
        send(request, host: context.host) { [weak self] message in
            guard let self, self.directoryRequest == request.id, self.directoryContext == context else { return }
            guard self.directoryContextIsCurrent else { self.palette = nil;return }
            self.directoryRequest = nil;self.directoryLoading = false
            guard message.error == nil, let entries = message.entries, let path = message.path, !path.isEmpty else {
                self.directoryError = message.error ?? "This directory is no longer available."
                return
            }
            self.directories = entries;self.directoryPath = path
        }
    }

    func openDirectory() {
        guard canOpenDirectory, let context = directoryContext else { return }
        let request = WireRequest(method: "window.new", session: context.session, block: context.block, cwd: directoryPath)
        palette = nil
        send(request, host: context.host) { [weak self] in self?.created($0, host: context.host) }
    }

    func applyAppearance(){
        let theme=theme
        for (id,engine) in engines{engine.applyTheme(theme);send(WireRequest(method:"block.theme",block:id,theme:theme.wire),host:engineHosts[id])}
    }

    func addHost(name:String,address:String,executable:String){
        let trimmed=address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.range(of:"^[A-Za-z0-9_.@:\\[\\]-]+$",options:.regularExpression) != nil,!trimmed.hasPrefix("-") else{notice="Enter a hostname, SSH alias, or user@host.";return}
        let profile=HostProfile(id:UUID().uuidString,name:name.isEmpty ? trimmed : name,address:trimmed,executable:executable.isEmpty ? "illogical" : executable)
        hostStore.add(profile);showAddHost=false
    }
    func removeHost(_ host:HostProfile){
        guard !host.isLocal else{return}
        hostStore.remove(host.id)
    }

    private func updateHosts(_ updated: [HostProfile]) {
        let removed = hosts.filter { old in !updated.contains(where: { $0.id == old.id }) }
        let added = updated.filter { new in !hosts.contains(where: { $0.id == new.id }) }
        hosts = updated
        for host in removed { disconnectHost(host) }
        if started { for host in added { connect(host) } }
    }

    private func disconnectHost(_ host: HostProfile) {
        connections[host.id]?.close();connections.removeValue(forKey:host.id)
        discardEngines(Array(Set(engineHosts.compactMap { $0.value == host.id ? $0.key : nil } + (states[host.id]?.blocks.map(\.id) ?? []))))
        rememberedDecks.removeValue(forKey: host.id);rememberedBlocks.removeValue(forKey: host.id)
        initialized.remove(host.id)
        states.removeValue(forKey:host.id);statuses.removeValue(forKey:host.id);hostFeatures.removeValue(forKey:host.id)
        if selectedHost == host.id { choose(session: states["local"]?.sessions.first?.id ?? "", host: "local") }
    }
    private func discardEngines(_ blocks:[String]) {
        guard !blocks.isEmpty else{return}
        for block in blocks { retireEngine(block) }
        for block in blocks { closeSearch(block) }
        if let pendingBlock,blocks.contains(pendingBlock){self.pendingBlock=nil}
        for block in blocks { engines.removeValue(forKey:block);engineHosts.removeValue(forKey:block);processLookups.removeValue(forKey:block)?.cancel();processIdentities.removeValue(forKey:block);processVersions.removeValue(forKey:block);closingBlocks.remove(block) }
    }

    private func retireEngine(_ block: String) {
        // AppKit may lay out or resign focus on a view retained through SwiftUI
        // teardown. A removed terminal must stop submitting service requests.
        guard let engine = engines[block] else { return }
        engine.onInput = nil;engine.onResize = nil;engine.onReplayGap = nil;engine.onViewportChange = nil
        processLookups.removeValue(forKey: block)?.cancel()
    }

    func importGhostty(){
        do { migration=try GhosttyThemeImporter.importConfiguration() }
        catch { notice=error.localizedDescription }
    }
    func importGhosttyFont(){
        do {
            let entries = try GhosttyThemeImporter.configurationEntries()
            if let name = entries.last(where: { $0.0 == "font-family" })?.1, !name.isEmpty { fontName = name }
            if let value = entries.last(where: { $0.0 == "font-size" })?.1, let size = Double(value), size.isFinite, (6...72).contains(size) { fontSize = size }
            fontOptions = TerminalFontOptions.importGhostty(entries: entries)
        } catch { notice = error.localizedDescription }
    }
    func useMigratedThemes(){
        let themes=migration;guard !themes.isEmpty else{return}
        importedThemes.removeAll{old in themes.contains{$0.name==old.name}};importedThemes.append(contentsOf:themes)
        if let data=try? JSONEncoder().encode(importedThemes){preferences.set(data,forKey:"importedThemes")}
        if let light = themes.first(where: \.isLight), let dark = themes.first(where: { !$0.isLight }) {
            lightThemeName = light.name;darkThemeName = dark.name
            followSystemAppearance = true;applySystemAppearance()
        } else { selectTheme(themes[0].name) }
        migration=[]
    }
}
