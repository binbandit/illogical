import AppKit

/// Fails without trapping, so a failing test never opens the crash reporter.
nonisolated private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #fileID, line: UInt = #line) {
    guard !condition() else { return }
    FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
    exit(1)
}

@main
struct WorkspaceSearchTests {
    @MainActor
    static func main() async {
        let domain = "dev.illogical.search-tests"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let model = WorkspaceModel()
        let preferences = Preferences.shared
        let originalAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = originalAppearance }
        preferences.lightThemeName = "Merino Light";preferences.darkThemeName = "Merino Dark"
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        preferences.followSystemAppearance = true
        expect(preferences.themeName == "Merino Light")
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(20))
        expect(preferences.themeName == "Merino Dark", "Appearance observation must select the configured dark theme")
        preferences.selectTheme("Merino Light")
        expect(!preferences.followSystemAppearance && preferences.themeName == "Merino Light")
        preferences.adopt([.merinoLight, .merinoDark])
        expect(preferences.followSystemAppearance && preferences.themeName == "Merino Dark", "Importing a pair must follow the system")
        model.fontSizeDelta = 0
        let configured = preferences.fontSize
        model.adjustFontSize(by: 1);model.adjustFontSize(by: 1)
        expect(model.fontSize == configured + 2 && preferences.fontSize == configured, "Zooming is per window and never changes the configured size")
        model.resetFontSize()
        expect(model.fontSize == configured, "Actual Size returns to the configured size")
        let first = model.engine(for: "search-a")
        let second = model.engine(for: "search-b")
        func feed(_ text: String, to engine: TerminalEngine) {
            let data = Data(text.utf8)
            data.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        }
        feed("apple apple\r\npear", to: first)
        feed("pear pear pear\r\napple", to: second)
        model.focus("search-a"); model.find()
        model.searches["search-a"]!.query = "apple"; model.updateSearch("search-a")
        _ = first.frame()
        model.focus("search-b"); model.find()
        model.searches["search-b"]!.query = "pear"; model.updateSearch("search-b")
        _ = second.frame()
        try? await Task.sleep(for: .milliseconds(10))
        expect(model.searches.count == 2)
        expect(model.searches["search-a"]?.result.count == 2)
        expect(model.searches["search-b"]?.result.count == 3)
        model.updateSearch("search-a", direction: 1); _ = first.frame()
        try? await Task.sleep(for: .milliseconds(10))
        expect(model.searches["search-a"]?.result.selected == 2)
        expect(model.searches["search-b"]?.result.selected == 1)
        model.closeSearch("search-b")
        expect(model.searches["search-a"]?.query == "apple" && model.searches["search-b"] == nil)
        expect(model.searchFocusedBlock == nil)
        model.focus("search-a"); model.find()
        expect(model.searches["search-a"]?.query == "apple", "Reopening a pane's search preserves its own query")
        model.searches["search-a"]?.query = ""; model.updateSearch("search-a")
        try? await Task.sleep(for: .milliseconds(10))
        expect(model.searches["search-a"]?.result.count == 0 && model.searches["search-a"]?.spans.isEmpty == true)

        for height: CGFloat in [14, 19, 28, 44] {
            let cell = CGSize(width: 9, height: height)
            let viewport = CGSize(width: 600, height: 480)
            let bar = CGSize(width: 330, height: 38)
            for row in 0..<8 {
                let span = TerminalSearchSpan(row: row, startColumn: 30, endColumn: 60)
                let origin = SearchOverlayPlacement.origin(viewport: viewport, bar: bar, cell: cell, titleHeight: 30, spans: [span])
                let match = CGRect(x: 8 + 30 * cell.width, y: 38 + CGFloat(row) * height, width: 31 * cell.width, height: height)
                expect(!CGRect(origin: origin, size: bar).intersects(match), "Search must avoid active matches at every supported font height")
                expect(origin.y >= 30 && origin.y + bar.height <= viewport.height)
            }
            let wrapped = [TerminalSearchSpan(row: 0, startColumn: 20, endColumn: 65),
                           TerminalSearchSpan(row: 1, startColumn: 0, endColumn: 65),
                           TerminalSearchSpan(row: 2, startColumn: 0, endColumn: 40)]
            let origin = SearchOverlayPlacement.origin(viewport: viewport, bar: bar, cell: cell, titleHeight: 30, spans: wrapped)
            expect(origin.y >= 38 + 3 * height, "Wrapped active matches must remain visible too")
        }
        model.close()
        print("Theme pairing: actual AppKit appearance observation, manual override and imported pair activation passed.")
        print("Pane search: independent queries/results/navigation, close/reopen/clear, and collision-free placement across font sizes passed.")
    }
}
