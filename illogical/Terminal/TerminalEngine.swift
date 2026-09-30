import AppKit

struct TerminalSearchSpan: Equatable {
    let row: Int
    let startColumn: Int
    let endColumn: Int
}

struct TerminalGraphicsState {
    static let maximumImages = 1_024
    static let maximumPlacements = 1_024
    static let maximumImageSide: UInt32 = 16_384
    static let maximumPixelBytes = 8 * 1_024 * 1_024

    var generation: UInt64 = 0
    var cellWidth: UInt32 = 1
    var cellHeight: UInt32 = 1
    var images: [UInt32: WireGraphicsImage] = [:]
    var placements: [WireGraphicsPlacement] = []

    /// Bytes per pixel for the service's image formats.
    private static func components(format: Int) -> Int? {
        switch format {
        case 0: 3 // RGB
        case 1: 4 // RGBA
        case 3: 2 // gray + alpha
        case 4: 1 // gray
        default: nil
        }
    }

    /// Applies the service's bounded static image scene. The whole transaction
    /// is validated before displayed state or pixel data is replaced.
    mutating func apply(_ update: WireGraphicsState) -> Bool {
        guard update.cellWidth > 0, update.cellHeight > 0,
              update.placements.count <= Self.maximumPlacements, update.images.count <= Self.maximumImages else { return false }
        var next = update.reset ? [:] : images
        var updated: Set<UInt32> = []
        for image in update.images {
            guard let components = Self.components(format: Int(image.format)),
                  image.width > 0, image.height > 0,
                  image.width <= Self.maximumImageSide, image.height <= Self.maximumImageSide,
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
        guard next.values.reduce(0, { $0 + $1.data.count }) <= Self.maximumPixelBytes else { return false }
        generation = update.generation
        cellWidth = update.cellWidth
        cellHeight = update.cellHeight
        images = next
        placements = update.placements.sorted {
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.imageID != $1.imageID { return $0.imageID < $1.imageID }
            return $0.id < $1.id
        }
        return true
    }
}

// MARK: - Key bindings

/// Ghostty-style `keybind` entries for keys that do something other than
/// their normal encoding: send fixed text or move the viewport.
struct TerminalKeybindings: Equatable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(rawValue: UInt8) { self.rawValue = rawValue }

        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.command) { modifiers.insert(.command) }
            self = modifiers
        }
    }

    struct Trigger: Hashable, Sendable {
        enum Key: Hashable, Sendable {
            /// A macOS virtual key code, independent of the keyboard layout.
            case physical(UInt16)
            /// The character the key types with no modifiers.
            case character(Character)
        }

        var key: Key
        var modifiers: Modifiers
    }

    enum Action: Equatable, Sendable {
        case text(Data)
        case scrollToTop
        case scrollToBottom
        /// Negative pages scroll up.
        case scrollPage(Int)
        /// Negative counts jump to earlier prompts.
        case jumpToPrompt(Int)
        /// Consume the key without sending anything.
        case ignore
    }

    private(set) var bindings: [Trigger: Action] = [:]

    /// Ghostty's macOS defaults that change what a key sends: "natural text
    /// editing", viewport scrolling and prompt jumps (Config.zig, Keybinds.init).
    static let ghosttyDefaults: TerminalKeybindings = {
        var defaults = TerminalKeybindings()
        for entry in [
            "super+arrow_right=text:\\x05", "super+arrow_left=text:\\x01", "super+backspace=text:\\x15",
            "alt+arrow_left=esc:b", "alt+arrow_right=esc:f",
            "super+home=scroll_to_top", "super+end=scroll_to_bottom",
            "super+page_up=scroll_page_up", "super+page_down=scroll_page_down",
            "super+arrow_up=jump_to_prompt:-1", "super+arrow_down=jump_to_prompt:1",
            "super+shift+arrow_up=jump_to_prompt:-1", "super+shift+arrow_down=jump_to_prompt:1",
        ] {
            let applied = defaults.apply(entry)
            assert(applied, "Invalid default keybind \(entry)")
        }
        return defaults
    }()

    /// The table new terminals use. The app installs the user's bindings at
    /// launch, e.g. `.ghostty(configuration: GhosttyThemeImporter.configurationEntries())`.
    @MainActor static var shared = ghosttyDefaults

    /// Ghostty's defaults with every `keybind` entry of a Ghostty configuration
    /// applied in order. Entries this terminal cannot perform are skipped.
    static func ghostty(configuration entries: [(String, String)]) -> TerminalKeybindings {
        var bindings = ghosttyDefaults
        for (key, value) in entries where key == "keybind" { bindings.apply(value) }
        return bindings
    }

    func action(for event: NSEvent) -> Action? {
        let modifiers = Modifiers(event.modifierFlags)
        if let action = bindings[Trigger(key: .physical(event.keyCode), modifiers: modifiers)] { return action }
        guard event.type == .keyDown || event.type == .keyUp,
              let base = event.characters(byApplyingModifiers: [])?.lowercased(), base.count == 1, let character = base.first
        else { return nil }
        return bindings[Trigger(key: .character(character), modifiers: modifiers)]
    }

    /// Applies one `keybind` value such as `shift+enter=text:\x1b\r`. Returns
    /// false when the entry is not something a terminal pane performs.
    @discardableResult
    mutating func apply(_ entry: String) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        if entry == "clear" {
            bindings.removeAll()
            return true
        }
        guard let separator = entry.firstIndex(of: "=") else { return false }
        var triggerText = Substring(entry[..<separator])
        // Flags such as `global:` or `unconsumed:` only matter to Ghostty's app layer.
        let flags = ["all:", "global:", "local:", "unconsumed:", "performable:"]
        while let flag = flags.first(where: { triggerText.hasPrefix($0) }) { triggerText = triggerText.dropFirst(flag.count) }
        guard !triggerText.contains(">"), let trigger = Self.trigger(String(triggerText)) else { return false }
        let actionText = String(entry[entry.index(after: separator)...])
        if actionText == "unbind" {
            bindings[trigger] = nil
            return true
        }
        guard let action = Self.action(actionText) else {
            // Ghostty would run an app action here; never send this key's old binding instead.
            bindings[trigger] = nil
            return false
        }
        bindings[trigger] = action
        return true
    }

    private static func trigger(_ text: String) -> Trigger? {
        var modifiers: Modifiers = []
        var key: Trigger.Key?
        var rest = Substring(text)
        while !rest.isEmpty {
            let plus = rest.firstIndex(of: "+") ?? rest.endIndex
            // An empty part is the plus key itself, as in `super++`.
            let part = plus == rest.startIndex ? "+" : String(rest[..<plus])
            rest = plus == rest.endIndex ? "" : rest[rest.index(after: plus)...]
            let modifier: Modifiers? = switch part {
            case "shift": .shift
            case "ctrl", "control": .control
            case "alt", "opt", "option": .option
            case "super", "cmd", "command": .command
            default: nil
            }
            if let modifier {
                guard !modifiers.contains(modifier) else { return nil }
                modifiers.insert(modifier)
                continue
            }
            guard key == nil, !part.isEmpty else { return nil }
            let name = part.hasPrefix("physical:") ? String(part.dropFirst("physical:".count)) : part
            if let code = physicalKeyCodes[name] {
                key = .physical(code)
            } else if name.count == 1, let character = name.lowercased().first {
                key = .character(character)
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        return Trigger(key: key, modifiers: modifiers)
    }

    private static func action(_ text: String) -> Action? {
        let (name, parameter): (Substring, String?) = if let colon = text.firstIndex(of: ":") {
            (text[..<colon], String(text[text.index(after: colon)...]))
        } else {
            (Substring(text), nil)
        }
        switch (name, parameter) {
        case ("text", let value?): return unescape(value).map(Action.text)
        case ("csi", let value?): return unescape(value).map { .text(Data("\u{1b}[".utf8) + $0) }
        case ("esc", let value?): return unescape(value).map { .text(Data("\u{1b}".utf8) + $0) }
        case ("scroll_to_top", nil): return .scrollToTop
        case ("scroll_to_bottom", nil): return .scrollToBottom
        case ("scroll_page_up", nil): return .scrollPage(-1)
        case ("scroll_page_down", nil): return .scrollPage(1)
        case ("jump_to_prompt", let count?): return Int(count).map(Action.jumpToPrompt)
        case ("ignore", nil): return .ignore
        default: return nil
        }
    }

    /// Decodes Zig string escapes, which Ghostty uses for text actions.
    static func unescape(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        var scalars = text.unicodeScalars.makeIterator()
        func hex(_ digits: String) -> UInt32? { UInt32(digits, radix: 16) }
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                continue
            }
            switch scalars.next() {
            case "n": bytes.append(0x0a)
            case "r": bytes.append(0x0d)
            case "t": bytes.append(0x09)
            case "\\": bytes.append(0x5c)
            case "'": bytes.append(0x27)
            case "\"": bytes.append(0x22)
            case "x":
                guard let high = scalars.next(), let low = scalars.next(),
                      let value = hex(String(high) + String(low)) else { return nil }
                bytes.append(UInt8(value))
            case "u":
                guard scalars.next() == "{" else { return nil }
                var digits = ""
                while let next = scalars.next(), next != "}" { digits.unicodeScalars.append(next) }
                guard let value = hex(digits), let character = Unicode.Scalar(value) else { return nil }
                bytes.append(contentsOf: Array(String(character).utf8))
            default:
                return nil
            }
        }
        return Data(bytes)
    }

    /// Ghostty key names (and its 1.1 aliases) to macOS virtual key codes.
    private static let physicalKeyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "delete": 117, "insert": 114,
            "home": 115, "end": 119, "page_up": 116, "page_down": 121,
            "arrow_left": 123, "arrow_right": 124, "arrow_down": 125, "arrow_up": 126,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "minus": 27, "equal": 24, "bracket_left": 33, "bracket_right": 30, "left_bracket": 33, "right_bracket": 30,
            "backslash": 42, "semicolon": 41, "quote": 39, "backquote": 50, "grave_accent": 50,
            "comma": 43, "period": 47, "slash": 44,
            "digit_0": 29, "digit_1": 18, "digit_2": 19, "digit_3": 20, "digit_4": 21,
            "digit_5": 23, "digit_6": 22, "digit_7": 26, "digit_8": 28, "digit_9": 25,
            "numpad_0": 82, "numpad_1": 83, "numpad_2": 84, "numpad_3": 85, "numpad_4": 86,
            "numpad_5": 87, "numpad_6": 88, "numpad_7": 89, "numpad_8": 91, "numpad_9": 92,
            "numpad_add": 69, "numpad_subtract": 78, "numpad_multiply": 67, "numpad_divide": 75,
            "numpad_decimal": 65, "numpad_enter": 76, "numpad_equal": 81,
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
        for (name, code) in codes where name.hasPrefix("numpad_") { codes["kp_" + name.dropFirst("numpad_".count)] = code }
        return codes
    }()
}

