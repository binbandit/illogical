import AppKit
import Carbon.HIToolbox
import MetalKit
import SwiftUI

/// A three-finger vertical swipe that drives the workspace peek. Progress
/// runs from 0 (terminal) to 2 (session overview).
@MainActor
private struct PeekTouchGesture {
    struct Contact {
        let identity: any NSObjectProtocol
        let position: CGPoint
    }

    /// A progress update, and whether the gesture finished.
    typealias Update = (progress: CGFloat, finished: Bool)

    private static let slop: CGFloat = 8
    private static let pointsPerStep: CGFloat = 64
    /// Vertical motion must dominate horizontal motion by this much.
    private static let verticalBias: CGFloat = 1.4

    private var contacts: [Contact] = []
    private var origin = CGPoint.zero
    private var start: CGFloat = 0
    private var progress: CGFloat = 0
    private var direction: CGFloat = 0
    private var blocked = false

    mutating func update(_ current: [Contact], initialProgress: CGFloat) -> Update? {
        guard !blocked else { return nil }
        if contacts.isEmpty {
            guard current.count == 3 else { return nil }
            contacts = current
            origin = Self.centroid(current)
            start = initialProgress
            progress = start
            return nil
        }
        let sameFingers = contacts.allSatisfy { old in current.contains { old.identity.isEqual($0.identity) } }
        guard current.count == 3, sameFingers else { return cancel() }
        let point = Self.centroid(current)
        let vertical = origin.y - point.y, horizontal = point.x - origin.x
        if direction == 0 {
            guard max(abs(vertical), abs(horizontal)) >= Self.slop else { return nil }
            let opensPastEnd = (start == 0 && vertical < 0) || (start == 2 && vertical > 0)
            guard abs(vertical) > abs(horizontal) * Self.verticalBias, !opensPastEnd else {
                blocked = true
                return nil
            }
            direction = vertical > 0 ? 1 : -1
        }
        progress = min(2, max(0, start + (vertical - direction * Self.slop) / Self.pointsPerStep))
        return (progress, false)
    }

    mutating func end(remaining: Int) -> Update? {
        let result: Update? = direction == 0 ? nil : (progress, true)
        contacts = []
        direction = 0
        blocked = remaining != 0
        return result
    }

    mutating func cancel() -> Update? {
        let result: Update? = direction == 0 ? nil : (start, true)
        blocked = blocked || !contacts.isEmpty
        contacts = []
        direction = 0
        return result
    }

    private static func centroid(_ contacts: [Contact]) -> CGPoint {
        let count = CGFloat(contacts.count)
        return CGPoint(x: contacts.reduce(0) { $0 + $1.position.x } / count,
                       y: contacts.reduce(0) { $0 + $1.position.y } / count)
    }
}

@MainActor
final class TerminalMetalView: MTKView {
    var onDisplayEnvironmentChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchLayerScaleToWindow()
        onDisplayEnvironmentChange?()
        if window != nil {
            // The parent's attachment callback can precede this child's window
            // and bounds. Wake again after AppKit finishes mounting the subtree.
            DispatchQueue.main.async { [weak self] in self?.onDisplayEnvironmentChange?() }
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onDisplayEnvironmentChange?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onDisplayEnvironmentChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchLayerScaleToWindow()
        onDisplayEnvironmentChange?()
    }

    /// AppKit leaves the Metal layer at the scale of the display the window
    /// started on, while MTKView sizes the drawable for the new one. The layer
    /// keeps its contents top-left instead of stretching them, so a stale
    /// scale shows the terminal at half size on a 1x display, or double size
    /// back on Retina.
    private func matchLayerScaleToWindow() {
        guard let scale = window?.backingScaleFactor, let layer, layer.contentsScale != scale else { return }
        CATransaction.begin()
        // Without this Core Animation animates the contents between scales.
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        CATransaction.commit()
    }
}

/// A workspace action in a terminal's right-click menu. Its key equivalent
/// is only shown, so the menu also teaches the shortcut.
struct TerminalMenuItem {
    let title: String
    var keyEquivalent = ""
    var modifiers: NSEvent.ModifierFlags = []
    let action: @MainActor () -> Void
}

