import CoreGraphics
import Foundation

enum PaneDirection { case left, right, up, down }

// Pure queries over a tab's split tree. The service owns the tree; these
// decide which pane to focus or which ratios to request.
extension SplitLayout {
    func contains(_ block: String) -> Bool { blocks.contains(block) }

    /// Ghostty's rule after closing a pane: the previous leaf in reading
    /// order, or the next one when the closed pane was first.
    func focusTarget(afterClosing block: String, surviving: Set<String>) -> String? {
        let leaves = blocks
        guard let index = leaves.firstIndex(of: block) else { return nil }
        return leaves[..<index].last(where: surviving.contains) ?? leaves[(index + 1)...].first(where: surviving.contains)
    }

    /// The pane `offset` places away in reading order, wrapping at the ends.
    func cycle(from block: String, by offset: Int) -> String? {
        let leaves = blocks
        guard leaves.count > 1, let index = leaves.firstIndex(of: block) else { return nil }
        return leaves[((index + offset) % leaves.count + leaves.count) % leaves.count]
    }

    /// The pane spatially next to `block`, preferring panes aligned with its
    /// centre line, then the nearest edge. Nil at the edge of the tab.
    func adjacentBlock(from block: String, direction: PaneDirection) -> String? {
        let panes = frames()
        guard let source = panes.first(where: { $0.block == block })?.rect else { return nil }
        let horizontal = direction == .left || direction == .right
        let midpoint = horizontal ? source.midY : source.midX
        let sourceRange = horizontal ? source.minY...source.maxY : source.minX...source.maxX
        var best: (block: String, rank: (Int, CGFloat, CGFloat))?
        for candidate in panes where candidate.block != block {
            let rect = candidate.rect
            let gap: CGFloat = switch direction {
            case .left: source.minX - rect.maxX
            case .right: rect.minX - source.maxX
            case .up: source.minY - rect.maxY
            case .down: rect.minY - source.maxY
            }
            guard gap >= -0.000001 else { continue }
            let lower = horizontal ? rect.minY : rect.minX
            let upper = horizontal ? rect.maxY : rect.maxX
            let alignment = lower <= midpoint && midpoint < upper ? 0 : (min(sourceRange.upperBound, upper) > max(sourceRange.lowerBound, lower) ? 1 : 2)
            let rank = (alignment, max(0, gap), abs((lower + upper) / 2 - midpoint))
            if let best, best.rank <= rank { continue }
            best = (candidate.block, rank)
        }
        return best?.block
    }

