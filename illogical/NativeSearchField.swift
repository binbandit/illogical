import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var size: CGFloat = 13
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onMove: (Int) -> Void = { _ in }
    var autoFocus = true
    var focusToken: UUID?
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = context.coordinator
        field.autoFocus = autoFocus
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder; field.font = .systemFont(ofSize: size)
        field.autoFocus = autoFocus
        if field.focusToken != focusToken {
            field.focusToken = focusToken
            if autoFocus { field.requestFocus() }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSTextField { parent.text = field.stringValue } }
        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            default: return false
            }
        }
    }
    final class Field: NSTextField {
        var autoFocus = true
        var focusToken: UUID?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if autoFocus { requestFocus() }
        }
        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.autoFocus, !self.isHiddenOrHasHiddenAncestor, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