/// Runs a `TerminalMenuItem`'s action; the menu keeps it alive while open.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ item: TerminalMenuItem) {
        run = item.action
        super.init(title: item.title, action: #selector(runAction), keyEquivalent: item.keyEquivalent)
        target = self
        keyEquivalentModifierMask = item.modifiers
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

struct TerminalSurface: NSViewRepresentable {
    let engine: TerminalEngine
    let fontSize: CGFloat
    let fontName: String
    let focused: Bool
    let focusToken: UUID
    var interactive = true
    var peekProgress: CGFloat = 0
    var contrast = true
    var fontOptions: TerminalFontOptions = .defaults
    var onFocus: () -> Void = {}
    var onRequestEditorFocus: (UUID?) -> Bool = { _ in false }
    var onPeek: (CGFloat, Bool) -> Void = { _, _ in }
    var onCellSize: (CGSize) -> Void = { _ in }
    var copyOnSelection = false
    var onCopy: (String) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }
    /// Ghostty's `unfocused-split-opacity`: an unfocused pane fades toward its
    /// background. 1 disables it; the workspace passes it only for split panes.
    var unfocusedOpacity: CGFloat = 1
    /// Ghostty's `mouse-hide-while-typing`.
    var hidePointerWhileTyping = true
    /// Ghostty's `clipboard-paste-protection`.
    var confirmUnsafePaste = true
    /// Groups of workspace actions for the right-click menu, after Copy,
    /// Paste and Select All.
    var menuItems: [[TerminalMenuItem]] = []

    func makeNSView(context: Context) -> NativeTerminalView { NativeTerminalView(engine: engine) }

    func updateNSView(_ view: NativeTerminalView, context: Context) {
        let renderer = view.renderer
        let layoutChanged = view.interactive != interactive || renderer?.fontSize != fontSize
            || renderer?.fontName != fontName || renderer?.fontOptions != fontOptions
        let drawingChanged = layoutChanged || renderer?.contrastCorrection != contrast
        view.interactive = interactive
        view.onFocus = onFocus
        view.onPeek = onPeek
        view.onCellSize = onCellSize
        view.onRequestEditorFocus = onRequestEditorFocus
        view.peekProgress = peekProgress
        view.copyOnSelection = copyOnSelection
        view.onCopy = onCopy
        view.onLink = onLink
        view.hidePointerWhileTyping = hidePointerWhileTyping
        view.confirmUnsafePaste = confirmUnsafePaste
        view.menuItems = menuItems
        renderer?.fontSize = fontSize
        renderer?.fontName = fontName
        renderer?.fontOptions = fontOptions
        engine.setDefaultCursor(style: ILCursorStyle(rawValue: Int32(fontOptions.cursorStyle.rawValue)) ?? .block,
                                blinks: fontOptions.cursorBlink)
        renderer?.interactive = interactive
        renderer?.contrastCorrection = contrast
        view.setPaneFocus(focused, unfocusedOpacity: unfocusedOpacity)
        view.updateCursorBlink()
        view.wantsKeyboardFocus = interactive && focused
        if interactive && focused && view.focusToken != focusToken {
            view.focusToken = focusToken
            view.requestKeyboardFocus()
        }
        if layoutChanged { view.needsLayout = true }
        if drawingChanged { renderer?.requestDraw() }
    }

    static func dismantleNSView(_ view: NativeTerminalView, coordinator: ()) { view.detach() }
}

/// The AppKit terminal view: keyboard and input methods, mouse reporting and
/// selection, scrolling, clipboard, links and focus, over a Metal renderer.
@MainActor
final class NativeTerminalView: NSView, @MainActor NSTextInputClient {
    private static let scrollbarWidth: CGFloat = 11
    private static let cursorBlinkInterval: TimeInterval = 0.6
    private static let selectionAutoscrollInterval: TimeInterval = 0.015
    /// Ghostty's mouse-scroll-multiplier.discrete: rows per wheel detent.
    private static let wheelRowsPerDetent: CGFloat = 3
    /// Bounds a single scroll event, so a runaway delta cannot flood the program.
    private static let maximumScrollUnits: CGFloat = 100

    let engine: TerminalEngine
    let metal = TerminalMetalView()
    var renderer: MetalTerminalRenderer?
    private let scrollbar = NSScroller()
    private let dimmer = PassthroughView()
    private let composition = NSTextField(labelWithString: "")
    private let copyFeedback = CopyFeedbackView()
    private var feedbackDismissal: Task<Void, Never>?

    var copyOnSelection = false
    var menuItems: [[TerminalMenuItem]] = []
    var pasteboard = NSPasteboard.general
    var onCopy: (String) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var hidePointerWhileTyping = true
    var confirmUnsafePaste = true
    /// Asks whether to paste text that could run commands; answers asynchronously.
    lazy var confirmPaste: (String, @escaping (Bool) -> Void) -> Void = { [weak self] text, answer in
        guard let self else { return answer(false) }
        self.presentPasteConfirmation(text, answer: answer)
    }
    var interactive = true {
        didSet {
            if oldValue && !interactive {
                reportTerminalFocus(false)
                cancelSelectionDrag()
                cancelPeekGesture()
            }
            if interactive != oldValue {
                updateRendererFocus()
                updateCursorBlink()
                updateTrackingAreas()
                updateDimming()
            }
        }
    }
    var focusToken: UUID?
    var wantsKeyboardFocus = false {
        didSet { if wantsKeyboardFocus && !oldValue { requestKeyboardFocus() } }
    }
    var onFocus: () -> Void = {}
    var onRequestEditorFocus: (UUID?) -> Bool = { _ in false }
    var onPeek: (CGFloat, Bool) -> Void = { _, _ in }
    var peekProgress: CGFloat = 0 {
        didSet {
            if peekProgress > 0 && oldValue == 0 {
                cancelSelectionDrag()
                unmarkText()
                pressedKeys.removeAll()
            }
            if (peekProgress == 0) != (oldValue == 0) { updateCursorBlink() }
        }
    }
    var onCellSize: (CGSize) -> Void = { _ in }
    private(set) var selectionAutoscrollTimer: Timer?
    private(set) var cursorBlinkTimer: Timer?

    private var reportedCellSize: CGSize?
    private var frameInfo = ILFrame()
    /// Distance from the view edge to the first cell, wherever the renderer puts it.
    private var gridInset: CGFloat { MetalTerminalRenderer.padding }
    private var paneFocused = true
    private var isFirstResponder = false
    private var unfocusedOpacity: CGFloat = 1
    private var dimmerColor: (background: UInt32, opacity: CGFloat)?
    private var detached = false
    private var keyboardFocusScheduled = false
    private var mouseTracking: NSTrackingArea?
    private var reportedTerminalFocus = false
    private var peekGesture = PeekTouchGesture()