// MARK: - Engine

/// A client replica of one service terminal: parses its output stream,
/// produces frames for the renderer, and encodes this client's input.
@MainActor
final class TerminalEngine {
    /// Result of offering a key event to the terminal.
    enum KeyOutcome: Equatable {
        /// Nothing was sent.
        case ignored
        /// Encoded input reached the program; `text` is true for keys that type.
        case sent(text: Bool)
        /// A key binding handled the key instead of the encoder.
        case bound
    }

    /// The service rejects writes over one megabyte. Larger input is split
    /// and paced so a big paste neither fails nor floods the connection.
    static let maximumWriteBytes = 512 * 1_024
    static let writePacing: Duration = .milliseconds(5)

    let blockID: String
    private(set) var handle: OpaquePointer?
    private(set) var stream: String?
    private(set) var loadingHistory = false
    private(set) var replayID: String?
    private(set) var sequence: UInt64?
    private(set) var graphics = TerminalGraphicsState()

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
    /// Which Option keys act as Alt, like Ghostty's `macos-option-as-alt`.
    var optionAsAlt: ILOptionAsAlt = .disabled
    var keybindings = TerminalKeybindings.shared
    /// The cursor shown until a program picks one; nil keeps Ghostty's block.
    private(set) var defaultCursor: (style: ILCursorStyle, blinks: Bool)?

