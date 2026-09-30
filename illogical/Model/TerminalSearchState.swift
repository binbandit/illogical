import Foundation
import Observation

/// One pane's scrollback search: its query and the latest match results.
@MainActor
@Observable
final class TerminalSearchState {
    struct Result: Equatable {
        var count = 0
        var selected = 0
        var row = -1
    }

    var query = ""
    /// Changes when the search field should take keyboard focus.
    var focusToken = UUID()
    private(set) var result = Result()
    private(set) var spans: [TerminalSearchSpan] = []
    @ObservationIgnored private var pendingResult: Result?
    @ObservationIgnored private var pendingSpans: [TerminalSearchSpan]?
    @ObservationIgnored private var scheduled = false

    func receive(count: Int, selected: Int, row: Int) {
        let next = Result(count: count, selected: selected, row: row)
        guard next != (pendingResult ?? result) else { return }
        pendingResult = next
        scheduleUpdate()
    }

    func receive(spans: [TerminalSearchSpan]) {
        guard spans != (pendingSpans ?? self.spans) else { return }
        pendingSpans = spans
        scheduleUpdate()
    }

    /// Results arrive while the renderer draws a frame, possibly inside a
    /// SwiftUI update. Publish them once afterwards.
    private func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if let result = self.pendingResult { self.pendingResult = nil;self.result = result }
            if let spans = self.pendingSpans { self.pendingSpans = nil;self.spans = spans }
        }
    }
}
