import AppKit
import MetalKit
import SwiftUI

@MainActor
final class TerminalMetalView: MTKView {
    var onDisplayEnvironmentChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDisplayEnvironmentChange?()
        if window != nil {
            // The parent's attachment callback can precede this child's window
            // and bounds. Wake again after AppKit finishes mounting the subtree.
            DispatchQueue.main.async { [weak self] in self?.onDisplayEnvironmentChange?() }
        }
    }
    override func viewDidUnhide() { super.viewDidUnhide();onDisplayEnvironmentChange?() }
    override func viewDidHide() { super.viewDidHide();onDisplayEnvironmentChange?() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties();onDisplayEnvironmentChange?() }
}

struct TerminalSurface: NSViewRepresentable {
    let engine: TerminalEngine
    let fontSize: CGFloat
    let fontName: String
    let focused: Bool
    let focusToken: UUID
    var interactive = true
    var contrast = true
    var fontOptions: TerminalFontOptions = .defaults
    var onFocus: () -> Void = {}
    var onPeek: (CGFloat, Bool) -> Void = { _, _ in }
    var onCellSize: (CGSize) -> Void = { _ in }
    var copyOnSelection = false
    var onCopy: (String) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }

    func makeNSView(context: Context) -> NativeTerminalView { NativeTerminalView(engine: engine) }
    func updateNSView(_ view: NativeTerminalView, context: Context) {
        view.interactive = interactive;view.onFocus = onFocus;view.onPeek = onPeek;view.onCellSize = onCellSize
        view.copyOnSelection = copyOnSelection;view.onCopy = onCopy;view.onLink = onLink
        view.renderer?.fontSize = fontSize;view.renderer?.fontName = fontName
        view.renderer?.fontOptions = fontOptions
        view.renderer?.interactive = interactive;view.renderer?.contrastCorrection = contrast
        view.renderer?.focused = focused
        view.updateCursorBlink()
        view.wantsKeyboardFocus = interactive && focused
        if interactive && focused && view.focusToken != focusToken {
            view.focusToken = focusToken
            view.requestKeyboardFocus()
        }
        view.needsLayout = true;view.renderer?.requestDraw()
    }
    static func dismantleNSView(_ view: NativeTerminalView, coordinator: ()) { view.detach() }
}

@MainActor
final class NativeTerminalView: NSView, @MainActor NSTextInputClient {
    let engine: TerminalEngine
    let metal = TerminalMetalView()
    private let scrollbar = NSScroller()
    private let composition = NSTextField(labelWithString: "")
    private let copyFeedback = CopyFeedbackView()
    private var feedbackDismissal: Task<Void, Never>?
    var copyOnSelection = false
    var pasteboard = NSPasteboard.general
    var onCopy: (String) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var openedLinkOnMouseDown = false
    var renderer: MetalTerminalRenderer?
    var interactive = true {
        didSet {
            if oldValue && !interactive { reportTerminalFocus(false) }
            if interactive != oldValue { updateCursorBlink();updateTrackingAreas() }
        }
    }
    var focusToken: UUID?
    var wantsKeyboardFocus = false {
        didSet { if wantsKeyboardFocus && !oldValue { requestKeyboardFocus() } }
    }
    var onFocus: () -> Void = {}
    var onPeek: (CGFloat, Bool) -> Void = { _, _ in }
    var onCellSize: (CGSize) -> Void = { _ in }
    private var reportedCellSize: CGSize?
    private var frameInfo = ILFrame()
    private var marked = NSAttributedString(string: "")
    private var insertionEvent: NSEvent?
    private var composingAtKeyDown = false
    private var composingKeyReleases: Set<UInt16> = []
    private var forwardedKeyPresses: Set<UInt16> = []
    private var markedSelection = NSRange(location: 0, length: 0)
    private var scrollRemainder: CGFloat = 0
    private(set) var cursorBlinkTimer: Timer?
    private var detached = false
    private var touchStart: CGFloat?
    private var touchProgress: CGFloat = 0
    private var keyboardFocusScheduled = false
    private var mouseTracking: NSTrackingArea?
    private var reportedTerminalFocus = false

