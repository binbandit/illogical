import AppKit

struct TerminalSearchSpan: Equatable {
    let row: Int
    let startColumn: Int
    let endColumn: Int
}

struct TerminalGraphicsState {
    var generation: UInt64 = 0
    var cellWidth: UInt32 = 1
    var cellHeight: UInt32 = 1
    var images: [UInt32: WireGraphicsImage] = [:]
    var placements: [WireGraphicsPlacement] = []

    // Match the service's bounded static image scene. Validate the entire
    // transaction before replacing displayed state or retaining pixel blobs.
    mutating func apply(_ update: WireGraphicsState) -> Bool {
        guard update.cellWidth > 0, update.cellHeight > 0, update.placements.count <= 1_024, update.images.count <= 1_024 else { return false }
        var next = update.reset ? [:] : images
        var updated: Set<UInt32> = []
        for image in update.images {
            let components: Int
            switch image.format { case 0: components = 3; case 1: components = 4; case 3: components = 2; case 4: components = 1; default: return false }
            guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
                  image.generation > 0, updated.insert(image.id).inserted,
                  image.data.count == Int(image.width) * Int(image.height) * components else { return false }
            next[image.id] = image
        }
        var referenced: Set<UInt32> = []
        for placement in update.placements {
            guard let image = next[placement.imageID], image.generation == placement.imageGeneration,
                  placement.row >= -Int64(UInt32.max), placement.row <= Int64(UInt32.max),
                  UInt64(placement.sourceX) + UInt64(placement.sourceWidth) <= UInt64(image.width),
                  UInt64(placement.sourceY) + UInt64(placement.sourceHeight) <= UInt64(image.height) else { return false }
            referenced.insert(placement.imageID)
        }
        next = next.filter { referenced.contains($0.key) }
        guard next.values.reduce(0, { $0 + $1.data.count }) <= 8 * 1_024 * 1_024 else { return false }
        generation = update.generation; cellWidth = update.cellWidth; cellHeight = update.cellHeight
        images = next
        placements = update.placements.sorted {
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.imageID != $1.imageID { return $0.imageID < $1.imageID }
            return $0.id < $1.id
        }
        return true
    }
}

