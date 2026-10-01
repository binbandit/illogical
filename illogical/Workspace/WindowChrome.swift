import AppKit
import SwiftUI

/// Empty titlebar space: dragging moves the window and double-clicking does
/// what the user chose in System Settings (zoom, minimise or nothing).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { Self.performDoubleClickAction(on: window) } else { window.performDrag(with: event) }
        }

        static func performDoubleClickAction(on window: NSWindow) {
            let defaults = UserDefaults.standard
            switch defaults.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"): window.miniaturize(nil)
            default: window.zoom(nil)
            }
        }
    }
}

/// Connects a workspace window to its model: window styling, title,
/// translucency, close confirmations, activation and closing.
struct WindowConfigurator: NSViewRepresentable {
    let model: WorkspaceModel
    let title: String
    let colors: ChromeColors
    /// Where the traffic lights centre vertically: the titlebar's height.
    let titlebarHeight: CGFloat
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model, isFullScreen: $isFullScreen) }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = { [coordinator = context.coordinator] window in coordinator.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        context.coordinator.titlebarHeight = titlebarHeight
        context.coordinator.apply(title: title, colors: colors)
    }

    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        let model: WorkspaceModel
        var isFullScreen: Binding<Bool>
        var titlebarHeight = Chrome.Titlebar.height { didSet { if titlebarHeight != oldValue { placeTrafficLights() } } }
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var title = ""
        private var colors: ChromeColors?

        init(model: WorkspaceModel, isFullScreen: Binding<Bool>) {
            self.model = model
            self.isFullScreen = isFullScreen
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            model.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let frame = WorkspaceRegistry.shared.nextWindowFrame {
                WorkspaceRegistry.shared.nextWindowFrame = nil
                window.setFrame(frame, display: true)
            }
            model.onRequestActivation = { [weak window] in
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
            model.onRequestClose = { [weak window] in window?.close() }
            model.confirmClose = { [weak window] prompt, reply in
                guard let window else { reply(false);return }
                Self.confirm(prompt, in: window, reply: reply)
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.close() }
                },
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fullScreenChanged() }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fullScreenChanged() }
                },
                // The window server only accepts a blur once the window is on screen.
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyBlur() }
                },
                // AppKit puts the traffic lights back at their defaults while
                // resizing; this arrives after it has, in the same frame.
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeTrafficLights() }
                },
            ]
            // Anything else that resets them (the edited dot, an appearance
            // change) is caught here. AppKit ignores a move made while it is
            // still positioning the buttons, so the fix waits until it is done.
            if let close = window.standardWindowButton(.closeButton) {
                for view in [close, close.superview?.superview].compactMap(\.self) {
                    view.postsFrameChangedNotifications = true
                    observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                        DispatchQueue.main.async { self?.placeTrafficLights() }
                    })
                }
            }
            DispatchQueue.main.async { [weak self] in self?.placeTrafficLights() }
            let current = (title, colors)
            title = ""
            colors = nil
            if let currentColors = current.1 { apply(title: current.0, colors: currentColors) }
        }

        func apply(title: String, colors: ChromeColors) {
            guard let window else { self.title = title;self.colors = colors;return }
            if window.title != title {
                window.title = title
                // A new title makes AppKit reset the traffic lights.
                placeTrafficLights()
            }
            guard self.colors != colors else { return }
            self.colors = colors
            let theme = colors.theme
            let fullScreen = window.styleMask.contains(.fullScreen)
            let opaque = fullScreen || theme.effectiveBackgroundOpacity >= 1
            window.isOpaque = opaque
            window.backgroundColor = opaque ? NSColor(hex: colors.titlebarHex, colorspace: colors.colorspace) : .clear
            applyBlur()
        }

        private func applyBlur() {
            guard let window, let theme = colors?.theme else { return }
            let translucent = !window.styleMask.contains(.fullScreen) && theme.effectiveBackgroundOpacity < 1
            WindowBlur.apply(radius: translucent ? theme.backgroundBlur ?? 0 : 0, to: window)
        }

        private func placeTrafficLights() {
            if let window { TrafficLights.place(in: window, titlebarHeight: titlebarHeight) }
        }

        private func fullScreenChanged() {
            guard let window else { return }
            isFullScreen.wrappedValue = window.styleMask.contains(.fullScreen)
            placeTrafficLights()
            if let colors { self.colors = nil;apply(title: window.title, colors: colors) }
        }

        /// A sheet like Ghostty's: Close is the default button, Cancel answers Escape.
        private static func confirm(_ prompt: ClosePrompt, in window: NSWindow, reply: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in reply(response == .alertFirstButtonReturn) }
        }
    }
}

/// Puts the close, minimise and zoom buttons where the design has them:
/// centred vertically in the custom titlebar at fixed horizontal centres.
/// Their container only grows when it is too short to hold them there,
/// because AppKit shrinks it back on appearance changes.
enum TrafficLights {
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    @MainActor
    static func place(in window: NSWindow, titlebarHeight: CGFloat) {
        guard !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview, let frameView = container.superview else { return }
        let top = frameView.bounds.height
        let needed = (titlebarHeight + close.frame.height) / 2
        if container.frame.maxY != top || container.frame.height < needed {
            var frame = container.frame
            frame.size.height = max(frame.height, needed)
            frame.origin.y = top - frame.height
            container.frame = frame
        }
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let centre = NSPoint(x: Chrome.Titlebar.trafficLightX + CGFloat(index) * Chrome.Titlebar.trafficLightSpacing,
                                 y: top - titlebarHeight / 2)
            let local = superview.convert(centre, from: frameView)
            let origin = NSPoint(x: (local.x - button.frame.width / 2).rounded(), y: (local.y - button.frame.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// Blurs what is behind a translucent window, like Ghostty's
/// `background-blur`. Uses the window server call Ghostty and iTerm2 use;
/// when it is unavailable the window is simply unblurred.
enum WindowBlur {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int, Int32) -> Int32

    private static let functions: (DefaultConnection, SetBlurRadius)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSDefaultConnectionForThread"),
              let setRadius = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(connection, to: DefaultConnection.self), unsafeBitCast(setRadius, to: SetBlurRadius.self))
    }()

    @MainActor
    static func apply(radius: Int, to window: NSWindow) {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return }
        _ = setRadius(connection(), window.windowNumber, Int32(max(0, min(radius, 100))))
    }
}