    private var canResume = false
    private var requestedCellSize: (UInt32, UInt32)?
    private var lastSearch = ""
    private var serviceTheme: WireTheme?
    private var hasKeyboardFocus = false
    private var lastSearchSpans: [TerminalSearchSpan] = []
    private var searchGeometryNeedsPublish = true
    private var renderHoldTask: Task<Void, Never>?
    /// The view a graphics-correction snapshot preserves until history finishes loading.
    private var correctionView: ILTerminalViewState?
    private var pendingWrites: [Data] = []
    private var writePump: Task<Void, Never>?

    init(blockID: String, theme: TerminalTheme) {
        self.blockID = blockID
        self.theme = theme
        handle = il_terminal_new(columns, rows)
        applyTheme(theme)
    }

    isolated deinit {
        renderHoldTask?.cancel()
        writePump?.cancel()
        il_terminal_free(handle)
    }

    // MARK: Replay

    func attachmentRequest() -> WireRequest {
        WireRequest(method: "block.attach", block: blockID,
                    replayID: canResume ? replayID : nil, sequence: canResume ? sequence : nil)
    }

    private func invalidateReplay() {
        canResume = false
        replayID = nil
        sequence = nil
        stream = nil
    }

    /// Orders sequenced mutations. A gap drops the replica and asks for a snapshot.
    private func acceptMutation(_ message: WireMessage) -> Bool {
        guard message.stream == stream else { return false }
        guard let next = message.sequence, let epoch = message.replayID else { return true }
        let sameEpoch = epoch == replayID
        // Theme and graphics resets restate the current sequence.
        if message.type == "theme", message.previousSequence == nil, sameEpoch, next == sequence { return true }
        if message.type == "graphics", message.graphics?.reset == true, message.previousSequence == nil, sameEpoch, next == sequence {
            return true
        }
        if sameEpoch, let sequence, next <= sequence { return false }
        guard sameEpoch, let current = sequence, message.previousSequence == current else {
            invalidateReplay()
            onReplayGap?()
            return false
        }
        sequence = next
        return true
    }