    // Keyboard and input method state.
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    /// Text the input system committed during the current keyDown; nil outside keyDown.
    private var keyTextAccumulator: [String]?
    /// Keys whose press reached the program, so only those send a release.
    private var pressedKeys: Set<UInt16> = []

    // Mouse state.
    private var scrollRemainder = CGPoint.zero
    private var scrollWasPrecise: Bool?
    private var selectionDragEvent: NSEvent?
    /// Shift-click extends the selection instead of starting a new one.
    private var extendingSelection = false
    private var clickFocusesOnly = false
    private var suppressMouseUp = false
    private var hoveringLink = false

    init(engine: TerminalEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        LaunchMetrics.mark("rendererInitStart")
        renderer = MetalTerminalRenderer(engine: engine, view: metal)
        LaunchMetrics.mark("rendererInitEnd")
        metal.onDisplayEnvironmentChange = { [weak self] in
            guard let self else { return }
            if !self.canAutoscrollSelection { self.cancelSelectionDrag() }
            self.needsLayout = true
            self.renderer?.requestDraw()
            self.requestKeyboardFocus()
            self.updateCursorBlink()
        }
        addSubview(metal)
        dimmer.wantsLayer = true
        dimmer.isHidden = true
        addSubview(dimmer)
        scrollbar.scrollerStyle = .overlay
        scrollbar.controlSize = .small
        scrollbar.target = self
        scrollbar.action = #selector(scrollbarChanged)
        scrollbar.isHidden = true
        addSubview(scrollbar)
        composition.isHidden = true
        composition.drawsBackground = true
        composition.isBordered = false
        addSubview(composition)
        copyFeedback.isHidden = true
        addSubview(copyFeedback)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        renderer?.onFrame = { [weak self] frame in self?.didRender(frame) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        cursorBlinkTimer?.invalidate()
        selectionAutoscrollTimer?.invalidate()
        feedbackDismissal?.cancel()
    }

    override var isFlipped: Bool { true }

    // MARK: - Lifecycle and focus

    override var acceptsFirstResponder: Bool { interactive && peekProgress == 0 }

    override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        updateRendererFocus()
        DispatchQueue.main.async { [weak self] in self?.updateCursorBlink() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelSelectionDrag()
        pressedKeys.removeAll(keepingCapacity: true)
        suppressMouseUp = false
        isFirstResponder = false
        updateRendererFocus()
        updateCursorBlink()
        return true
    }

    func detach() {
        wantsKeyboardFocus = false
        detached = true
        cancelSelectionDrag()
        cancelPeekGesture()
        reportTerminalFocus(false)
        feedbackDismissal?.cancel()
        feedbackDismissal = nil
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        renderer?.detach()
        metal.onDisplayEnvironmentChange = nil
        observeWindow(nil)
    }

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ]

