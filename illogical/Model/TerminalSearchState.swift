import Combine
import Foundation

@MainActor
final class TerminalSearchState: ObservableObject {
    struct Result: Equatable {
        var count = 0
        var selected = 0
        var row = -1
    }
    @Published var query = ""
    @Published var focusToken = UUID()
    @Published private(set) var result = Result()
    @Published private(set) var spans: [TerminalSearchSpan] = []
    private var pendingResult: Result?
    private var pendingSpans: [TerminalSearchSpan]?
    private var scheduled = false

    func receive(count: Int, selected: Int, row: Int) {
        let next = Result(count: count, selected: selected, row: row)
        guard next != (pendingResult ?? result) else { return }
        pendingResult = next; scheduleUpdate()
    }

    func receive(spans: [TerminalSearchSpan]) {
        guard spans != (pendingSpans ?? self.spans) else { return }
        pendingSpans = spans; scheduleUpdate()
    }

    private func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        // Frames can arrive while SwiftUI is updating the native surface.
        // Publish once afterward, and keep each pane's result independent.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if let result = self.pendingResult { self.pendingResult = nil; self.result = result }
            if let spans = self.pendingSpans { self.pendingSpans = nil; self.spans = spans }
        }
    }
}
