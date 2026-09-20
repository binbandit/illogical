import AppKit

@main
struct TerminalInputTests {
    @MainActor
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { fputs("FAIL: \(name)\n", stderr); failures += 1 }
        }
        let engine = TerminalEngine(blockID: "keyboard-test", theme: .merinoDark)
        var output = Data()
        engine.onInput = { output.append($0) }
        func key(_ code: UInt16, _ characters: String, _ base: String, _ modifiers: NSEvent.ModifierFlags = [], release: Bool = false, repeatKey: Bool = false) -> Data {
            output.removeAll(keepingCapacity: true)
            let event = NSEvent.keyEvent(with: release ? .keyUp : .keyDown, location: .zero,
                                        modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                        context: nil, characters: characters, charactersIgnoringModifiers: base,
                                        isARepeat: repeatKey, keyCode: code)!
            engine.key(event, release: release)
            return output
        }
        for (code, raw, base, value, signal) in [(UInt16(8), "\u{3}", "c", UInt8(3), SIGINT),
                                                (UInt16(2), "\u{4}", "d", UInt8(4), Int32(0)),
                                                (UInt16(6), "\u{1a}", "z", UInt8(26), SIGTSTP)] {
            let encoded = key(code, raw, base, .control)
            check(encoded == Data([value]), "Control-\(base) encodes its terminal control byte; got \(encoded as NSData)")
            check(encoded.withUnsafeBytes { il_test_pty_input($0.bindMemory(to: UInt8.self).baseAddress, UInt(encoded.count), signal) } == 1,
                  "Control-\(base) reaches a real foreground PTY child as \(signal == 0 ? "EOF" : "signal \(signal)")")
        }
        check(key(36, "\r", "\r") == Data([13]), "Return")
        check(key(51, "\u{7f}", "\u{7f}") == Data([127]), "Backspace")
        check(key(48, "\t", "\t") == Data([9]), "Tab")
        check(key(48, "\u{19}", "\t", .shift) == Data("\u{1b}[Z".utf8), "Shift-Tab")
        check(key(53, "\u{1b}", "\u{1b}") == Data([27]), "Escape")
        check(key(126, "\u{f700}", "\u{f700}") == Data("\u{1b}[A".utf8), "Up arrow")
        check(key(123, "\u{f702}", "\u{f702}", .option) == Data("\u{1b}[1;3D".utf8), "Option-Left")
        check(key(49, "\0", " ", .control) == Data([0]), "Control-Space")
        check(key(44, "\u{1f}", "/", .control) == Data([31]), "Control-Slash")
        check(key(42, "\u{1c}", "\\", .control) == Data([28]), "Control-Backslash")
        check(key(33, "\u{1b}", "[", .control) == Data("\u{1b}[91;5u".utf8), "Ghostty fixterms Control-Left-Bracket")
        check(key(30, "\u{1d}", "]", .control) == Data([29]), "Control-Right-Bracket")
        check(key(17, "\u{14}", "t", .control) == Data([20]), "Control-T")
        check(key(0, "A", "a", .shift) == Data("A".utf8), "Shift text")
        check(key(11, "∫", "b", .option) == Data("∫".utf8), "Native Option character")
        check(key(0, "a", "a", release: true).isEmpty, "No release bytes in legacy mode")

        let modes = Data("\u{1b}[?1h".utf8)
        modes.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, modes.count) }
        check(key(126, "\u{f700}", "\u{f700}") == Data("\u{1b}OA".utf8), "Application cursor mode")
        let kitty = Data("\u{1b}[>3u".utf8)
        kitty.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, kitty.count) }
        check(key(8, "\u{3}", "c", .control) == Data("\u{1b}[99;5u".utf8), "Kitty Control-C press")
        check(key(8, "\u{3}", "c", .control, repeatKey: true) == Data("\u{1b}[99;5:2u".utf8), "Kitty Control-C repeat")
        check(key(8, "\u{3}", "c", .control, release: true) == Data("\u{1b}[99;5:3u".utf8), "Kitty Control-C release")
        let extended = Data("\u{1b}[>31u".utf8)
        extended.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, extended.count) }
        check(key(0, "A", "a", .shift) == Data("\u{1b}[97:65;2;65u".utf8), "Kitty alternate and associated text")
        for (modifiers, release, expected) in [(NSEvent.ModifierFlags.shift, false, "\u{1b}[57441;2u"),
                                               (NSEvent.ModifierFlags(), true, "\u{1b}[57441;1:3u")] {
            output.removeAll(keepingCapacity: true)
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
            engine.key(event, release: release)
            check(output == Data(expected.utf8), "Kitty modifier \(release ? "release" : "press")")
        }
        if failures != 0 { exit(1) }
        print("Terminal input: control keys signal real PTY programs, native text, cursor modes and Kitty events passed.")
    }
}