    init(engine: TerminalEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        LaunchMetrics.mark("rendererInitStart")
        renderer = MetalTerminalRenderer(engine: engine, view: metal)
        LaunchMetrics.mark("rendererInitEnd")
        metal.onDisplayEnvironmentChange = { [weak self] in
            self?.renderer?.requestDraw()
            self?.requestKeyboardFocus()
            self?.updateCursorBlink()
        }
        addSubview(metal)
        scrollbar.scrollerStyle = .overlay;scrollbar.controlSize = .small;scrollbar.target = self;scrollbar.action = #selector(scrollbarChanged)
        scrollbar.isHidden = true;addSubview(scrollbar)
        composition.isHidden = true;composition.drawsBackground = true;composition.isBordered = false;addSubview(composition)
        copyFeedback.isHidden = true;addSubview(copyFeedback)
        allowedTouchTypes = [.indirect];wantsRestingTouches = true
        setAccessibilityElement(true);setAccessibilityRole(.textArea);setAccessibilityLabel("Terminal")
        renderer?.onFrame = { [weak self] frame in self?.didRender(frame) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { cursorBlinkTimer?.invalidate();feedbackDismissal?.cancel() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        renderer?.focused = true;renderer?.requestDraw()
        DispatchQueue.main.async { [weak self] in self?.updateCursorBlink() }
        return true
    }
    override func resignFirstResponder() -> Bool {
        forwardedKeyPresses.removeAll(keepingCapacity: true)
        composingKeyReleases.removeAll(keepingCapacity: true)
        renderer?.focused = false;updateCursorBlink();renderer?.requestDraw();return true
    }
    func detach() {
        wantsKeyboardFocus = false
        detached = true
        reportTerminalFocus(false)
        feedbackDismissal?.cancel();feedbackDismissal = nil
        cursorBlinkTimer?.invalidate();cursorBlinkTimer = nil
        renderer?.detach()
        metal.onDisplayEnvironmentChange = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(displayEnvironmentChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(displayEnvironmentChanged(_:)), name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(displayEnvironmentChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
        }
        requestKeyboardFocus()
        renderer?.requestDraw()
        updateCursorBlink()
    }

    func requestKeyboardFocus() {
        guard interactive, wantsKeyboardFocus, !keyboardFocusScheduled else { return }
        keyboardFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyboardFocusScheduled = false
            guard self.interactive, self.wantsKeyboardFocus, !self.isHiddenOrHasHiddenAncestor,
                  let window = self.window, window.attachedSheet == nil,
                  window.firstResponder !== self else { return }
            // Mounting or reactivating a terminal must preserve an editor that
            // already acquired focus, even before SwiftUI updates its flags.
            if let responder = window.firstResponder, responder is NSTextView || responder is NSControl { return }
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        requestKeyboardFocus();displayEnvironmentChanged(notification)
    }

    override func viewDidUnhide() { super.viewDidUnhide();updateCursorBlink();renderer?.requestDraw() }
    override func viewDidHide() { super.viewDidHide();updateCursorBlink();renderer?.requestDraw() }
    @objc private func displayEnvironmentChanged(_ notification: Notification) {
        updateCursorBlink();renderer?.requestDraw()
    }

    private var canBlinkCursor: Bool {
        !detached && interactive && renderer?.focused == true && frameInfo.cursorBlinking
            && frameInfo.cursorVisible && !isHiddenOrHasHiddenAncestor && !metal.isHiddenOrHasHiddenAncestor
            && window?.isKeyWindow == true && window?.firstResponder === self
            && window?.occlusionState.contains(.visible) == true
    }

    private func reportTerminalFocus(_ focused: Bool) {
        guard reportedTerminalFocus != focused else { return }
        reportedTerminalFocus = focused
        engine.focusChanged(focused)
    }

    func updateCursorBlink(reset: Bool = false) {
        if interactive {
            reportTerminalFocus(!detached && !isHiddenOrHasHiddenAncestor && window?.isKeyWindow == true && window?.firstResponder === self)
        }
        guard canBlinkCursor else {
            cursorBlinkTimer?.invalidate();cursorBlinkTimer = nil
            if renderer?.cursorOn == false { renderer?.cursorOn = true;renderer?.requestDraw() }
            return
        }
        if let cursorBlinkTimer {
            if reset { cursorBlinkTimer.fireDate = Date(timeIntervalSinceNow: 0.6) }
            return
        }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canBlinkCursor else { self.updateCursorBlink();return }
                self.renderer?.cursorOn.toggle();self.renderer?.requestDraw()
            }
        }
        // Cursor phase is cosmetic. Let the system coalesce its only idle wake.
        timer.tolerance = 0.06
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    override func layout() {
        super.layout();metal.frame = bounds;scrollbar.frame = NSRect(x:bounds.width-11,y:0,width:11,height:bounds.height)
        copyFeedback.frame = bounds
        if let cell = renderer?.cell, cell != reportedCellSize {
            reportedCellSize = cell
            DispatchQueue.main.async { [weak self] in self?.onCellSize(cell) }
        }
        if interactive, let cell=renderer?.cell {
            let cols=UInt16(max(2,min(1000,Int((bounds.width-16)/cell.width))))
            let rows=UInt16(max(1,min(1000,Int((bounds.height-16)/cell.height))))
            let scale=window?.backingScaleFactor ?? 2
            engine.requestResize(columns:cols,rows:rows,cellWidth:UInt32(cell.width*scale),cellHeight:UInt32(cell.height*scale))
        }
        updateComposition()
        LaunchMetrics.mark("surfaceLaidOut")
        renderer?.requestDraw()
    }

    private func didRender(_ frame: ILFrame) {
        if engine.stream != nil { LaunchMetrics.mark("firstSnapshotFrameExtracted") }
        frameInfo=frame
        updateCursorBlink()
        let total=Double(frame.scrollTotal),length=Double(frame.scrollLength)
        scrollbar.isHidden = !interactive || total<=length
        scrollbar.isEnabled = interactive && total > length
        scrollbar.knobProportion=total>0 ? length/total : 1
        scrollbar.doubleValue=total>length ? Double(frame.scrollOffset)/(total-length) : 1
        updateComposition()
    }

    override func accessibilityValue() -> Any? {
        guard interactive, let frame = engine.frame(), let cells = frame.cells else { return "" }
        var lines = [String](repeating: "", count: Int(frame.rows))
        for index in 0..<frame.count {
            var cell = cells[index]
            guard cell.width > 0, Int(cell.row) < lines.count else { continue }
            let text = withUnsafePointer(to: &cell.text) {
                $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            lines[Int(cell.row)] += text.isEmpty ? " " : text
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    @objc private func scrollbarChanged() {
        let range=frameInfo.scrollTotal>frameInfo.scrollLength ? frameInfo.scrollTotal-frameInfo.scrollLength : 0
        engine.scrollTo(UInt64(Double(range)*scrollbar.doubleValue))
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else{return}
        renderer?.cursorOn=true
        updateCursorBlink(reset: true)
        composingKeyReleases.remove(event.keyCode)
        forwardedKeyPresses.remove(event.keyCode)
        if !hasMarkedText(), event.modifierFlags.contains(.control) || event.characters?.unicodeScalars.first.map({(0xf700...0xf8ff).contains($0.value)}) == true {
            forwardKeyDown(event);return
        }
        composingAtKeyDown = hasMarkedText()
        insertionEvent=event
        defer { insertionEvent=nil; composingAtKeyDown=false }
        interpretKeyEvents([event])
        if composingAtKeyDown || hasMarkedText() { composingKeyReleases.insert(event.keyCode) }
    }
    override func keyUp(with event: NSEvent) {
        let forwarded = forwardedKeyPresses.remove(event.keyCode) != nil
        let composed = composingKeyReleases.remove(event.keyCode) != nil
        guard interactive, forwarded, !composed, !hasMarkedText() else { return }
        engine.key(event,release:true)
    }

    private func forwardKeyDown(_ event: NSEvent, text: String? = nil) {
        forwardedKeyPresses.insert(event.keyCode)
        engine.key(event, text: text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard interactive, window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard interactive, !hasMarkedText() else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 57: flag = .capsLock
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        default: return
        }
        engine.key(event, release: !event.modifierFlags.contains(flag))
    }

    override func doCommand(by selector: Selector) {
        if !composingAtKeyDown, !hasMarkedText(), let event=insertionEvent { forwardKeyDown(event) }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text=(string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasMarked=hasMarkedText() || composingAtKeyDown;unmarkText()
        if wasMarked, text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return }
        if let event=insertionEvent,!wasMarked{forwardKeyDown(event,text:text)}else{engine.send(Data(text.utf8))}
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked=(string as? NSAttributedString) ?? NSAttributedString(string:string as? String ?? "")
        markedSelection = selectedRange
        updateComposition()
    }
    func unmarkText(){marked=NSAttributedString(string:"");markedSelection=NSRange(location:0,length:0);updateComposition()}
    func hasMarkedText()->Bool{marked.length>0}
    func markedRange()->NSRange{hasMarkedText() ? NSRange(location:0,length:marked.length) : NSRange(location:NSNotFound,length:0)}
    func selectedRange()->NSRange{markedSelection}
    func validAttributesForMarkedText()->[NSAttributedString.Key]{[.underlineStyle,.foregroundColor,.backgroundColor]}
    func attributedSubstring(forProposedRange range:NSRange,actualRange:NSRangePointer?)->NSAttributedString?{nil}
    func characterIndex(for point:NSPoint)->Int{0}
    func firstRect(forCharacterRange range:NSRange,actualRange:NSRangePointer?)->NSRect{
        guard let window,let cell=renderer?.cell else{return .zero}
        let rect=NSRect(x:8+CGFloat(frameInfo.cursorColumn)*cell.width,y:8+CGFloat(frameInfo.cursorRow)*cell.height,width:cell.width,height:cell.height)
        return window.convertToScreen(convert(rect,to:nil))
    }
    private func updateComposition(){
        guard let cell=renderer?.cell else{return}
        composition.isHidden = !hasMarkedText();composition.stringValue=marked.string;composition.font=renderer?.font
        composition.textColor=NSColor(hex:engine.theme.foreground);composition.backgroundColor=NSColor(hex:engine.theme.background)
        composition.frame=NSRect(x:8+CGFloat(frameInfo.cursorColumn)*cell.width,y:8+CGFloat(frameInfo.cursorRow)*cell.height,width:max(cell.width,CGFloat(marked.length+1)*cell.width),height:cell.height)
    }

    @objc func copy(_ sender: Any?) {
        guard interactive, let text = engine.copy(), !text.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        onCopy(text);showCopyFeedback()
    }
    @objc func paste(_ sender: Any?) { if let text=pasteboard.string(forType:.string){engine.paste(text)} }
    @objc override func selectAll(_ sender: Any?) { engine.selectAll() }

    private func localPoint(_ event:NSEvent)->NSPoint{let p=convert(event.locationInWindow,from:nil);return NSPoint(x:max(0,p.x-8),y:max(0,p.y-8))}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        mouseTracking = nil
        if interactive {
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(tracking);mouseTracking = tracking
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard interactive, !event.modifierFlags.contains(.shift), let cell = renderer?.cell else { return }
        _ = terminalMouse(event, action: 2, button: 0, point: localPoint(event), cell: cell)
    }
    private func terminalMouse(_ event: NSEvent, action: Int32, button: Int32, point: NSPoint, cell: NSSize) -> Bool {
        let scale = window?.backingScaleFactor ?? 2
        return engine.mouse(event, action: action, button: button,
                            point: NSPoint(x: point.x * scale, y: point.y * scale),
                            cell: NSSize(width: cell.width * scale, height: cell.height * scale))
    }
    private func sendMouse(_ event: NSEvent, action: Int32, button: Int32) -> Bool {
        guard interactive, !event.modifierFlags.contains(.shift), let cell = renderer?.cell else { return false }
        if action == 0 { window?.makeFirstResponder(self);onFocus() }
        return terminalMouse(event, action: action, button: button, point: localPoint(event), cell: cell)
    }
    override func rightMouseDown(with event: NSEvent) { if !sendMouse(event, action: 0, button: 2) { super.rightMouseDown(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !sendMouse(event, action: 1, button: 2) { super.rightMouseUp(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if !sendMouse(event, action: 2, button: 2) { super.rightMouseDragged(with: event) } }
    private func extraMouseButton(_ event: NSEvent) -> Int32 { event.buttonNumber == 2 ? 3 : Int32(event.buttonNumber + 5) }
    override func otherMouseDown(with event: NSEvent) { if !sendMouse(event, action: 0, button: extraMouseButton(event)) { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !sendMouse(event, action: 1, button: extraMouseButton(event)) { super.otherMouseUp(with: event) } }
    override func otherMouseDragged(with event: NSEvent) { if !sendMouse(event, action: 2, button: extraMouseButton(event)) { super.otherMouseDragged(with: event) } }
    override func mouseDown(with event:NSEvent){
        guard interactive,let cell=renderer?.cell else{return};window?.makeFirstResponder(self);onFocus()
        let point=localPoint(event);openedLinkOnMouseDown = false
        if event.modifierFlags.contains(.command),let url=engine.link(at:point,cell:cell){openedLinkOnMouseDown = true;onLink(url);openURL(url);return}
        if !event.modifierFlags.contains(.shift),terminalMouse(event,action:0,button:1,point:point,cell:cell){return}
        engine.select(event,action:0,point:point,cell:cell)
    }
    override func mouseDragged(with event:NSEvent){
        guard interactive,let cell=renderer?.cell else{return};let point=localPoint(event)
        if !event.modifierFlags.contains(.shift),terminalMouse(event,action:2,button:1,point:point,cell:cell){return}
        engine.select(event,action:1,point:point,cell:cell)
    }
    override func mouseUp(with event:NSEvent){
        if openedLinkOnMouseDown { openedLinkOnMouseDown = false;return }
        guard interactive,let cell=renderer?.cell else{return};let point=localPoint(event)
        if !event.modifierFlags.contains(.shift),terminalMouse(event,action:1,button:1,point:point,cell:cell){return}
        engine.select(event,action:2,point:point,cell:cell)
        if copyOnSelection { copy(nil) }
    }
    override func scrollWheel(with event:NSEvent){
        guard interactive,let cell=renderer?.cell else{return}
        scrollRemainder += event.scrollingDeltaY/(event.hasPreciseScrollingDeltas ? cell.height : 1)
        let rows=Int(scrollRemainder);guard rows != 0 else{return};scrollRemainder -= CGFloat(rows)
        let point=localPoint(event)
        if !event.modifierFlags.contains(.shift),terminalMouse(event,action:0,button:rows>0 ? 4 : 5,point:point,cell:cell){
            for _ in 1..<max(1,min(100,abs(rows))){_ = terminalMouse(event,action:0,button:rows>0 ? 4 : 5,point:point,cell:cell)}
        }else{engine.scroll(-rows)}
    }
    override func menu(for event:NSEvent)->NSMenu?{
        guard interactive else{return nil};let menu=NSMenu();menu.addItem(withTitle:"Copy",action:#selector(copy(_:)),keyEquivalent:"");menu.addItem(withTitle:"Paste",action:#selector(paste(_:)),keyEquivalent:"");menu.addItem(withTitle:"Select All",action:#selector(selectAll(_:)),keyEquivalent:"");for item in menu.items{item.target=self};return menu
    }
    override func touchesBegan(with event:NSEvent){
        let touches=event.touches(matching:.touching,in:self)
        if touches.count==3{touchStart=touches.reduce(0){$0+$1.normalizedPosition.y}/3;touchProgress=0}
    }
    override func touchesMoved(with event:NSEvent){
        let touches=event.touches(matching:.touching,in:self)
        guard interactive,touches.count==3,let start=touchStart else{return}
        let average=touches.reduce(0){$0+$1.normalizedPosition.y}/3
        touchProgress=min(2,max(0,(start-average)*8));onPeek(touchProgress,false)
    }
    override func touchesEnded(with event:NSEvent){if touchStart != nil{onPeek(touchProgress,true);touchStart=nil}}
    override func touchesCancelled(with event:NSEvent){if touchStart != nil{onPeek(0,true);touchStart=nil}}

    private func showCopyFeedback() {
        guard !detached, !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) == true,
              let frame = engine.frame(), let cells = frame.cells,
              let cellSize = renderer?.cell else { return }
        var rects: [CGRect] = []
        for row in 0..<Int(frame.rows) {
            var start: Int?
            for column in 0...Int(frame.columns) {
                let selected = column < Int(frame.columns) && (cells[row * Int(frame.columns) + column].flags & 8) != 0
                if selected && start == nil { start = column }
                if !selected, let first = start {
                    rects.append(CGRect(x: 8 + CGFloat(first) * cellSize.width, y: 8 + CGFloat(row) * cellSize.height,
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
        copyFeedback.alphaValue = 1;copyFeedback.isHidden = false;copyFeedback.needsDisplay = true
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
            self.copyFeedback.isHidden = true;self.feedbackDismissal = nil
        }
    }
}

@MainActor
private final class CopyFeedbackView: NSView {
    var rects: [CGRect] = []
    var reduceMotion = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if reduceMotion {
            guard let selection = rects.first else { return }
            let badge = CGRect(x: min(max(8, selection.maxX - 54), max(8, bounds.width - 62)),
                               y: max(4, selection.minY - 23), width: 54, height: 21)
            NSColor.windowBackgroundColor.setFill();NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            ("Copied" as NSString).draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 3),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        } else {
            NSColor.white.withAlphaComponent(0.28).setFill()
            for rect in rects { NSBezierPath(rect: rect).fill() }
        }
    }
}
