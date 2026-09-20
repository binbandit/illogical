import Foundation

nonisolated struct WireRequest: Encodable, Sendable {
    var id = UUID().uuidString
    var method: String
    var session: String?
    var window: String?
    var block: String?
    var client: String?
    var target: String?
    var label: String?
    var command: [String]?
    var cwd: String?
    var axis: String?
    var ratio: Double?
    var cols: UInt16?
    var rows: UInt16?
    var cellWidth: UInt32?
    var cellHeight: UInt32?
    var data: Data?
    var format: String?
    var keepOpen: Bool?
    var release: Bool?
    var theme: WireTheme?
    var replayID: String?
    var sequence: UInt64?
    var synchronized: Bool?
    var viewport: UInt64?
}

nonisolated struct WireTheme: Codable, Sendable {
    var background: UInt32?
    var foreground: UInt32?
    var cursor: UInt32?
    var palette: [UInt32]?
}

nonisolated struct WireMessage: Decodable, Sendable {
    var id: String?
    var type: String
    var error: String?
    var `protocol`: Int?
    var features: [String]?
    var engine: String?
    var client: String?
    var state: WorkspaceState?
    var block: String?
    var session: String?
    var window: String?
    var stream: String?
    var data: Data?
    var text: String?
    var event: String?
    var final: Bool?
    var cols: UInt16?
    var rows: UInt16?
    var exitCode: Int?
    var entries: [DirectoryEntry]?
    var path: String?
    var process: ChildProcess?
    var theme: WireTheme?
    var replayID: String?
    var sequence: UInt64?
    var previousSequence: UInt64?
    var viewport: UInt64?
    var graphics: WireGraphicsState?
}

nonisolated struct WireGraphicsState: Codable, Sendable {
    var generation: UInt64
    var reset: Bool
    var cellWidth: UInt32
    var cellHeight: UInt32
    var images: [WireGraphicsImage]
    var placements: [WireGraphicsPlacement]
}

nonisolated struct WireGraphicsImage: Codable, Sendable {
    var id: UInt32
    var generation: UInt64
    var width: UInt32
    var height: UInt32
    var format: Int
    var data: Data
}

nonisolated struct WireGraphicsPlacement: Codable, Sendable {
    var imageID: UInt32
    var imageGeneration: UInt64
    var id: UInt32
    var column: UInt32
    var row: Int64
    var xOffset: UInt32
    var yOffset: UInt32
    var pixelWidth: UInt32
    var pixelHeight: UInt32
    var sourceX: UInt32
    var sourceY: UInt32
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var z: Int32
}

nonisolated struct WorkspaceState: Decodable, Sendable {
    var revision: UInt64
    var sessions: [Session]
    var blocks: [BlockInfo]
    var clients: Int
}

nonisolated struct Session: Decodable, Identifiable, Sendable {
    let id: String
    var name: String
    var windows: [Deck]
}

nonisolated struct Deck: Decodable, Identifiable, Sendable {
    let id: String
    var name: String
    var root: SplitLayout
    var zoomed: String?
}

nonisolated final class SplitLayout: Decodable, Identifiable, Sendable {
    let id: String
    let block: String?
    let axis: String?
    let ratio: Double?
    let first: SplitLayout?
    let second: SplitLayout?

    var blocks: [String] {
        if let block { return [block] }
        return (first?.blocks ?? []) + (second?.blocks ?? [])
    }
}

nonisolated struct BlockInfo: Decodable, Identifiable, Sendable {
    let id: String
    var title: String
    var cwd: String
    var pid: Int
    var cols: UInt16
    var rows: UInt16
    var parked: Bool
    var exitCode: Int?
    var command: [String]
    var keepOpen: Bool
    var owner: String?

    var displayTitle: String {
        if !title.isEmpty && !["zsh", "bash", "fish", "sh"].contains(title) { return title }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let location = cwd == home ? "~" : (cwd as NSString).lastPathComponent
        return "\(location) - \(title.isEmpty ? "shell" : title)"
    }

    var icon: String {
        let text = title.lowercased()
        if text.contains("vim") || text.contains("emacs") { return "curlybraces" }
        if text.contains("claude") || text.contains("codex") { return "sparkle" }
        if text.contains("top") { return "chart.bar.xaxis" }
        if text.contains("git") { return "point.3.connected.trianglepath.dotted" }
        return "terminal"
    }
}

nonisolated struct DirectoryEntry: Decodable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
}

nonisolated struct ChildProcess: Decodable, Sendable {
    let pid: Int
    let foregroundPID: Int
    let user: String
    let command: [String]
    let cwd: String
    let home: String
    let exitCode: Int?
    var child: ProcessIdentity?
    var foreground: ProcessIdentity?
}

nonisolated struct ProcessIdentity: Decodable, Sendable {
    let pid: Int
    let uid: UInt32
    var user: String?
    var name: String?
    var executable: String?
}

nonisolated struct HostProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var address: String
    var executable: String
    var isLocal: Bool { id == "local" }
    static let local = HostProfile(id: "local", name: "This Mac", address: "", executable: "")
}