    private func observeWindow(_ window: NSWindow?) {
        let center = NotificationCenter.default
        for name in Self.windowNotifications { center.removeObserver(self, name: name, object: nil) }
        guard let window else { return }
        for name in Self.windowNotifications {
            let selector = name == NSWindow.didBecomeKeyNotification ? #selector(windowBecameKey(_:)) : #selector(displayEnvironmentChanged(_:))
            center.addObserver(self, selector: selector, name: name, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelSelectionDrag()
            cancelPeekGesture()
        }
        observeWindow(window)
        updateRendererFocus()
        needsLayout = true
        requestKeyboardFocus()
        renderer?.requestDraw()
        updateCursorBlink()
    }

    /// Takes keyboard focus once AppKit and SwiftUI have settled, without
    /// stealing it from a text field the user is editing.
    func requestKeyboardFocus() {
        guard interactive, wantsKeyboardFocus, !keyboardFocusScheduled else { return }
        keyboardFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyboardFocusScheduled = false
            guard self.interactive, self.peekProgress == 0, self.wantsKeyboardFocus, !self.isHiddenOrHasHiddenAncestor,
                  let window = self.window, window.attachedSheet == nil else { return }
            let replaceEditor = self.onRequestEditorFocus(self.focusToken)
            guard window.firstResponder !== self else { return }
            // Mounting or reactivating a terminal must preserve an editor that
            // already acquired focus, even before SwiftUI updates its flags.
            if let responder = window.firstResponder, responder is NSTextView || responder is NSControl, !replaceEditor { return }
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        requestKeyboardFocus()
        displayEnvironmentChanged(notification)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateCursorBlink()
        renderer?.requestDraw()
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelSelectionDrag()
        cancelPeekGesture()
        updateCursorBlink()
        renderer?.requestDraw()
    }

    @objc private func displayEnvironmentChanged(_ notification: Notification) {
        needsLayout = true
        updateRendererFocus()
        if notification.name == NSWindow.didResignKeyNotification || window?.occlusionState.contains(.visible) != true {
            cancelSelectionDrag()
            cancelPeekGesture()
        }
        updateCursorBlink()
        renderer?.requestDraw()
    }

    private var isKeyboardFocused: Bool {
        !detached && peekProgress == 0 && !isHiddenOrHasHiddenAncestor && window?.isKeyWindow == true && window?.firstResponder === self
    }

    private var canBlinkCursor: Bool {
        interactive && isKeyboardFocused && renderer?.focused == true && frameInfo.cursorBlinking && frameInfo.cursorVisible
            && !metal.isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true
    }

    private func reportTerminalFocus(_ focused: Bool) {
        guard reportedTerminalFocus != focused else { return }
        reportedTerminalFocus = focused
        engine.focusChanged(focused)
    }

    /// Keeps focus reports and the cursor blink timer in step with visibility
    /// and focus. The timer only exists while it can change what is visible.
    func updateCursorBlink(reset: Bool = false) {
        if interactive { reportTerminalFocus(isKeyboardFocused) }
        guard canBlinkCursor else {
            cursorBlinkTimer?.invalidate()
            cursorBlinkTimer = nil
            if renderer?.cursorOn == false {
                renderer?.cursorOn = true
                renderer?.requestDraw()
            }
            return
        }
        if let cursorBlinkTimer {
            if reset { cursorBlinkTimer.fireDate = Date(timeIntervalSinceNow: Self.cursorBlinkInterval) }
            return
        }
        let timer = Timer(timeInterval: Self.cursorBlinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canBlinkCursor else {
                    self.updateCursorBlink()
                    return
                }
                self.renderer?.cursorOn.toggle()
                self.renderer?.requestDraw()
            }
        }
        // Cursor phase is cosmetic. Let the system coalesce its only idle wake.
        timer.tolerance = 0.06
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    /// Whether this pane is the workspace's focused pane, and how far to fade it otherwise.
    func setPaneFocus(_ focused: Bool, unfocusedOpacity: CGFloat) {
        paneFocused = focused
        self.unfocusedOpacity = min(1, max(0, unfocusedOpacity))
        updateRendererFocus()
        updateDimming()
    }

    /// Like Ghostty, only the focused pane of the key window draws a solid
    /// cursor; every other terminal shows a hollow one.
    private func updateRendererFocus() {
        let focused = interactive ? paneFocused && isFirstResponder && window?.isKeyWindow == true : paneFocused
        guard let renderer, renderer.focused != focused else { return }
        renderer.focused = focused
        renderer.requestDraw()
    }

    var isDimmed: Bool { !dimmer.isHidden }

    private func updateDimming() {
        let dimmed = interactive && !paneFocused && unfocusedOpacity < 1
        dimmer.isHidden = !dimmed
        let background = engine.theme.background
        guard dimmed, dimmerColor?.background != background || dimmerColor?.opacity != unfocusedOpacity else { return }
        dimmerColor = (background, unfocusedOpacity)
        dimmer.layer?.backgroundColor = NSColor(hex: background).withAlphaComponent(1 - unfocusedOpacity).cgColor
    }

    // MARK: - Layout and frames

    override func layout() {
        super.layout()
        // Fractional split positions must not stretch the drawable or place
        // every glyph between physical pixels during compositing.
        metal.frame = backingAlignedRect(bounds, options: .alignAllEdgesNearest)
        dimmer.frame = bounds
        scrollbar.frame = NSRect(x: bounds.width - Self.scrollbarWidth, y: 0, width: Self.scrollbarWidth, height: bounds.height)
        copyFeedback.frame = bounds
        if let cell = renderer?.cell, cell != reportedCellSize {
            reportedCellSize = cell
            DispatchQueue.main.async { [weak self] in self?.onCellSize(cell) }
        }
        if interactive, let cell = renderer?.cell, let grid = Self.gridSize(for: metal.bounds.size, inset: gridInset, cell: cell) {
            let scale = window?.backingScaleFactor ?? 2
            engine.requestResize(columns: grid.columns, rows: grid.rows,
                                 cellWidth: UInt32((cell.width * scale).rounded()), cellHeight: UInt32((cell.height * scale).rounded()))
        }
        updateComposition()
        LaunchMetrics.mark("surfaceLaidOut")
        renderer?.requestDraw()
    }

    /// The grid that fits inside the content insets, clamped to what the service accepts.
    private static func gridSize(for size: CGSize, inset: CGFloat, cell: CGSize) -> (columns: UInt16, rows: UInt16)? {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let columns = ((size.width - 2 * inset) / cell.width).rounded(.down)
        let rows = ((size.height - 2 * inset) / cell.height).rounded(.down)
        guard columns.isFinite, rows.isFinite else { return nil }
        return (UInt16(min(1000, max(2, columns))), UInt16(min(1000, max(1, rows))))
    }

    private func didRender(_ frame: ILFrame) {
        if engine.stream != nil { LaunchMetrics.mark("firstSnapshotFrameExtracted") }
        frameInfo = frame
        updateCursorBlink()
        let total = Double(frame.scrollTotal), visible = Double(frame.scrollLength)
        let scrollable = interactive && total > visible
        scrollbar.isHidden = !scrollable
        scrollbar.isEnabled = scrollable
        scrollbar.knobProportion = total > 0 ? visible / total : 1
        scrollbar.doubleValue = total > visible ? Double(frame.scrollOffset) / (total - visible) : 1
        updateComposition()
        updateDimming()
    }

    override func accessibilityValue() -> Any? {
        guard interactive, let frame = engine.frame(), let cells = frame.cells else { return "" }
        var lines = [String](repeating: "", count: Int(frame.rows))
        for index in 0..<frame.count {
            let cell = cells[index]
            guard cell.width > 0, Int(cell.row) < lines.count else { continue }
            let text = Self.text(of: cell)
            lines[Int(cell.row)] += text.isEmpty ? " " : text
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    private static func text(of cell: ILCell) -> String {
        withUnsafeBytes(of: cell.text) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @objc private func scrollbarChanged() {
        let range = frameInfo.scrollTotal > frameInfo.scrollLength ? frameInfo.scrollTotal - frameInfo.scrollLength : 0
        engine.scrollTo(UInt64((Double(range) * scrollbar.doubleValue).rounded()))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        guard peekProgress == 0 else {
            if Int(event.keyCode) == kVK_Escape {
                cancelPeekGesture(reset: false)
                onPeek(0, true)
            }
            return
        }
        renderer?.cursorOn = true
        updateCursorBlink(reset: true)
        pressedKeys.remove(event.keyCode)

        // Option acting as Alt must not compose characters, so the input
        // system sees the event without it. Ghostty reuses the original event
        // whenever it can: some input methods depend on its identity.
        let translation = engine.translationModifiers(event.modifierFlags)
        let translationEvent = translation == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translation, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: translation) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let markedBefore = hasMarkedText()
        keyTextAccumulator = []
        interpretKeyEvents([translationEvent])
        let committed = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        // A key that ends a composition belongs to the input method too.
        let composing = hasMarkedText() || markedBefore

        if markedBefore && !committed.isEmpty {
            // The input method committed its text while handling this key;
            // the key itself was consumed, except movement after a commit.
            for text in committed where !Self.isControlText(text) { engine.typeText(text) }
            if Self.replaysAfterCommit(event) { sendKey(event, translation: translation) }
            return
        }
        if committed.isEmpty {
            if composing && Self.isControlText(event.characters) { return }
            sendKey(event, translation: translation, composing: composing)
        } else {
            for text in committed where !(composing && Self.isControlText(text)) {
                // Let the encoder derive control characters from the key.
                sendKey(event, translation: translation, text: Self.isControlText(text) ? nil : text)
            }
        }
    }

    private func sendKey(_ event: NSEvent, translation: NSEvent.ModifierFlags, text: String? = nil, composing: Bool = false) {
        guard case .sent(let typed) = engine.key(event, text: text, translation: translation, composing: composing) else { return }
        pressedKeys.insert(event.keyCode)
        // Ghostty's mouse-hide-while-typing; the pointer returns when the mouse moves.
        if typed && hidePointerWhileTyping && !event.isARepeat && NSApp.isActive { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// A single C0 control character, which an input method may produce while composing.
    private static func isControlText(_ text: String?) -> Bool {
        guard let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else { return false }
        return scalar.value < 0x20
    }

    /// Arrows still move after a Korean-style commit; plain Left does not,
    /// because AppKit already leaves the caret in place.
    private static func replaysAfterCommit(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow, kVK_RightArrow: true
        case kVK_LeftArrow: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: false
        }
    }

    override func keyUp(with event: NSEvent) {
        // Menu shortcuts and composed keys never sent a press, so they send no release.
        guard pressedKeys.remove(event.keyCode) != nil, interactive, peekProgress == 0, !hasMarkedText() else { return }
        engine.key(event, action: .release)
    }

    /// Control chords reach the terminal before AppKit's key equivalents
    /// (which would, for example, beep on Control-/). Control-Tab and
    /// Control-Shift-Tab stay with the tab menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard interactive, peekProgress == 0, window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if Int(event.keyCode) == kVK_Tab && (modifiers == .control || modifiers == [.control, .shift]) { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        updatePointer()
        guard interactive, peekProgress == 0, !hasMarkedText(), let pressed = Self.modifierKeyIsDown(event) else { return }
        engine.key(event, action: pressed ? .press : .release)
    }

    /// Whether a modifier key went down, telling the two sides apart: with
    /// both Shift keys held, releasing one still leaves `.shift` set.
    private static func modifierKeyIsDown(_ event: NSEvent) -> Bool? {
        // NX_DEVICE*KEYMASK bits from IOLLEvent.h.
        let key: (flag: NSEvent.ModifierFlags, sideMask: UInt?)? = switch Int(event.keyCode) {
        case kVK_CapsLock: (.capsLock, nil)
        case kVK_Shift: (.shift, 0x02)
        case kVK_RightShift: (.shift, 0x04)
        case kVK_Control: (.control, 0x01)
        case kVK_RightControl: (.control, 0x2000)
        case kVK_Option: (.option, 0x20)
        case kVK_RightOption: (.option, 0x40)
        case kVK_Command: (.command, 0x08)
        case kVK_RightCommand: (.command, 0x10)
        default: nil
        }
        guard let (flag, sideMask) = key else { return nil }
        guard event.modifierFlags.contains(flag) else { return false }
        // Synthetic events carry no device bits; trust the flag alone then.
        let deviceBits: UInt = 0x207f
        guard let sideMask, event.modifierFlags.rawValue & deviceBits != 0 else { return true }
        return event.modifierFlags.rawValue & sideMask != 0
    }

    /// Commands the input system maps keys to (insertNewline:, cancelOperation:,
    /// moveLeft:...) are handled by keyDown's encoder path. Overriding this
    /// keeps AppKit from beeping or sending them up the responder chain.
    override func doCommand(by selector: Selector) {}

    // MARK: - Input methods

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard interactive, peekProgress == 0 else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Dictation, the character viewer and input methods outside a key press.
        engine.typeText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard interactive, peekProgress == 0 else { return }
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        markedSelection = selectedRange
        // Ghostty's selection-clear-on-typing covers composing too.
        if markedText.length > 0 { engine.clearSelection() }
        updateComposition()
    }

    func unmarkText() {
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        updateComposition()
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { markedSelection }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor, .backgroundColor] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where input method candidate windows go: the terminal cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cell = renderer?.cell else { return .zero }
        return window.convertToScreen(convert(cursorRect(cell: cell), to: nil))
    }

    private func cursorRect(cell: CGSize) -> NSRect {
        NSRect(x: metal.frame.minX + gridInset + CGFloat(frameInfo.cursorColumn) * cell.width,
               y: metal.frame.minY + gridInset + CGFloat(frameInfo.cursorRow) * cell.height,
               width: cell.width, height: cell.height)
    }

    /// Shows in-progress input method text over the cursor.
    private func updateComposition() {
        guard let cell = renderer?.cell else { return }
        composition.isHidden = !hasMarkedText()
        guard hasMarkedText() else { return }
        composition.stringValue = markedText.string
        composition.font = renderer?.font
        composition.textColor = NSColor(hex: engine.theme.foreground)
        composition.backgroundColor = NSColor(hex: engine.theme.background)
        var frame = cursorRect(cell: cell)
        frame.size.width = max(cell.width, CGFloat(markedText.length + 1) * cell.width)
        composition.frame = frame
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        guard interactive, peekProgress == 0, let text = engine.copy(), !text.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        onCopy(text)
        showCopyFeedback()
    }

    @objc func paste(_ sender: Any?) {
        guard interactive, peekProgress == 0, let text = Self.pasteText(from: pasteboard), !text.isEmpty else { return }
        guard confirmUnsafePaste, engine.pasteNeedsConfirmation(text) else {
            engine.paste(text)
            return
        }
        confirmPaste(text) { [weak self] approved in
            if approved { self?.engine.paste(text) }
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard interactive, peekProgress == 0 else { return }
        engine.selectAll()
    }

    /// Like Ghostty: copied files paste as shell-escaped paths, anything else as text.
    private static func pasteText(from pasteboard: NSPasteboard) -> String? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map { shellEscaped($0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    private static func shellEscaped(_ path: String) -> String {
        let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    private func presentPasteConfirmation(_ text: String, answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Paste text that may run commands?"
        alert.informativeText = "The clipboard contains a line break, so pasting it may run a command immediately.\n\n"
            + String(text.prefix(400))
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        guard let window else {
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactive, peekProgress == 0 else { return nil }
        let menu = NSMenu()
        // Services, AutoFill and Writing Tools have nothing to offer a terminal.
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        for (title, action, key) in [("Copy", #selector(copy(_:)), "c"), ("Paste", #selector(paste(_:)), "v"),
                                     ("Select All", #selector(selectAll(_:)), "a")] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        for group in menuItems where !group.isEmpty {
            menu.addItem(.separator())
            group.forEach { menu.addItem(ClosureMenuItem($0)) }
        }
        return menu
    }

    // MARK: - Mouse

    /// A point in the cell grid's coordinate space, in points.
    private func gridPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - metal.frame.minX - gridInset, y: point.y - metal.frame.minY - gridInset)
    }

    /// A grid point clamped into the grid, for protocols that cannot express
    /// positions outside it.
    private func clampedGridPoint(_ event: NSEvent) -> CGPoint {
        let point = gridPoint(event)
        return CGPoint(x: max(0, point.x), y: max(0, point.y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        mouseTracking = nil
        guard interactive else { return }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }

    override func cursorUpdate(with event: NSEvent) { updatePointer() }

    /// I-beam over text; a pointing hand over a link while Command is held.
    private func updatePointer() {
        guard interactive, let window, let cell = renderer?.cell else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location) else { return }
        let point = CGPoint(x: location.x - metal.frame.minX - gridInset, y: location.y - metal.frame.minY - gridInset)
        hoveringLink = NSEvent.modifierFlags.contains(.command) && engine.link(at: point, cellSize: cell) != nil
        (hoveringLink ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive, peekProgress == 0, let cell = renderer?.cell else { return }
        if event.modifierFlags.contains(.command) || hoveringLink { updatePointer() }
        guard !event.modifierFlags.contains(.shift) else { return }
        _ = reportMouse(event, .motion, button: .unknown, cell: cell)
    }

    /// Sends a mouse report in device pixels. Returns true when the program owns the mouse.
    private func reportMouse(_ event: NSEvent, _ action: ILMouseAction, button: ILMouseButton, cell: CGSize) -> Bool {
        let scale = window?.backingScaleFactor ?? 2
        let point = clampedGridPoint(event)
        return engine.mouse(action, button: button, modifiers: event.modifierFlags,
                            at: CGPoint(x: point.x * scale, y: point.y * scale),
                            cell: CGSize(width: cell.width * scale, height: cell.height * scale))
    }

    /// Reports right, middle and extra buttons; Shift keeps them local.
    private func reportOtherButton(_ event: NSEvent, _ action: ILMouseAction, button: ILMouseButton) -> Bool {
        guard interactive, peekProgress == 0, !event.modifierFlags.contains(.shift), let cell = renderer?.cell else { return false }
        if action == .press {
            window?.makeFirstResponder(self)
            onFocus()
        }
        return reportMouse(event, action, button: button, cell: cell)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !reportOtherButton(event, .press, button: .right) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !reportOtherButton(event, .release, button: .right) { super.rightMouseUp(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !reportOtherButton(event, .motion, button: .right) { super.rightMouseDragged(with: event) }
    }

    /// AppKit numbers middle as 2, then back and forward from 3.
    private static func otherButton(_ event: NSEvent) -> ILMouseButton {
        switch event.buttonNumber {
        case 2: .middle
        case 3: .back
        case 4: .forward
        case 5: .ten
        case 6: .eleven
        default: .unknown
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !reportOtherButton(event, .press, button: Self.otherButton(event)) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !reportOtherButton(event, .release, button: Self.otherButton(event)) { super.otherMouseUp(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !reportOtherButton(event, .motion, button: Self.otherButton(event)) { super.otherMouseDragged(with: event) }
    }

    /// The click that activates an inactive window only focuses the pane.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        clickFocusesOnly = !NSApp.isActive || window?.isKeyWindow != true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        stopSelectionAutoscroll()
        selectionDragEvent = nil
        extendingSelection = false
        suppressMouseUp = false
        // Like Ghostty, a click that moves focus to this pane is not also a
        // click in the program or the start of a selection.
        let focusesOnly = clickFocusesOnly || (window?.isKeyWindow == true && window?.firstResponder !== self)
        clickFocusesOnly = false
        guard interactive, let cell = renderer?.cell else { return }
        if peekProgress > 0 {
            cancelPeekGesture(reset: false)
            onPeek(0, true)
            return
        }
        window?.makeFirstResponder(self)
        onFocus()
        if focusesOnly {
            suppressMouseUp = true
            return
        }
        let point = clampedGridPoint(event)
        if event.modifierFlags.contains(.command), let url = engine.link(at: point, cellSize: cell) {
            cancelSelectionDrag()
            suppressMouseUp = true
            onLink(url)
            openURL(url)
            return
        }
        if !event.modifierFlags.contains(.shift), reportMouse(event, .press, button: .left, cell: cell) {
            cancelSelectionDrag()
            return
        }
        if event.modifierFlags.contains(.shift), event.clickCount == 1, engine.extendSelection(to: point, cellSize: cell) {
            extendingSelection = true
        } else {
            engine.select(.press, at: gridPoint(event), cellSize: cell, time: event.timestamp, rectangle: event.modifierFlags.contains(.option))
        }
        selectionDragEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, peekProgress == 0, !suppressMouseUp, let cell = renderer?.cell else { return }
        if !event.modifierFlags.contains(.shift), reportMouse(event, .motion, button: .left, cell: cell) {
            cancelSelectionDrag()
            return
        }
        guard selectionDragEvent != nil else { return }
        selectionDragEvent = event
        if extendingSelection {
            engine.extendSelection(to: clampedGridPoint(event), cellSize: cell)
            return
        }
        engine.select(.drag, at: gridPoint(event), cellSize: cell, time: event.timestamp, rectangle: event.modifierFlags.contains(.option))
        updateSelectionAutoscroll()
    }

    override func mouseUp(with event: NSEvent) {
        stopSelectionAutoscroll()
        selectionDragEvent = nil
        if suppressMouseUp {
            suppressMouseUp = false
            return
        }
        guard interactive, peekProgress == 0, let cell = renderer?.cell else { return }
        if !event.modifierFlags.contains(.shift), reportMouse(event, .release, button: .left, cell: cell) {
            cancelSelectionDrag()
            return
        }
        if extendingSelection {
            extendingSelection = false
        } else {
            engine.select(.release, at: gridPoint(event), cellSize: cell, time: event.timestamp, rectangle: event.modifierFlags.contains(.option))
        }
        if copyOnSelection { copy(nil) }
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard interactive, peekProgress == 0, let cell = renderer?.cell else { return }
        let precise = event.hasPreciseScrollingDeltas
        if scrollWasPrecise != precise || event.phase == .began {
            scrollRemainder = .zero
            scrollWasPrecise = precise
        }
        let rows = Self.scrollUnits(event.scrollingDeltaY, cell: cell.height, precise: precise, vertical: true, remainder: &scrollRemainder.y)
        let columns = Self.scrollUnits(event.scrollingDeltaX, cell: cell.width, precise: precise, vertical: false, remainder: &scrollRemainder.x)
        guard rows != 0 || columns != 0 else { return }
        if !event.modifierFlags.contains(.shift), engine.mouseReporting {
            // The program owns the wheel. Like Ghostty, drop any Shift-made selection.
            engine.clearSelection()
            for _ in 0..<abs(rows) { _ = reportMouse(event, .press, button: rows > 0 ? .wheelUp : .wheelDown, cell: cell) }
            for _ in 0..<abs(columns) { _ = reportMouse(event, .press, button: columns > 0 ? .wheelLeft : .wheelRight, cell: cell) }
        } else if rows != 0, !engine.alternateScroll(rows) {
            engine.scroll(-rows)
        }
    }

    /// Whole rows or columns for a scroll event, carrying the fractional rest.
    /// Positive values scroll toward earlier content (up or left).
    private static func scrollUnits(_ delta: CGFloat, cell: CGFloat, precise: Bool, vertical: Bool, remainder: inout CGFloat) -> Int {
        guard delta.isFinite, delta != 0, cell > 0 else { return 0 }
        if precise {
            remainder += max(-maximumScrollUnits, min(maximumScrollUnits, delta / cell))
        } else if vertical {
            // AppKit reports a slow physical detent as 0.1; Ghostty rounds it
            // out to a whole detent, then applies its discrete multiplier.
            let detents = delta > 0 ? max(1, delta) : min(-1, delta)
            remainder += max(-maximumScrollUnits, min(maximumScrollUnits, detents * wheelRowsPerDetent))
        } else {
            return Int(max(-maximumScrollUnits, min(maximumScrollUnits, delta.rounded())))
        }
        let units = remainder.rounded(.towardZero)
        remainder -= units
        return Int(units)
    }

    // MARK: - Selection autoscroll

    private var canAutoscrollSelection: Bool {
        !detached && interactive && selectionDragEvent != nil && !isHiddenOrHasHiddenAncestor
            && !metal.isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true
    }

    private func stopSelectionAutoscroll() {
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
    }

    private func cancelSelectionDrag() {
        stopSelectionAutoscroll()
        selectionDragEvent = nil
        extendingSelection = false
        engine.cancelSelectionGesture()
    }

    private func updateSelectionAutoscroll() {
        guard canAutoscrollSelection, engine.selectionNeedsAutoscroll else {
            stopSelectionAutoscroll()
            return
        }
        guard selectionAutoscrollTimer == nil else { return }
        // Matches Ghostty's gesture timer. It exists only while a selection is
        // held at a viewport edge, and runs during AppKit event tracking too.
        let timer = Timer(timeInterval: Self.selectionAutoscrollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionAutoscrollTick() }
        }
        timer.tolerance = 0.003
        selectionAutoscrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func selectionAutoscrollTick() {
        guard canAutoscrollSelection, engine.selectionNeedsAutoscroll, let event = selectionDragEvent,
              let cell = renderer?.cell else {
            stopSelectionAutoscroll()
            return
        }
        if !event.modifierFlags.contains(.shift), engine.mouseReporting {
            cancelSelectionDrag()
            return
        }
        let previousDistance = il_terminal_scroll_distance(engine.handle)
        engine.select(.autoscrollTick, at: gridPoint(event), cellSize: cell, time: event.timestamp,
                      rectangle: event.modifierFlags.contains(.option))
        if il_terminal_scroll_distance(engine.handle) == previousDistance {
            stopSelectionAutoscroll()
        } else {
            updateSelectionAutoscroll()
        }
    }

    // MARK: - Peek touches

    private func movePeekGesture(_ event: NSEvent) {
        guard interactive, !detached else { return }
        let contacts = event.touches(matching: .touching, in: self).filter { !$0.isResting }.map {
            PeekTouchGesture.Contact(identity: $0.identity,
                                     position: CGPoint(x: $0.normalizedPosition.x * $0.deviceSize.width,
                                                       y: $0.normalizedPosition.y * $0.deviceSize.height))
        }
        if let update = peekGesture.update(contacts, initialProgress: peekProgress) { onPeek(update.progress, update.finished) }
    }

    private func cancelPeekGesture(reset: Bool = true) {
        if let update = peekGesture.cancel() { onPeek(update.progress, update.finished) }
        if reset { peekGesture = PeekTouchGesture() }
    }

    override func touchesBegan(with event: NSEvent) { movePeekGesture(event) }

    override func touchesMoved(with event: NSEvent) { movePeekGesture(event) }

    override func touchesEnded(with event: NSEvent) {
        guard interactive, !detached else { return }
        let remaining = event.touches(matching: .touching, in: self).count
        if let update = peekGesture.end(remaining: remaining) { onPeek(update.progress, update.finished) }
    }

    override func touchesCancelled(with event: NSEvent) {
        cancelPeekGesture()
        _ = peekGesture.end(remaining: 0)
    }

    // MARK: - Copy feedback

    /// Flashes the copied cells (or shows a badge with Reduce Motion).
    private func showCopyFeedback() {
        guard !detached, !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) == true,
              let frame = engine.frame(), let cells = frame.cells, let cellSize = renderer?.cell else { return }
        let columns = Int(frame.columns)
        var rects: [CGRect] = []
        for row in 0..<Int(frame.rows) {
            var start: Int?
            for column in 0...columns {
                let selected = column < columns && ILCellFlags(rawValue: cells[row * columns + column].flags).contains(.selected)
                if selected && start == nil { start = column }
                if !selected, let first = start {
                    rects.append(CGRect(x: metal.frame.minX + gridInset + CGFloat(first) * cellSize.width,
                                        y: metal.frame.minY + gridInset + CGFloat(row) * cellSize.height,
                                        width: CGFloat(column - first) * cellSize.width, height: cellSize.height))
                    start = nil
                }
            }
        }
        guard !rects.isEmpty else { return }
        feedbackDismissal?.cancel()
        copyFeedback.layer?.removeAllAnimations()
        copyFeedback.rects = rects
        copyFeedback.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        copyFeedback.alphaValue = 1
        copyFeedback.isHidden = false
        copyFeedback.needsDisplay = true
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if !copyFeedback.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                copyFeedback.animator().alphaValue = 0
            }
        }
        feedbackDismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.copyFeedback.isHidden = true
            self.feedbackDismissal = nil
        }
    }
}

/// A decorative overlay that never takes mouse events.
@MainActor
private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class CopyFeedbackView: PassthroughView {
    var rects: [CGRect] = []
    var reduceMotion = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if reduceMotion {
            guard let selection = rects.first else { return }
            let badge = CGRect(x: min(max(8, selection.maxX - 54), max(8, bounds.width - 62)),
                               y: max(4, selection.minY - 23), width: 54, height: 21)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            ("Copied" as NSString).draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 3),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        } else {
            NSColor.white.withAlphaComponent(0.28).setFill()
            for rect in rects { NSBezierPath(rect: rect).fill() }
        }
    }
}
