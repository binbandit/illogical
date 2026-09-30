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
        engine.keybindings = .ghosttyDefaults
        var output = Data()
        engine.onInput = { output.append($0) }
        func feed(_ text: String) {
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        func event(_ code: UInt16, _ characters: String, _ base: String, _ modifiers: NSEvent.ModifierFlags = [],
                   type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: base,
                             isARepeat: repeatKey, keyCode: code)!
        }
        func key(_ code: UInt16, _ characters: String, _ base: String, _ modifiers: NSEvent.ModifierFlags = [],
                 release: Bool = false, repeatKey: Bool = false) -> Data {
            output.removeAll(keepingCapacity: true)
            engine.key(event(code, characters, base, modifiers, type: release ? .keyUp : .keyDown, repeatKey: repeatKey))
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
        check(key(117, "\u{f728}", "\u{f728}") == Data("\u{1b}[3~".utf8), "Forward delete")
        check(key(48, "\t", "\t") == Data([9]), "Tab")
        check(key(48, "\u{19}", "\t", .shift) == Data("\u{1b}[Z".utf8), "Shift-Tab")
        check(key(53, "\u{1b}", "\u{1b}") == Data([27]), "Escape")
        check(key(126, "\u{f700}", "\u{f700}") == Data("\u{1b}[A".utf8), "Up arrow")
        check(key(115, "\u{f729}", "\u{f729}") == Data("\u{1b}[H".utf8), "Home")
        check(key(116, "\u{f72c}", "\u{f72c}") == Data("\u{1b}[5~".utf8), "Page Up")
        check(key(122, "\u{f704}", "\u{f704}") == Data("\u{1b}OP".utf8), "F1")
        check(key(49, "\0", " ", .control) == Data([0]), "Control-Space")
        check(key(44, "\u{1f}", "/", .control) == Data([31]), "Control-Slash")
        check(key(42, "\u{1c}", "\\", .control) == Data([28]), "Control-Backslash")
        check(key(33, "\u{1b}", "[", .control) == Data("\u{1b}[91;5u".utf8), "Ghostty fixterms Control-Left-Bracket")
        check(key(30, "\u{1d}", "]", .control) == Data([29]), "Control-Right-Bracket")
        for (code, character, byte) in [(UInt16(15), "r", UInt8(0x12)), (37, "l", 0x0c), (0, "a", 0x01),
                                        (14, "e", 0x05), (13, "w", 0x17), (32, "u", 0x15), (17, "t", 0x14)] {
            let control = String(UnicodeScalar(byte))
            check(key(code, control, character, .control) == Data([byte]), "Control-\(character.uppercased())")
        }
        check(key(0, "A", "a", .shift) == Data("A".utf8), "Shift text")
        check(key(0, "A", "a", .capsLock) == Data("A".utf8), "Caps Lock text")
        check(key(11, "∫", "b", .option) == Data("∫".utf8), "Native Option character")
        check(key(0, "a", "a", release: true).isEmpty, "No release bytes in legacy mode")
        check(key(0, "a", "a", repeatKey: true) == Data("a".utf8), "Key repeat")

        // Ghostty's macOS "natural text editing" defaults.
        check(key(123, "\u{f702}", "\u{f702}", .option) == Data("\u{1b}b".utf8), "Option-Left moves back a word")
        check(key(124, "\u{f703}", "\u{f703}", .option) == Data("\u{1b}f".utf8), "Option-Right moves forward a word")
        check(key(51, "\u{7f}", "\u{7f}", .option) == Data("\u{1b}\u{7f}".utf8), "Option-Backspace deletes a word")
        check(key(123, "\u{f702}", "\u{f702}", .command) == Data([0x01]), "Command-Left goes to line start")
        check(key(124, "\u{f703}", "\u{f703}", .command) == Data([0x05]), "Command-Right goes to line end")
        check(key(51, "\u{7f}", "\u{7f}", .command) == Data([0x15]), "Command-Backspace kills the line")
        check(key(123, "\u{f702}", "\u{f702}", [.command, .option]).isEmpty, "Other modifier sets are not the binding")
        // Unbound Command chords never type in legacy mode.
        for (code, characters) in [(UInt16(38), "j"), (36, "\r"), (96, "\u{f708}"), (18, "1"), (47, ".")] {
            check(key(code, characters, characters, .command).isEmpty, "Command-\(code) sends nothing")
        }

        // Option as Alt.
        engine.optionAsAlt = .both
        check(key(11, "∫", "b", .option) == Data("\u{1b}b".utf8), "Option as Alt sends Meta")
        engine.optionAsAlt = .right
        check(key(11, "∫", "b", .option) == Data("∫".utf8), "Left Option still composes when only the right is Alt")
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        check(engine.translationModifiers(rightOption) == NSEvent.ModifierFlags(rawValue: 0x40), "Right Option is not used to translate text")
        engine.optionAsAlt = .disabled

        // The owner's Ghostty binding, honoured in every key mode like Ghostty.
        let shiftEnter = TerminalKeybindings.ghostty(configuration: [("font-size", "14"), ("keybind", "shift+enter=text:\\x1b\\r")])
        var owner = shiftEnter
        engine.keybindings = owner
        check(key(36, "\r", "\r", .shift) == Data("\u{1b}\r".utf8), "Shift-Enter sends ESC CR")
        check(key(36, "\r", "\r") == Data([13]), "Plain Enter is unaffected")
        check(owner.apply("ctrl+shift+k=csi:2J") && owner.apply("super+k=esc:c") && owner.apply("global:unconsumed:alt+x=text:\\u{1F600}"),
              "csi, esc, flags and Unicode escapes parse")
        engine.keybindings = owner
        check(key(40, "\u{b}", "k", [.control, .shift]) == Data("\u{1b}[2J".utf8), "csi: binding")
        check(key(40, "k", "k", .command) == Data("\u{1b}c".utf8), "esc: binding")
        check(key(7, "≈", "x", .option) == Data("😀".utf8), "Unicode text binding")
        check(owner.apply("super+arrow_left=unbind") && owner.apply("super+arrow_right=new_tab") == false, "unbind and app actions")
        engine.keybindings = owner
        check(key(123, "\u{f702}", "\u{f702}", .command).isEmpty && key(124, "\u{f703}", "\u{f703}", .command).isEmpty,
              "Unbound and app-action keys fall back to Command's silence")
        check(owner.apply("clear") && owner.bindings.isEmpty, "clear removes every binding")
        check(!owner.apply("a>b=text:x") && !owner.apply("shift+=text:x") && !owner.apply("shift+enter=text:\\q"), "Invalid entries are rejected")
        engine.keybindings = .ghosttyDefaults

        feed("selected words")
        func hasSelection() -> Bool { !(engine.copy() ?? "").isEmpty }
        engine.selectAll()
        engine.key(event(56, "", "", .shift, type: .flagsChanged), action: .press)
        check(hasSelection(), "A modifier press keeps the selection")
        _ = key(0, "a", "a")
        check(!hasSelection(), "Typing clears the selection like Ghostty's selection-clear-on-typing")
        engine.selectAll()
        engine.typeText("日本")
        check(!hasSelection(), "Committed input-method text clears the selection")
        engine.selectAll()
        engine.paste("pasted")
        check(hasSelection(), "Paste keeps the selection")
        output.removeAll()

        // Viewport bindings.
        let viewport = TerminalEngine(blockID: "viewport-bindings", theme: .merinoDark)
        viewport.keybindings = .ghosttyDefaults
        viewport.resizeFromServer(columns: 20, rows: 4)
        var viewportInput = Data()
        viewport.onInput = { viewportInput.append($0) }
        for command in 1...3 {
            let text = "\u{1b}]133;A\u{7}$ cmd\(command)\r\n" + String(repeating: "output\r\n", count: 5)
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(viewport.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        func offset() -> UInt64 { viewport.frame()!.scrollOffset }
        let bottom = offset()
        viewport.key(event(115, "\u{f729}", "\u{f729}", .command))
        check(offset() == 0, "Command-Home scrolls to the top")
        viewport.key(event(121, "\u{f72d}", "\u{f72d}", .command))
        check(offset() == 4, "Command-Page Down scrolls one page")
        viewport.key(event(119, "\u{f72b}", "\u{f72b}", .command))
        check(offset() == bottom, "Command-End scrolls to the bottom")
        viewport.key(event(126, "\u{f700}", "\u{f700}", .command))
        check(offset() == 12, "Command-Up jumps to the previous prompt")
        viewport.key(event(126, "\u{f700}", "\u{f700}", [.command, .shift]))
        check(offset() == 6, "Shift-Command-Up jumps to prompts too")
        viewport.key(event(125, "\u{f701}", "\u{f701}", .command))
        check(offset() == 12, "Command-Down jumps to the next prompt")
        check(viewportInput.isEmpty, "Viewport bindings send nothing to the program")
        Data(String(repeating: "more output\r\n", count: 10).utf8).withUnsafeBytes {
            il_terminal_feed(viewport.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        check(offset() == 12, "New output does not move a viewport the user scrolled up")

        // Large pastes are split under the service's per-write limit and arrive complete, in order.
        let large = String(repeating: "0123456789abcdef", count: 200_000)
        var chunks: [Data] = []
        engine.onInput = { chunks.append($0) }
        engine.paste(large)
        engine.key(event(0, "z", "z"))
        let deadline = Date(timeIntervalSinceNow: 5)
        while chunks.reduce(0, { $0 + $1.count }) < large.utf8.count + 1, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        check(chunks.allSatisfy { $0.count <= TerminalEngine.maximumWriteBytes }, "Paste chunks respect the write limit")
        check(chunks.count > 1 && Data(chunks.joined()) == Data((large + "z").utf8), "A 3 MB paste arrives whole, before later typing")
        engine.onInput = { output.append($0) }

        feed("\u{1b}[?1h")
        check(key(126, "\u{f700}", "\u{f700}") == Data("\u{1b}OA".utf8), "Application cursor mode")
        feed("\u{1b}[>3u")
        check(key(8, "\u{3}", "c", .control) == Data("\u{1b}[99;5u".utf8), "Kitty Control-C press")
        check(key(8, "\u{3}", "c", .control, repeatKey: true) == Data("\u{1b}[99;5:2u".utf8), "Kitty Control-C repeat")
        check(key(8, "\u{3}", "c", .control, release: true) == Data("\u{1b}[99;5:3u".utf8), "Kitty Control-C release")
        check(key(38, "j", "j", .command) == Data("\u{1b}[106;9u".utf8), "Kitty reports Command chords")
        engine.keybindings = shiftEnter
        check(key(36, "\r", "\r", .shift) == Data("\u{1b}\r".utf8), "An explicit binding wins over Kitty, as in Ghostty")
        engine.keybindings = .ghosttyDefaults
        feed("\u{1b}[>31u")
        check(key(0, "A", "a", .shift) == Data("\u{1b}[97:65;2;65u".utf8), "Kitty alternate and associated text")
        for _ in 0..<40 { feed("history\r\n") }
        engine.scrollTo(0)
        engine.key(event(56, "", "", .shift, type: .flagsChanged), action: .press)
        check(engine.frame()?.scrollOffset == 0, "A Kitty modifier report does not jump to the bottom")
        engine.key(event(56, "", "", [], type: .flagsChanged), action: .release)
        engine.scrollToBottom()
        for (modifiers, action, expected) in [(NSEvent.ModifierFlags.shift, ILKeyAction.press, "\u{1b}[57441;2u"),
                                              (NSEvent.ModifierFlags(), ILKeyAction.release, "\u{1b}[57441;1:3u")] {
            output.removeAll(keepingCapacity: true)
            engine.key(event(56, "", "", modifiers, type: .flagsChanged), action: action)
            check(output == Data(expected.utf8), "Kitty modifier \(action == .press ? "press" : "release")")
        }
        if failures != 0 { exit(1) }
        print("Terminal input: control keys signal real PTY programs; text, navigation, natural text editing, Command silence, Option as Alt, Ghostty keybinds, viewport bindings, chunked paste, cursor modes and Kitty events passed.")
    }
}