    func receive(_ message: WireMessage) {
        switch message.type {
        case "resync":
            invalidateReplay()
            return
        case "resume":
            guard canResume, message.replayID == replayID, message.sequence == sequence else {
                invalidateReplay()
                onReplayGap?()
                return
            }
            stream = message.stream
            return
        case "snapshot":
            guard let data = message.data, restoreSnapshot(message, data: data) else { return }
        case "history":
            guard let data = message.data, message.stream == stream, applyHistory(message, data: data) else { return }
        case "output", "resize", "theme", "graphics":
            guard acceptMutation(message), applyMutation(message) else { return }
        default:
            return
        }
        notify()
    }

    private func restoreSnapshot(_ message: WireMessage, data: Data) -> Bool {
        // A graphics correction replaces the parser in place; keep the user's view.
        var preserved: ILTerminalViewState?
        if message.text == "graphics" {
            if let correctionView {
                preserved = correctionView
            } else {
                var state = ILTerminalViewState()
                if il_terminal_capture_view(handle, &state) { preserved = state }
            }
        }
        let restored = data.withUnsafeBytes { il_terminal_restore($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        guard let restored else {
            invalidateReplay()
            onError?("Could not restore the terminal snapshot.")
            return false
        }
        il_terminal_free(handle)
        handle = restored
        stream = message.stream
        correctionView = preserved
        graphics = TerminalGraphicsState()
        replayID = message.replayID
        sequence = message.sequence
        canResume = false
        columns = message.cols ?? columns
        rows = message.rows ?? rows
        requestedSize = nil
        loadingHistory = true
        if !lastSearch.isEmpty { runSearch(lastSearch, navigation: .next) }
        applyDefaultCursor()
        if let serviceTheme { applyServiceTheme(serviceTheme) } else { applyTheme(theme) }
        if var preserved { il_terminal_restore_view(handle, &preserved) }
        return true
    }

    private func applyHistory(_ message: WireMessage, data: Data) -> Bool {
        let final = message.final ?? false
        let result = data.withUnsafeBytes { il_terminal_history(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count, final) }
        guard result == 0 else {
            invalidateReplay()
            onError?("Could not restore terminal history (\(result)).")
            return false
        }
        if var correctionView { il_terminal_restore_view(handle, &correctionView) }
        if final {
            loadingHistory = false
            canResume = replayID != nil && sequence != nil
            correctionView = nil
        }
        return true
    }

    private func applyMutation(_ message: WireMessage) -> Bool {
        switch message.type {
        case "output":
            if let data = message.data {
                data.withUnsafeBytes { il_terminal_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
            }
        case "resize":
            if let columns = message.cols, let rows = message.rows { resizeFromServer(columns: columns, rows: rows) }
        case "theme":
            if let theme = message.theme { applyServiceTheme(theme) }
        case "graphics":
            guard let update = message.graphics, graphics.apply(update) else {
                invalidateReplay()
                onError?("Could not restore terminal images.")
                onReplayGap?()
                return false
            }
        default:
            break
        }
        return true
    }

    // MARK: Size

    func resizeFromServer(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
        il_terminal_resize(handle, columns, rows, 0, 0)
        notify()
    }

    func requestResize(columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard stream != nil, columns > 1, rows > 0 else { return }
        let sameGrid = requestedSize?.0 == columns && requestedSize?.1 == rows
        let sameCells = requestedCellSize?.0 == cellWidth && requestedCellSize?.1 == cellHeight
        guard !sameGrid || !sameCells else { return }
        requestedSize = (columns, rows)
        requestedCellSize = (cellWidth, cellHeight)
        onResize?(columns, rows, cellWidth, cellHeight)
    }

    // MARK: Frames

    func frame() -> ILFrame? {
        var frame = ILFrame()
        guard il_terminal_frame(handle, &frame) else { return nil }
        columns = frame.columns
        rows = frame.rows
        if !lastSearch.isEmpty { publishSearch(frame) }
        return frame
    }

    private func publishSearch(_ frame: ILFrame) {
        onSearch?(Int(frame.searchCount), Int(frame.searchSelected), Int(frame.searchRow))
        guard let onSearchGeometry else { return }
        let spans = Self.activeMatchSpans(frame)
        if searchGeometryNeedsPublish || spans != lastSearchSpans {
            searchGeometryNeedsPublish = false
            lastSearchSpans = spans
            onSearchGeometry(spans)
        }
    }

    /// Row runs of the selected search match, for placing the search bar.
    private static func activeMatchSpans(_ frame: ILFrame) -> [TerminalSearchSpan] {
        guard let cells = frame.cells else { return [] }
        func isActive(_ cell: ILCell) -> Bool { ILCellFlags(rawValue: cell.flags).contains(.activeSearchMatch) }
        var spans: [TerminalSearchSpan] = []
        var index = 0
        while index < frame.count {
            let first = cells[index]
            index += 1
            guard isActive(first) else { continue }
            var end = Int(first.column)
            while index < frame.count, cells[index].row == first.row, isActive(cells[index]) {
                end = Int(cells[index].column)
                index += 1
            }
            spans.append(TerminalSearchSpan(row: Int(first.row), startColumn: Int(first.column), endColumn: end))
        }
        return spans
    }

    /// Wakes observers, and keeps one timer to release a synchronized-output
    /// hold even when the program goes quiet (or crashed mid-update).
    func notify() {
        il_terminal_expire_render_hold(handle)
        let remaining = il_terminal_render_hold_remaining(handle)
        if remaining <= 0 {
            renderHoldTask?.cancel()
            renderHoldTask = nil
        } else if renderHoldTask == nil {
            renderHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(remaining.rounded(.up)))
                guard !Task.isCancelled, let self else { return }
                self.renderHoldTask = nil
                self.notify()
            }
        }
        for observer in Array(observers.values) { observer() }
    }

    // MARK: Appearance

    /// Ghostty's `cursor-style` and `cursor-style-blink`, kept across snapshot restores.
    func setDefaultCursor(style: ILCursorStyle, blinks: Bool) {
        guard defaultCursor?.style != style || defaultCursor?.blinks != blinks else { return }
        defaultCursor = (style, blinks)
        applyDefaultCursor()
        notify()
    }

    private func applyDefaultCursor() {
        guard let defaultCursor else { return }
        il_terminal_set_default_cursor(handle, defaultCursor.style, defaultCursor.blinks)
    }

    func applyTheme(_ theme: TerminalTheme) {
        serviceTheme = nil
        self.theme = theme
        theme.palette.withUnsafeBufferPointer {
            il_terminal_theme(handle, theme.background, theme.foreground, theme.accent, $0.baseAddress)
        }
        notify()
    }

    func applyServiceTheme(_ wire: WireTheme) {
        let palette = wire.palette ?? []
        let colors = [wire.background, wire.foreground, wire.cursor].compactMap { $0 }
        guard colors.allSatisfy({ $0 <= 0xffffff }), palette.isEmpty || palette.count == 256,
              palette.allSatisfy({ $0 <= 0xffffff }) else {
            onError?("Could not apply an invalid terminal theme.")
            return
        }
        serviceTheme = wire
        withOptionalPointer(wire.background) { background in
            withOptionalPointer(wire.foreground) { foreground in
                withOptionalPointer(wire.cursor) { cursor in
                    palette.withUnsafeBufferPointer {
                        il_terminal_theme_override(handle, background, foreground, cursor, palette.isEmpty ? nil : $0.baseAddress)
                    }
                }
            }
        }
        var defaults = [UInt32](repeating: 0, count: 256)
        if il_terminal_default_palette(handle, &defaults) {
            theme.ansi = Array(defaults.prefix(16))
            theme.extendedPalette = Array(defaults.dropFirst(16))
        }
        let background = wire.background ?? 0, foreground = wire.foreground ?? 0xffffff
        theme.name = "Service Theme"
        theme.background = background
        theme.foreground = foreground
        theme.accent = wire.cursor ?? foreground
        theme.isLight = 299 * (background >> 16 & 255) + 587 * (background >> 8 & 255) + 114 * (background & 255) > 127_500
        notify()
    }

    // MARK: Input

    /// Sends user input: returns to the live bottom first, like Ghostty's
    /// scroll-to-bottom on keystroke and paste.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        correctionView = nil
        let publishBottom = onViewportChange != nil && il_terminal_scroll_distance(handle) > 0
        il_terminal_scroll_bottom(handle)
        if publishBottom { onViewportChange?(0) }
        write(data)
        notify()
    }

