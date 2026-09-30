import Foundation

// The JSON-lines contract with the illogical service. Field names and values
// must stay compatible with service/internal/mux/protocol.go.

/// A service method name. Literal-constructible so tests and other layers can
/// name methods this file does not list.
nonisolated struct WireMethod: RawRepresentable, Hashable, Encodable, Sendable, ExpressibleByStringInterpolation {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    init(stringInterpolation: DefaultStringInterpolation) { rawValue = String(stringInterpolation: stringInterpolation) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let watch: WireMethod = "watch"
    static let sessionNew: WireMethod = "session.new"
    static let sessionRename: WireMethod = "session.rename"
    static let sessionKill: WireMethod = "session.kill"
    static let windowNew: WireMethod = "window.new"
    static let windowRename: WireMethod = "window.rename"
    static let windowKill: WireMethod = "window.kill"
    static let windowZoom: WireMethod = "window.zoom"
    static let layoutResize: WireMethod = "layout.resize"
    static let directoryList: WireMethod = "directory.list"
    static let blockSplit: WireMethod = "block.split"
    static let blockMove: WireMethod = "block.move"
    static let blockKill: WireMethod = "block.kill"
    static let blockAttach: WireMethod = "block.attach"
    static let blockClaim: WireMethod = "block.claim"
    static let blockWrite: WireMethod = "block.write"
    static let blockResize: WireMethod = "block.resize"
    static let blockProcess: WireMethod = "block.process"
    static let blockEvent: WireMethod = "block.event"
    static let blockTheme: WireMethod = "block.theme"
    static let blockViewport: WireMethod = "block.viewport"
}

/// How a split arranges its two children. `horizontal` places them side by
/// side; `vertical` stacks them.
nonisolated enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical

    init(from decoder: Decoder) throws {
        // An unknown future axis must not make the whole workspace undecodable.
        self = SplitAxis(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .horizontal
    }
}

nonisolated struct WireRequest: Encodable, Sendable {
    var id = UUID().uuidString
    var method: WireMethod
    var session: String?
    var window: String?
    var block: String?
    var client: String?
    var target: String?
    var label: String?
    var command: [String]?
    var cwd: String?
    var axis: SplitAxis?
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

/// Every message the service sends: replies (carrying the request `id`),
/// workspace `state`, terminal stream updates and block `event`s.
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

nonisolated struct WorkspaceState: Decodable, Equatable, Sendable {
    var revision: UInt64
    var sessions: [Session]
    var blocks: [BlockInfo]
    var clients: Int
}

nonisolated struct Session: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var windows: [Deck]
    /// The tab the service last saw focused, shared by every client.
    var focusedWindow: String?
}

/// A tab: a tree of terminal blocks. The service calls it a window.
nonisolated struct Deck: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var root: SplitLayout
    var zoomed: String?
    /// The pane the service last saw focused, shared by every client.
    var focusedBlock: String?
}

/// A node of a tab's layout: either a terminal `block` or a split of two children.
nonisolated final class SplitLayout: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let block: String?
    let axis: SplitAxis?
    let ratio: Double?
    let first: SplitLayout?
    let second: SplitLayout?

    /// Terminal blocks in reading order: left to right, top to bottom.
    var blocks: [String] {
        if let block { return [block] }
        return (first?.blocks ?? []) + (second?.blocks ?? [])
    }

    static func == (lhs: SplitLayout, rhs: SplitLayout) -> Bool {
        lhs === rhs || (lhs.id == rhs.id && lhs.block == rhs.block && lhs.axis == rhs.axis && lhs.ratio == rhs.ratio
                        && lhs.first == rhs.first && lhs.second == rhs.second)
    }
}

nonisolated struct BlockInfo: Decodable, Equatable, Identifiable, Sendable {
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
    /// A name given with `illogical block rename`, preferred over the title.
    var label: String?
}

nonisolated struct DirectoryEntry: Decodable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
}

nonisolated struct ChildProcess: Decodable, Equatable, Sendable {
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

nonisolated struct ProcessIdentity: Decodable, Equatable, Sendable {
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
    var isLocal: Bool { id == Self.local.id }
    static let local = HostProfile(id: "local", name: "This Mac", address: "", executable: "")
}