@MainActor
final class TerminalEngine {
    let blockID: String
    private(set) var handle: OpaquePointer?
    private(set) var stream: String?
    private(set) var loadingHistory = false
    private(set) var replayID: String?
    private(set) var sequence: UInt64?
    private(set) var graphics = TerminalGraphicsState()
    private var canResume = false
    var onReplayGap: (() -> Void)?
    var onViewportChange: ((UInt64) -> Void)?
    var onInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16, UInt32, UInt32) -> Void)?
    var onError: ((String) -> Void)?
    var onSearch: ((Int, Int, Int) -> Void)?
    var onSearchGeometry: (([TerminalSearchSpan]) -> Void)? { didSet { searchGeometryNeedsPublish = true } }
    var observers: [UUID: () -> Void] = [:]
    var theme: TerminalTheme
    var columns: UInt16 = 100
    var rows: UInt16 = 30
    var requestedSize: (UInt16, UInt16)?
    private var requestedCellSize: (UInt32, UInt32)?
    private var lastSearch = ""
    private var serviceTheme: WireTheme?
    private var hasKeyboardFocus = false
    private var lastSearchSpans: [TerminalSearchSpan] = []
    private var searchGeometryNeedsPublish = true
    private var renderHoldTask: Task<Void, Never>?
    private var correctionView: ILTerminalViewState?

    init(blockID: String, theme: TerminalTheme) {
        self.blockID = blockID; self.theme = theme
        handle = il_terminal_new(columns, rows)
        applyTheme(theme)
    }

    isolated deinit { renderHoldTask?.cancel(); il_terminal_free(handle) }

    func attachmentRequest() -> WireRequest {
        WireRequest(method: "block.attach", block: blockID,
                    replayID: canResume ? replayID : nil, sequence: canResume ? sequence : nil)
    }

    private func invalidateReplay() {
        canResume = false;replayID = nil;sequence = nil;stream = nil
    }

    private func acceptMutation(_ message: WireMessage) -> Bool {
        guard message.stream == stream else { return false }
        guard let next = message.sequence, let epoch = message.replayID else { return true }
        if message.type == "theme", message.previousSequence == nil, epoch == replayID, next == sequence { return true }
        if message.type == "graphics", message.graphics?.reset == true, message.previousSequence == nil, epoch == replayID, next == sequence { return true }
        if epoch == replayID, let sequence, next <= sequence { return false }
        guard epoch == replayID, let current = sequence, message.previousSequence == current else {
            invalidateReplay();onReplayGap?();return false
        }
        sequence = next
        return true
    }

    func receive(_ message: WireMessage) {
        if message.type == "resync" { invalidateReplay();return }
        if message.type == "resume" {
            guard canResume, message.replayID == replayID, message.sequence == sequence else {
                invalidateReplay();onReplayGap?();return
            }
            stream = message.stream
            return
        }
        if message.type == "snapshot", let data = message.data {
            var preserved: ILTerminalViewState?
            if message.text == "graphics" {
                if let correctionView { preserved = correctionView }
                else {
                    var state = ILTerminalViewState()
                    if il_terminal_capture_view(handle, &state) { preserved = state }
                }
            }
            let restored = data.withUnsafeBytes { bytes in
                il_terminal_restore(bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            guard let restored else { invalidateReplay();onError?("Could not restore the terminal snapshot."); return }
            il_terminal_free(handle); handle = restored; stream = message.stream
            correctionView = preserved
            graphics = TerminalGraphicsState()
            replayID = message.replayID;sequence = message.sequence;canResume = false
            columns = message.cols ?? columns; rows = message.rows ?? rows
            requestedSize = nil; loadingHistory = true
            if !lastSearch.isEmpty {
                lastSearch.withCString { il_terminal_search(handle, $0, lastSearch.utf8.count, 1) }
            }
            if let serviceTheme { applyServiceTheme(serviceTheme) }
            else { applyTheme(theme) }
            if let preserved { il_terminal_restore_view(handle, [preserved]) }
        } else if message.type == "history", let data = message.data {
            guard message.stream == stream else { return }
            let result = data.withUnsafeBytes { il_terminal_history(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count, message.final ?? false) }
            if result != 0 { invalidateReplay();onError?("Could not restore terminal history (\(result)).");return }
            if let correctionView { il_terminal_restore_view(handle, [correctionView]) }
            if message.final == true { loadingHistory = false;canResume = replayID != nil && sequence != nil }
            if message.final == true { correctionView = nil }
        } else if ["output", "resize", "theme", "graphics"].contains(message.type) {
            guard acceptMutation(message) else { return }
            if message.type == "output", let data = message.data {
                data.withUnsafeBytes { il_terminal_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
            } else if message.type == "resize", let cols = message.cols, let rows = message.rows {
                resizeFromServer(columns: cols, rows: rows)
            } else if message.type == "theme", let theme = message.theme {
                applyServiceTheme(theme)
            } else if message.type == "graphics" {
                guard let update = message.graphics, graphics.apply(update) else {
                    invalidateReplay(); onError?("Could not restore terminal images."); onReplayGap?(); return
                }
            }
        } else { return }
        notify()
    }

    func resizeFromServer(columns: UInt16, rows: UInt16) {
        self.columns = columns; self.rows = rows
        il_terminal_resize(handle, columns, rows, 0, 0); notify()
    }

    func requestResize(columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard stream != nil, columns > 1, rows > 0 else { return }
        guard requestedSize?.0 != columns || requestedSize?.1 != rows || requestedCellSize?.0 != cellWidth || requestedCellSize?.1 != cellHeight else { return }
        requestedSize = (columns, rows);requestedCellSize = (cellWidth, cellHeight)
        onResize?(columns, rows, cellWidth, cellHeight)
    }

    func frame() -> ILFrame? {
        var frame = ILFrame()
        guard il_terminal_frame(handle, &frame) else { return nil }
        columns = frame.columns; rows = frame.rows
        if !lastSearch.isEmpty {
            onSearch?(Int(frame.searchCount), Int(frame.searchSelected), Int(frame.searchRow))
            if let onSearchGeometry {
                var spans: [TerminalSearchSpan] = []
                if let cells = frame.cells {
                    var index = 0
                    while index < frame.count {
                        let cell = cells[index]
                        guard cell.flags & 128 != 0 else { index += 1; continue }
                        var end = Int(cell.column)
                        index += 1
                        while index < frame.count, cells[index].row == cell.row, cells[index].flags & 128 != 0 {
                            end = Int(cells[index].column); index += 1
                        }
                        spans.append(TerminalSearchSpan(row: Int(cell.row), startColumn: Int(cell.column), endColumn: end))
                    }
                }
                if searchGeometryNeedsPublish || spans != lastSearchSpans {
                    searchGeometryNeedsPublish = false; lastSearchSpans = spans; onSearchGeometry(spans)
                }
            }
        }
        return frame
    }

    func applyTheme(_ theme: TerminalTheme) {
        serviceTheme = nil
        self.theme = theme
        theme.palette.withUnsafeBufferPointer { il_terminal_theme(handle, theme.background, theme.foreground, theme.accent, $0.baseAddress) }
        notify()
    }

    func applyServiceTheme(_ wire: WireTheme) {
        let palette = wire.palette ?? []
        guard [wire.background, wire.foreground, wire.cursor].compactMap({ $0 }).allSatisfy({ $0 <= 0xffffff }),
              (palette.isEmpty || palette.count == 256), palette.allSatisfy({ $0 <= 0xffffff }) else {
            onError?("Could not apply an invalid terminal theme.")
            return
        }
        serviceTheme = wire
        var bg = wire.background ?? 0, fg = wire.foreground ?? 0xffffff, cursor = wire.cursor ?? fg
        withUnsafePointer(to: &bg) { b in
            withUnsafePointer(to: &fg) { f in
                withUnsafePointer(to: &cursor) { c in
                    palette.withUnsafeBufferPointer { p in
                        il_terminal_theme_override(handle, wire.background == nil ? nil : b, wire.foreground == nil ? nil : f,
                                                   wire.cursor == nil ? nil : c, palette.isEmpty ? nil : p.baseAddress)
                    }
                }
            }
        }
        var defaults = [UInt32](repeating: 0, count: 256)
        if il_terminal_default_palette(handle, &defaults) { theme.ansi = Array(defaults.prefix(16));theme.extendedPalette = Array(defaults.dropFirst(16)) }
        theme.name = "Service Theme"
        theme.background = bg; theme.foreground = fg; theme.accent = cursor
        theme.isLight = 299 * (bg >> 16 & 255) + 587 * (bg >> 8 & 255) + 114 * (bg & 255) > 127_500
        notify()
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        correctionView = nil
        let publishBottom = onViewportChange != nil && il_terminal_scroll_distance(handle) > 0
        il_terminal_scroll_bottom(handle)
        if publishBottom { onViewportChange?(0) }
        onInput?(data); notify()
    }

    func key(_ event: NSEvent, text: String? = nil, release: Bool = false) {
        let isCharacterEvent = event.type == .keyDown || event.type == .keyUp
        var translated = text ?? (isCharacterEvent ? event.characters : nil) ?? ""
        // AppKit has already turned Control-C into ETX. Ghostty needs the
        // printable layout character and applies the terminal's own key mode.
        if translated.unicodeScalars.count == 1, let scalar = translated.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7f {
            translated = isCharacterEvent
                ? event.characters(byApplyingModifiers: event.modifierFlags.subtracting([.control, .command])) ?? ""
                : ""
        }
        let filtered = Self.keyText(translated)
        var buffer = [CChar](repeating: 0, count: max(512, filtered.utf8.count + 128))
        let mods = Self.modifiers(event.modifierFlags)
        let consumed = filtered.isEmpty ? 0 : Self.modifiers(event.modifierFlags.subtracting([.control, .command]))
        let unshifted = isCharacterEvent ? Self.keyText(event.characters(byApplyingModifiers: []) ?? "") : ""
        let written = filtered.withCString {
            il_terminal_key(handle, event.keyCode, mods, consumed, release ? 0 : (isCharacterEvent && event.isARepeat ? 2 : 1), $0, filtered.utf8.count,
                            unshifted.unicodeScalars.count == 1 ? unshifted.unicodeScalars.first!.value : 0, &buffer, buffer.count)
        }
        if written > 0 { send(Data(bytes: buffer, count: written)) }
    }

    private static func keyText(_ text: String) -> String {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return text }
        return scalar.value < 0x20 || scalar.value == 0x7f || (0xf700...0xf8ff).contains(scalar.value) ? "" : text
    }

    func paste(_ text: String) {
        var input = Array(text.utf8CString)
        var output = [CChar](repeating: 0, count: input.count + 32)
        let count = il_terminal_paste(handle, &input, input.count - 1, &output, output.count)
        if count > 0 { send(Data(bytes: output, count: count)) }
    }

    private func publishViewport() {
        guard let onViewportChange else { return }
        onViewportChange(il_terminal_scroll_distance(handle))
    }
    func receiveViewport(_ distance: UInt64) {
        correctionView = nil
        guard let frame = frame() else { return }
        let maximum = frame.scrollTotal > frame.scrollLength ? frame.scrollTotal - frame.scrollLength : 0
        il_terminal_scroll_to(handle, maximum > distance ? maximum - distance : 0);notify()
    }
    func scroll(_ rows: Int) { correctionView = nil;il_terminal_scroll(handle, Int64(rows));publishViewport();notify() }
    func scrollTo(_ row: UInt64) { correctionView = nil;il_terminal_scroll_to(handle, row);publishViewport();notify() }
    func scrollBottom() { correctionView = nil;il_terminal_scroll_bottom(handle);publishViewport();notify() }

    func alternateScroll(_ rows: Int) -> Bool {
        guard rows != 0 else { return false }
        var output = [CChar](repeating: 0, count: 3)
        let count = il_terminal_alternate_scroll(handle, rows > 0, &output, output.count)
        guard count > 0 else { return false }
        let sequence = Data(bytes: output, count: count)
        let repetitions = min(100, abs(rows))
        var data = Data()
        data.reserveCapacity(count * repetitions)
        for _ in 0..<repetitions { data.append(sequence) }
        onInput?(data);notify()
        return true
    }

    func mouse(_ event: NSEvent, action: Int32, button: Int32, point: NSPoint, cell: NSSize) -> Bool {
        var output = [CChar](repeating: 0, count: 256)
        let count = il_terminal_mouse(handle, action, button, Self.modifiers(event.modifierFlags), Float(point.x), Float(point.y), Float(cell.width), Float(cell.height), &output, output.count)
        if count > 0 { onInput?(Data(bytes: output, count: count)) }
        // A protocol-suppressed drag is still owned by the terminal program.
        // Falling back to local selection would turn same-cell motion into a
        // spurious selection gesture.
        return count > 0 || il_terminal_mouse_reporting(handle)
    }

    func focusChanged(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        var output = [CChar](repeating: 0, count: 3)
        let count = il_terminal_focus(handle, focused, &output, output.count)
        if count > 0 { onInput?(Data(bytes: output, count: count)) }
    }

    func select(_ event: NSEvent, action: Int32, point: NSPoint, cell: NSSize) {
        correctionView = nil
        let col = UInt16(max(0, min(Int(columns) - 1, Int(point.x / cell.width))))
        let row = UInt16(max(0, min(Int(rows) - 1, Int(point.y / cell.height))))
        il_terminal_select(handle, action, col, row, Float(point.x), Float(point.y), Float(cell.width), Float(cell.height), UInt64(event.timestamp * 1_000_000_000), event.modifierFlags.contains(.option))
        if action == 3 { publishViewport() }
        notify()
    }

    var selectionNeedsAutoscroll: Bool { il_terminal_selection_autoscroll(handle) }
    func cancelSelectionGesture() { il_terminal_selection_cancel(handle) }

    func copy() -> String? {
        var count = 0
        guard let bytes = il_terminal_copy(handle, &count) else { return nil }
        defer { il_bytes_free(bytes) }
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }

    func selectAll() { correctionView = nil;il_terminal_select_all(handle); notify() }

    func search(_ query: String, direction: Int32 = 0) {
        correctionView = nil
        let newQuery = lastSearch != query; lastSearch = query
        query.withCString { il_terminal_search(handle, $0, query.utf8.count, newQuery && !query.isEmpty ? 1 : direction) }
        if query.isEmpty {
            onSearch?(0, 0, -1)
            lastSearchSpans = []; searchGeometryNeedsPublish = false; onSearchGeometry?([])
        }
        notify()
    }

    func link(at point: NSPoint, cell: NSSize) -> URL? {
        guard let bytes = il_terminal_link(handle, UInt16(max(0, min(Int(columns)-1, Int(point.x/cell.width)))), UInt16(max(0, min(Int(rows)-1, Int(point.y/cell.height))))) else { return nil }
        defer { il_bytes_free(bytes) }
        guard let url = URL(string: String(cString: bytes)), ["http", "https", "file", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func notify() {
        il_terminal_expire_render_hold(handle)
        let remaining = il_terminal_render_hold_remaining(handle)
        if remaining <= 0 {
            renderHoldTask?.cancel(); renderHoldTask = nil
        } else if renderHoldTask == nil {
            // A quiet or crashed producer must release its last partial frame
            // without depending on cursor blinking, new output, or user input.
            renderHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(remaining.rounded(.up)))
                guard !Task.isCancelled, let self else { return }
                self.renderHoldTask = nil
                self.notify()
            }
        }
        for observer in Array(observers.values) { observer() }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) | (flags.contains(.option) ? 4 : 0) | (flags.contains(.command) ? 8 : 0) | (flags.contains(.capsLock) ? 16 : 0)
    }
}