    /// Queues bytes for the program without moving the viewport. All input
    /// shares one ordered queue so a report never lands inside a paste.
    private func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if pendingWrites.isEmpty, data.count <= Self.maximumWriteBytes {
            onInput?(data)
            return
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.maximumWriteBytes, limitedBy: data.endIndex) ?? data.endIndex
            pendingWrites.append(Data(data[offset..<end]))
            offset = end
        }
        guard writePump == nil else { return }
        writePump = Task { [weak self] in
            while !Task.isCancelled, let chunk = self?.takePendingWrite() {
                self?.onInput?(chunk)
                try? await Task.sleep(for: TerminalEngine.writePacing)
            }
            self?.writePump = nil
        }
    }

    private func takePendingWrite() -> Data? {
        pendingWrites.isEmpty ? nil : pendingWrites.removeFirst()
    }

    /// Committed input-method text is typing, not a paste.
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        il_terminal_clear_selection(handle)
        send(Data(text.utf8))
    }

    func paste(_ text: String) {
        let input = Array(text.utf8)
        guard !input.isEmpty else { return }
        let encoded = input.withUnsafeBufferPointer { source in
            Self.encoded(capacity: input.count + 32) { output, capacity in
                source.withMemoryRebound(to: CChar.self) {
                    il_terminal_paste(handle, $0.baseAddress, $0.count, output, capacity)
                }
            }
        }
        send(encoded)
    }

    /// Ghostty's clipboard-paste-protection: confirm before pasting text that
    /// could run commands.
    func pasteNeedsConfirmation(_ text: String) -> Bool {
        text.utf8CString.withUnsafeBufferPointer { il_terminal_paste_is_unsafe(handle, $0.baseAddress, $0.count - 1) }
    }

    /// Runs a C encoder that reports the length it needs, growing the buffer once if required.
    private static func encoded(capacity: Int, _ encode: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> Data {
        var buffer = [CChar](repeating: 0, count: max(1, capacity))
        var length = buffer.withUnsafeMutableBufferPointer { encode($0.baseAddress, $0.count) }
        if length > buffer.count {
            buffer = [CChar](repeating: 0, count: length)
            length = buffer.withUnsafeMutableBufferPointer { encode($0.baseAddress, $0.count) }
        }
        return length > 0 && length <= buffer.count ? buffer.withUnsafeBytes { Data($0.prefix(length)) } : Data()
    }

    // MARK: Keyboard

    /// The modifiers macOS should translate characters with: Option acting
    /// as Alt must not compose characters (Ghostty's translation mods).
    func translationModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        optionActsAsAlt(flags) ? flags.subtracting(.option) : flags
    }

    private func optionActsAsAlt(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.option) else { return false }
        let rightOption = Self.modifiers(flags).contains(.rightOption)
        return switch optionAsAlt {
        case .disabled: false
        case .both: true
        case .left: !rightOption
        case .right: rightOption
        }
    }

    /// Encodes a key event, after key bindings. `text` overrides the event's
    /// characters (input-method commits); `translation` is the modifier set the
    /// characters were produced with.
    @discardableResult
    func key(_ event: NSEvent, action: ILKeyAction? = nil, text: String? = nil,
             translation: NSEvent.ModifierFlags? = nil, composing: Bool = false) -> KeyOutcome {
        let isCharacterEvent = event.type == .keyDown || event.type == .keyUp
        let action = action ?? (event.type == .keyUp ? .release : event.isARepeat ? .repeat : .press)
        if action != .release, !composing, let binding = keybindings.action(for: event) {
            perform(binding)
            return .bound
        }
        // macOS Command chords never type. Only the Kitty protocol reports them.
        if event.modifierFlags.contains(.command), !il_terminal_kitty_keyboard(handle) { return .ignored }

        let translation = translation ?? translationModifiers(event.modifierFlags)
        let keyText = Self.keyText(text ?? (isCharacterEvent && action != .release ? Self.characters(event, translation: translation) : nil))
        let unshifted = isCharacterEvent ? Self.keyText(event.characters(byApplyingModifiers: [])).unicodeScalars : "".unicodeScalars
        let unshiftedCodepoint = unshifted.count == 1 ? unshifted.first?.value ?? 0 : 0
        let data = keyText.withCString { textPointer in
            var key = ILKeyEvent(
                keyCode: event.keyCode, action: action, modifiers: Self.modifiers(event.modifierFlags),
                consumedModifiers: keyText.isEmpty ? [] : Self.modifiers(translation.subtracting([.control, .command])),
                unshiftedCodepoint: unshiftedCodepoint,
                text: textPointer, textLength: keyText.utf8.count, composing: composing, optionAsAlt: optionAsAlt)
            return Self.encoded(capacity: 64) { il_terminal_key(handle, &key, $0, $1) }
        }
        guard !data.isEmpty else { return .ignored }
        // Ghostty's selection-clear-on-typing: any non-modifier key that reaches the program.
        if event.type != .flagsChanged, action != .release { il_terminal_clear_selection(handle) }
        send(data)
        return .sent(text: !keyText.isEmpty)
    }

    private func perform(_ action: TerminalKeybindings.Action) {
        switch action {
        case .text(let data):
            il_terminal_clear_selection(handle)
            send(data)
        case .scrollToTop: scrollToTop()
        case .scrollToBottom: scrollToBottom()
        case .scrollPage(let pages): scrollPage(pages)
        case .jumpToPrompt(let count): jumpToPrompt(count)
        case .ignore: break
        }
    }

    /// The characters a key produced. AppKit already turned Control chords
    /// into C0 bytes; the encoder wants the layout character instead.
    private static func characters(_ event: NSEvent, translation: NSEvent.ModifierFlags) -> String? {
        let characters = translation == event.modifierFlags ? event.characters : event.characters(byApplyingModifiers: translation)
        guard let characters, characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first,
              scalar.value < 0x20 || scalar.value == 0x7f else { return characters }
        return event.characters(byApplyingModifiers: translation.subtracting([.control, .command]))
    }

    /// Key text without control characters or AppKit's function-key
    /// private-use characters; the encoder derives those from the key.
    private static func keyText(_ text: String?) -> String {
        guard let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return text ?? "" }
        let isControl = scalar.value < 0x20 || scalar.value == 0x7f
        let isFunctionKey = (0xf700...0xf8ff).contains(scalar.value)
        return isControl || isFunctionKey ? "" : text
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ILModifiers {
        var modifiers: ILModifiers = []
        let pairs: [(NSEvent.ModifierFlags, ILModifiers)] = [
            (.shift, .shift), (.control, .control), (.option, .option), (.command, .command), (.capsLock, .capsLock),
        ]
        for (flag, modifier) in pairs where flags.contains(flag) { modifiers.insert(modifier) }
        // Device-dependent bits say which side is held (IOLLEvent.h NX_DEVICER*KEYMASK).
        let sides: [(UInt, ILModifiers)] = [(0x04, .rightShift), (0x2000, .rightControl), (0x40, .rightOption), (0x10, .rightCommand)]
        for (mask, side) in sides where flags.rawValue & mask != 0 { modifiers.insert(side) }
        return modifiers
    }

    // MARK: Viewport

    private func publishViewport() {
        onViewportChange?(il_terminal_scroll_distance(handle))
    }

    private func moveViewport(_ move: () -> Void) {
        correctionView = nil
        move()
        publishViewport()
        notify()
    }

    /// Applies a peer's bottom-relative viewport without echoing it back.
    func receiveViewport(_ distance: UInt64) {
        correctionView = nil
        guard let frame = frame() else { return }
        let bottom = frame.scrollTotal > frame.scrollLength ? frame.scrollTotal - frame.scrollLength : 0
        il_terminal_scroll_to(handle, bottom > distance ? bottom - distance : 0)
        notify()
    }

    /// Negative rows scroll up into history.
    func scroll(_ rows: Int) { moveViewport { il_terminal_scroll(handle, Int64(rows)) } }
    func scrollTo(_ row: UInt64) { moveViewport { il_terminal_scroll_to(handle, row) } }
    func scrollToTop() { moveViewport { il_terminal_scroll_top(handle) } }
    func scrollToBottom() { moveViewport { il_terminal_scroll_bottom(handle) } }
    /// The name existing callers use for `scrollToBottom()`.
    func scrollBottom() { scrollToBottom() }
    /// Negative pages scroll up.
    func scrollPage(_ pages: Int) { scroll(pages * Int(rows)) }

    /// Moves the viewport top to a shell prompt marked with OSC 133.
    @discardableResult
    func jumpToPrompt(_ count: Int) -> Bool {
        var jumped = false
        moveViewport { jumped = il_terminal_jump_to_prompt(handle, Int32(clamping: count)) }
        return jumped
    }

    /// Cursor keys for a wheel on the alternate screen (DEC mode 1007), if enabled.
    func alternateScroll(_ rows: Int) -> Bool {
        guard rows != 0 else { return false }
        var sequence = [CChar](repeating: 0, count: 3)
        let count = il_terminal_alternate_scroll(handle, rows > 0, &sequence, sequence.count)
        guard count > 0 else { return false }
        let key = sequence.withUnsafeBytes { Data($0.prefix(count)) }
        write(Data(repeatElement(key, count: min(100, abs(rows))).joined()))
        notify()
        return true
    }

    // MARK: Mouse and focus

    var mouseReporting: Bool { il_terminal_mouse_reporting(handle) }

    /// Reports a mouse event to the program at a pixel position. Returns true
    /// when the program owns the mouse, even if this event produced no bytes.
    func mouse(_ action: ILMouseAction, button: ILMouseButton, modifiers: NSEvent.ModifierFlags, at point: CGPoint, cell: CGSize) -> Bool {
        var report = [CChar](repeating: 0, count: 64)
        let count = il_terminal_mouse(handle, action, button, Self.modifiers(modifiers), Float(point.x), Float(point.y),
                                      Float(cell.width), Float(cell.height), &report, report.count)
        if count > 0 { write(report.withUnsafeBytes { Data($0.prefix(count)) }) }
        // A suppressed same-cell drag still belongs to the program; falling
        // back to local selection would start a spurious selection.
        return count > 0 || mouseReporting
    }

    func focusChanged(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        var report = [CChar](repeating: 0, count: 3)
        let count = il_terminal_focus(handle, focused, &report, report.count)
        if count > 0 { write(report.withUnsafeBytes { Data($0.prefix(count)) }) }
    }

    // MARK: Selection

    /// The viewport cell under a point, clamped to the grid; nil for unusable geometry.
    func viewportCell(at point: CGPoint, cellSize: CGSize) -> (column: UInt16, row: UInt16)? {
        guard cellSize.width > 0, cellSize.height > 0, point.x.isFinite, point.y.isFinite, columns > 0, rows > 0 else { return nil }
        let column = min(max((point.x / cellSize.width).rounded(.down), 0), CGFloat(columns - 1))
        let row = min(max((point.y / cellSize.height).rounded(.down), 0), CGFloat(rows - 1))
        return (UInt16(column), UInt16(row))
    }

    func select(_ event: ILSelectionEvent, at point: CGPoint, cellSize: CGSize, time: TimeInterval, rectangle: Bool) {
        correctionView = nil
        guard let cell = viewportCell(at: point, cellSize: cellSize) else { return }
        let nanoseconds = time.isFinite && time > 0 ? UInt64(min(time, 1e9) * 1_000_000_000) : 0
        il_terminal_select(handle, event, cell.column, cell.row, Float(point.x), Float(point.y),
                           Float(cellSize.width), Float(cellSize.height), nanoseconds, rectangle)
        if event == .autoscrollTick { publishViewport() }
        notify()
    }

    var selectionNeedsAutoscroll: Bool { il_terminal_selection_autoscroll(handle) }
    func cancelSelectionGesture() { il_terminal_selection_cancel(handle) }

    func selectAll() {
        correctionView = nil
        il_terminal_select_all(handle)
        notify()
    }

    /// Moves the end of the current selection to a point (Shift-click).
    @discardableResult
    func extendSelection(to point: CGPoint, cellSize: CGSize) -> Bool {
        guard let cell = viewportCell(at: point, cellSize: cellSize), il_terminal_extend_selection(handle, cell.column, cell.row) else { return false }
        correctionView = nil
        notify()
        return true
    }

    func clearSelection() {
        il_terminal_clear_selection(handle)
        notify()
    }

    func copy() -> String? {
        var count = 0
        guard let bytes = il_terminal_copy(handle, &count) else { return nil }
        defer { il_bytes_free(bytes) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    // MARK: Search and links

    /// `direction` moves the selected match: positive next, negative previous.
    func search(_ query: String, direction: Int32 = 0) {
        correctionView = nil
        let newQuery = lastSearch != query
        lastSearch = query
        let navigation: ILSearchNavigation = newQuery && !query.isEmpty ? .next
            : direction > 0 ? .next : direction < 0 ? .previous : .stay
        runSearch(query, navigation: navigation)
        if query.isEmpty {
            onSearch?(0, 0, -1)
            lastSearchSpans = []
            searchGeometryNeedsPublish = false
            onSearchGeometry?([])
        }
        notify()
    }

    private func runSearch(_ query: String, navigation: ILSearchNavigation) {
        query.withCString { il_terminal_search(handle, $0, query.utf8.count, navigation) }
    }

    /// The link under a point, limited to schemes that are safe to open.
    func link(at point: CGPoint, cellSize: CGSize) -> URL? {
        guard let cell = viewportCell(at: point, cellSize: cellSize), let bytes = il_terminal_link(handle, cell.column, cell.row) else { return nil }
        defer { il_bytes_free(bytes) }
        guard let url = URL(string: String(cString: bytes)),
              ["http", "https", "file", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Passes a pointer to a copy of `value`, or nil when there is no value.
private func withOptionalPointer<Value, Result>(_ value: Value?, _ body: (UnsafePointer<Value>?) -> Result) -> Result {
    guard var value else { return body(nil) }
    return withUnsafePointer(to: &value) { body($0) }
}
