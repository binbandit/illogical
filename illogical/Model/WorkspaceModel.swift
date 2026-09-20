import AppKit
import Combine
import SwiftUI

enum PaletteMode: String, Identifiable { case sessions, commands, themes, directory; var id: String { rawValue } }

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var hosts: [HostProfile] = [.local]
    @Published var states: [String: WorkspaceState] = [:]
    @Published private(set) var processIdentities: [String: ChildProcess] = [:]
    @Published private(set) var hostFeatures: [String: Set<String>] = [:]
    @Published var statuses: [String: String] = [:]
    @Published var selectedHost = "local"
    @Published var selectedSession = ""
    @Published var selectedDeck = ""
    @Published var focusedBlock = ""
    @Published var focusToken = UUID()
    @Published var palette: PaletteMode?
    @Published var showSettings = false
    @Published var showAddHost = false
    @Published var showRename = false
    @Published var renameTarget = "session"
    @Published var renameValue = ""
    @Published var notice: String?
    @Published var peek: CGFloat = 0
    @Published var sidebarFilter = ""
    @Published var showPaneTitles: Bool { didSet { preferences.set(showPaneTitles, forKey: "showPaneTitles") } }
    @Published private(set) var searches: [String: TerminalSearchState] = [:]
    @Published var searchFocusedBlock: String?
    @Published var directories: [DirectoryEntry] = []
    @Published var directoryPath = ""
    @Published var directoryLoading = false
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
    private var appearanceObservation: NSKeyValueObservation?
    private var connections: [String: ServiceConnection] = [:]
    private var engines: [String: TerminalEngine] = [:]
    private var engineHosts: [String: String] = [:]
    private var initialized = Set<String>()
    private var rememberedDecks: [String: String] = [:]
    private var directoryRequest: String?
    private var started = false
    private var processLookups: [String: Task<Void, Never>] = [:]
    private var processVersions: [String: String] = [:]
    private var pendingBlock: String?
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
        if let data=defaults.data(forKey:"hosts"),let saved=try? JSONDecoder().decode([HostProfile].self,from:data){hosts=[.local]+saved.filter{!$0.isLocal}}
        if let data=defaults.data(forKey:"importedThemes"),let themes=try? JSONDecoder().decode([TerminalTheme].self,from:data){importedThemes=themes}
        selectedHost=defaults.string(forKey:"selectedHost") ?? "local"
        selectedSession=defaults.string(forKey:"selectedSession") ?? ""
        selectedDeck=defaults.string(forKey:"selectedDeck") ?? ""
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.applySystemAppearance() }
        }
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
    func close() { for lookup in processLookups.values { lookup.cancel() };processLookups.removeAll();for connection in connections.values{connection.close()};connections.removeAll();started=false }

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
            let valid=Set(state.blocks.map(\.id))
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
                    if let deck=activeDeck,!deck.root.blocks.contains(focusedBlock){focus(deck.root.blocks.first ?? "")}
                } else if let first=state.sessions.first { choose(session:first.id,host:host) }
                else { selectedSession="";selectedDeck="";focusedBlock="" }
            }
        }
        if let block=message.block {
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
                guard !Task.isCancelled, let self, self.processVersions[block.id] == version else { return }
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
        engines[block]=engine;engineHosts[block]=host
        engine.onInput={ [weak self] data in self?.send(WireRequest(method:"block.write",block:block,data:data),host:host) }
        engine.onResize={ [weak self] cols,rows,width,height in self?.send(WireRequest(method:"block.resize",block:block,cols:cols,rows:rows,cellWidth:width,cellHeight:height),host:host) }
        engine.onReplayGap = { [weak self] in self?.send(WireRequest(method: "block.attach", block: block), host: host) }
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
        guard supportsViewportSync(host: host) else { engine.onViewportChange = nil;return }
        if synchronizeViewports {
            engine.onViewportChange = { [weak self] distance in
                self?.send(WireRequest(method: "block.viewport", block: block, viewport: distance), host: host)
            }
        } else { engine.onViewportChange = nil }
        send(WireRequest(method: "block.viewport", block: block, synchronized: synchronizeViewports), host: host)
    }

    func choose(session:String,host:String) {
        selectedHost=host;selectedSession=session
        let available=states[host]?.sessions.first{$0.id==session}?.windows ?? []
        selectedDeck=available.first{$0.id==rememberedDecks[session]}?.id ?? available.first?.id ?? ""
        focusedBlock=activeDeck?.root.blocks.first ?? "";palette=nil;peek=0
        saveSelection();focus(focusedBlock)
    }

    func choose(deck:String,session:String?=nil,host:String?=nil) {
        if let host{selectedHost=host};if let session{selectedSession=session}
        selectedDeck=deck;rememberedDecks[selectedSession]=deck
        focusedBlock=activeDeck?.root.blocks.first ?? "";palette=nil;peek=0
        saveSelection();focus(focusedBlock)
    }

    func focus(_ block:String) {
        guard !block.isEmpty else{return}
        searchFocusedBlock = nil
        focusedBlock=block;focusToken=UUID();engines[block]?.requestedSize = nil
        send(WireRequest(method:"block.claim",block:block),host:engineHosts[block] ?? selectedHost)
    }

    private func saveSelection(){preferences.set(selectedHost,forKey:"selectedHost");preferences.set(selectedSession,forKey:"selectedSession");preferences.set(selectedDeck,forKey:"selectedDeck")}

    private func created(_ message:WireMessage,host:String) {
        guard message.error==nil else{return}
        selectedHost=host
        if let session=message.session{selectedSession=session}
        if let window=message.window{selectedDeck=window;rememberedDecks[selectedSession]=window}
        if let block=message.block{focusedBlock=block;pendingBlock=block}
        saveSelection();palette=nil;peek=0;focusToken=UUID()
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
    func closeBlock(_ block:String?=nil){send(WireRequest(method:"block.kill",block:block ?? focusedBlock))}
    func closeDeck(_ deck:String){send(WireRequest(method:"window.kill",window:deck))}
    func killSession(_ session:String,host:String){send(WireRequest(method:"session.kill",session:session),host:host)}
    func zoom(_ block:String?=nil){send(WireRequest(method:"window.zoom",window:selectedDeck,block:block ?? focusedBlock))}
    func move(_ block:String,to target:String,axis:String){send(WireRequest(method:"block.move",block:block,target:target,axis:axis)){[weak self] in self?.created($0,host:self?.selectedHost ?? "local")}}
    func resizeSplit(_ id:String,ratio:Double,deck:String){send(WireRequest(method:"layout.resize",window:deck,target:id,ratio:ratio))}

    func rename(_ target:String){renameTarget=target;renameValue=target=="session" ? activeSession?.name ?? "" : activeDeck.map{deckTitle($0)} ?? "";showRename=true}
    func finishRename(){
        let name=renameValue.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else{return}
        send(WireRequest(method:renameTarget+".rename",session:selectedSession,window:selectedDeck,label:name));showRename=false
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
    func setPeek(_ progress:CGFloat,finished:Bool){
        if finished { animateNavigation { peek=progress<0.3 ? 0 : (progress<1.35 ? 1 : 2) } }
        else { peek=progress }
    }
    func animateNavigation(_ change: () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var transaction = Transaction(animation: reduceMotion ? nil : .snappy(duration: 0.24))
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction, change)
    }
    func togglePeek(_ level: CGFloat) { animateNavigation { peek = peek == level ? 0 : level } }
    func showDirectory(){palette = .directory;loadDirectory("")}
    func loadDirectory(_ path:String){
        let request=WireRequest(method:"directory.list",block:focusedBlock,cwd:path);directoryRequest=request.id;directoryLoading=true
        send(request){[weak self] message in
            guard let self,self.directoryRequest==request.id else{return};self.directoryLoading=false
            if let entries=message.entries{self.directories=entries;self.directoryPath=message.path ?? path}
        }
    }

    func applyAppearance(){
        let theme=theme
        for (id,engine) in engines{engine.applyTheme(theme);send(WireRequest(method:"block.theme",block:id,theme:theme.wire),host:engineHosts[id])}
    }

    func addHost(name:String,address:String,executable:String){
        let trimmed=address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.range(of:"^[A-Za-z0-9_.@:\\[\\]-]+$",options:.regularExpression) != nil,!trimmed.hasPrefix("-") else{notice="Enter a hostname, SSH alias, or user@host.";return}
        let profile=HostProfile(id:UUID().uuidString,name:name.isEmpty ? trimmed : name,address:trimmed,executable:executable.isEmpty ? "illogical" : executable)
        hosts.append(profile);persistHosts();connect(profile);showAddHost=false
    }
    func removeHost(_ host:HostProfile){
        guard !host.isLocal else{return}
        connections[host.id]?.close();connections.removeValue(forKey:host.id)
        discardEngines(Array(Set(engineHosts.compactMap { $0.value == host.id ? $0.key : nil } + (states[host.id]?.blocks.map(\.id) ?? []))))
        for session in states[host.id]?.sessions ?? [] { rememberedDecks.removeValue(forKey:session.id) }
        initialized.remove(host.id)
        states.removeValue(forKey:host.id);statuses.removeValue(forKey:host.id);hostFeatures.removeValue(forKey:host.id);hosts.removeAll{$0.id==host.id};persistHosts()
        if selectedHost==host.id{selectedHost="local";if let session=states["local"]?.sessions.first{choose(session:session.id,host:"local")}}
    }
    private func discardEngines(_ blocks:[String]) {
        guard !blocks.isEmpty else{return}
        for block in blocks { closeSearch(block) }
        if let pendingBlock,blocks.contains(pendingBlock){self.pendingBlock=nil}
        for block in blocks { engines.removeValue(forKey:block);engineHosts.removeValue(forKey:block);processLookups.removeValue(forKey:block)?.cancel();processIdentities.removeValue(forKey:block);processVersions.removeValue(forKey:block) }
    }
    private func persistHosts(){if let data=try? JSONEncoder().encode(hosts.filter{!$0.isLocal}){preferences.set(data,forKey:"hosts")}}

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

struct WorkspaceFocusKey: FocusedValueKey { typealias Value = WorkspaceModel }
extension FocusedValues { var workspace: WorkspaceModel? { get{self[WorkspaceFocusKey.self]} set{self[WorkspaceFocusKey.self]=newValue} } }
