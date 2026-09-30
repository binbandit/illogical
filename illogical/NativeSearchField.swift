import AppKit
import SwiftUI

/// A borderless AppKit text field for palettes and search bars. It reports
/// Return (with whether Shift was held), Escape, the arrow keys and
/// Command-Delete, and can
/// take keyboard focus whenever `focusToken` changes.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var size: CGFloat = 13
    var onSubmit: (_ backwards: Bool) -> Void
    var onEscape: () -> Void
    var onMove: (Int) -> Void = { _ in }
    var autoFocus = true
    var focusToken: UUID?
    var onFocus: () -> Void = {}
    /// Command-Delete; return true to consume it instead of editing the text.
    var onDeleteCommand: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.autoFocus = autoFocus
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: size)
        field.autoFocus = autoFocus
        if field.focusToken != focusToken {
            field.focusToken = focusToken
            if autoFocus { field.requestFocus() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.deleteToBeginningOfLine(_:)): return parent.onDeleteCommand?() ?? false
            default: return false
            }
            return true
        }
    }

    final class Field: NSTextField {
        var autoFocus = true
        var focusToken: UUID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if autoFocus { requestFocus() }
        }

        /// Takes keyboard focus once SwiftUI has finished mounting the field.
        /// Becoming first responder selects the existing text.
        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.autoFocus, !self.isHiddenOrHasHiddenAncestor, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