    /// Every pane's rectangle within a unit square, following live ratios.
    func frames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(block: String, rect: CGRect)] {
        if let block { return [(block, rect)] }
        guard let first, let second else { return [] }
        let ratio = clampedRatio
        var firstRect = rect, secondRect = rect
        if axis == .vertical {
            firstRect.size.height *= ratio
            secondRect.origin.y += firstRect.height
            secondRect.size.height -= firstRect.height
        } else {
            firstRect.size.width *= ratio
            secondRect.origin.x += firstRect.width
            secondRect.size.width -= firstRect.width
        }
        return first.frames(in: firstRect) + second.frames(in: secondRect)
    }

    var clampedRatio: Double {
        guard let ratio, ratio.isFinite else { return 0.5 }
        return min(1, max(0, ratio))
    }

    /// Ratios that give every pane an equal share along each split's axis,
    /// like Ghostty's `equalize_splits`. Only splits that change are listed.
    func equalizedRatios() -> [(split: String, ratio: Double)] {
        guard let first, let second, let axis else { return [] }
        let a = first.weight(along: axis), b = second.weight(along: axis)
        let ratio = Double(a) / Double(a + b)
        let own = abs(clampedRatio - ratio) > 0.001 ? [(id, ratio)] : []
        return own + first.equalizedRatios() + second.equalizedRatios()
    }

    private func weight(along axis: SplitAxis) -> Int {
        guard let first, let second else { return 1 }
        let a = first.weight(along: axis), b = second.weight(along: axis)
        return self.axis == axis ? a + b : max(a, b)
    }

    /// Moves the divider of the nearest split around `block` that runs along
    /// `direction` by `cells`, measured with each pane's grid size.
    func resized(_ block: String, toward direction: PaneDirection, cells: Int,
                 gridSize: (String) -> (columns: Int, rows: Int)?) -> (split: String, ratio: Double)? {
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        guard let split = ancestors(of: block).last(where: { $0.axis == axis }) else { return nil }
        let extent = split.extent(along: axis, gridSize: gridSize)
        guard extent > 0 else { return nil }
        let sign: Double = direction == .right || direction == .down ? 1 : -1
        let ratio = min(0.9, max(0.1, split.clampedRatio + sign * Double(cells) / Double(extent)))
        return abs(ratio - split.clampedRatio) > 0.0001 ? (split.id, ratio) : nil
    }

    /// Splits from the root down to the leaf holding `block`.
    private func ancestors(of block: String) -> [SplitLayout] {
        guard let first, let second else { return [] }
        if first.contains(block) { return [self] + first.ancestors(of: block) }
        if second.contains(block) { return [self] + second.ancestors(of: block) }
        return []
    }

    private func extent(along axis: SplitAxis, gridSize: (String) -> (columns: Int, rows: Int)?) -> Int {
        if let block {
            guard let size = gridSize(block) else { return 0 }
            return axis == .horizontal ? size.columns : size.rows
        }
        guard let first, let second else { return 0 }
        let a = first.extent(along: axis, gridSize: gridSize), b = second.extent(along: axis, gridSize: gridSize)
        return self.axis == axis ? a + b : max(a, b)
    }
}

extension Session {
    var hasTabs: Bool { !windows.isEmpty }
}

extension BlockInfo {
    /// What a tab or pane header calls this terminal.
    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        if !title.isEmpty && !Self.shells.contains(title) { return title }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let location = cwd == home ? "~" : (cwd as NSString).lastPathComponent
        return "\(location) - \(title.isEmpty ? "shell" : title)"
    }

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "-zsh", "-bash", "-fish"]
}

extension ChildProcess {
    /// Whether something other than the shell owns the terminal, so closing
    /// it would end work in progress.
    var isRunningJob: Bool { foregroundPID > 0 && foregroundPID != pid }

    /// A short name for the foreground job, for close confirmations and icons.
    var jobName: String {
        let identity = foreground ?? child
        if let executable = identity?.executable, !executable.isEmpty { return (executable as NSString).lastPathComponent }
        if let name = identity?.name, !name.isEmpty { return name }
        return command.first.map { ($0 as NSString).lastPathComponent } ?? "A process"
    }
}

/// What a tab or pane is running, drawn as a small badge. Programs without
/// their own icon, lazygit and ssh included, show the shell's.
enum ProcessBadge: Equatable {
    case shell, neovim, vim, claude, codex, fx, monitor

    init(program: String) {
        switch (program as NSString).lastPathComponent.lowercased() {
        case "nvim": self = .neovim
        case "vim", "vi": self = .vim
        case "claude", "cc": self = .claude
        case "codex": self = .codex
        case "fx": self = .fx
        case "top", "htop", "btop", "btm": self = .monitor
        default: self = .shell
        }
    }

    /// How strongly a tab's badge prefers this process over its others:
    /// agents, then editors, then monitors, then shells.
    var specificity: Int {
        switch self {
        case .claude, .codex, .fx: 3
        case .neovim, .vim: 2
        case .monitor: 1
        case .shell: 0
        }
    }

    /// Recognises programs from a terminal title, such as `✳ Claude Code`.
    init?(title: String) {
        if title.hasPrefix("✳") { self = .claude;return }
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words {
            let badge = ProcessBadge(program: String(word))
            if badge != .shell { self = badge;return }
        }
        return nil
    }
}
