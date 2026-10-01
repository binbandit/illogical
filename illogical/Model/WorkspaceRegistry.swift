import AppKit

/// A session on a particular host.
nonisolated struct SessionKey: Hashable, Codable, Sendable {
    let host: String
    let session: String
}

/// What a window showed, kept in its scene storage for restoration.
nonisolated struct WindowSelection: Equatable, Sendable {
    var host: String
    var session: String
    var tab: String
}

/// How a new window chooses what to show once the service answers.
enum WindowIntent: Equatable {
    /// Relaunch: show the stored session unless it is gone or shown elsewhere.
    case restore(WindowSelection)
    /// Command-N: a fresh session, inheriting the parent pane's directory.
    case newSession(host: String, parentBlock: String?)
    /// Dock reopen or first launch: the most recent session not shown elsewhere.
    case reopen

    var host: String {
        switch self {
        case .restore(let selection): selection.host
        case .newSession(let host, _): host
        case .reopen: HostProfile.local.id
        }
    }
}

/// Tracks every live workspace window so a session appears in at most one
/// window, and remembers which sessions were used most recently.
@MainActor
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    private struct Entry { weak var model: WorkspaceModel? }
    private var entries: [Entry] = []
    private(set) var history: [SessionKey]
    /// Consumed by the next window that starts, set just before opening it.
    var nextWindowIntent: WindowIntent?
    /// Where the next window should appear: the key window's size, cascaded.
    var nextWindowFrame: NSRect?

    private static let historyKey = "sessionHistory"
    private static let historyLimit = 64

    private init() {
        history = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([SessionKey].self, from: $0) } ?? []
    }

    var models: [WorkspaceModel] { entries.compactMap(\.model) }

    func register(_ model: WorkspaceModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
        entries.append(Entry(model: model))
    }

    func unregister(_ model: WorkspaceModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
    }

    /// The other window currently showing `key`, if any.
    func window(showing key: SessionKey, excluding model: WorkspaceModel) -> WorkspaceModel? {
        models.first { $0 !== model && $0.shownSession == key }
    }

    func model(for window: NSWindow?) -> WorkspaceModel? {
        guard let window else { return nil }
        return models.first { $0.window === window }
    }

    func recordUse(_ key: SessionKey) {
        history.removeAll { $0 == key }
        history.insert(key, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }

    /// Orders `sessions` most recently used first, keeping service order for
    /// sessions never used.
    func mostRecentFirst(_ sessions: [SessionKey]) -> [SessionKey] {
        let rank = Dictionary(history.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated().sorted {
            (rank[$0.element] ?? Int.max, $0.offset) < (rank[$1.element] ?? Int.max, $1.offset)
        }.map(\.element)
    }
}
