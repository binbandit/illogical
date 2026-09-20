import Foundation

@main
struct TerminalReplayTests {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: ".build/tests/search-contrast")
        let ready = try Data(contentsOf: root.appendingPathComponent("snapshot-ready.bin"))
        let count = Int(try String(contentsOf: root.appendingPathComponent("history-count.txt"), encoding: .utf8))!
        let engine = TerminalEngine(blockID: "replay", theme: .merinoDark)
        var gaps = 0
        engine.onReplayGap = { gaps += 1 }
        engine.receive(WireMessage(type: "snapshot", stream: "first", data: ready, cols: 120, rows: 12, replayID: "epoch", sequence: 10))
        precondition(engine.attachmentRequest().replayID == nil, "Incomplete history must request a full snapshot")
        for index in 0..<count {
            let data = try Data(contentsOf: root.appendingPathComponent(String(format: "history-%02d.bin", index)))
            engine.receive(WireMessage(type: "history", stream: "first", data: data, final: index == count - 1, replayID: "epoch", sequence: 10))
        }
        precondition(engine.attachmentRequest().sequence == 10 && !engine.loadingHistory)
        var sharedOffsets: [UInt64] = []
        engine.onViewportChange = { sharedOffsets.append($0) }
        engine.scrollTo(12)
        let viewportFrame = engine.frame()!
        precondition(sharedOffsets.last == viewportFrame.scrollTotal - viewportFrame.scrollLength - 12)
        engine.receiveViewport(0)
        precondition(sharedOffsets.count == 1 && engine.frame()?.scrollOffset == viewportFrame.scrollTotal - viewportFrame.scrollLength,
                     "Remote viewport updates must not echo and must map from bottom-relative history")
        engine.receiveViewport(UInt64.max)
        precondition(engine.frame()?.scrollOffset == 0, "Incomplete local history must clamp safely")
        engine.onViewportChange = nil
        var pixelSizes: [(UInt32, UInt32)] = []
        engine.onResize = { _, _, width, height in pixelSizes.append((width, height)) }
        engine.requestResize(columns: 120, rows: 12, cellWidth: 16, cellHeight: 38)
        engine.requestResize(columns: 120, rows: 12, cellWidth: 16, cellHeight: 38)
        engine.requestResize(columns: 120, rows: 12, cellWidth: 8, cellHeight: 19)
        precondition(pixelSizes.count == 2 && pixelSizes.last?.0 == 8, "A scale change must update pixel geometry without requiring a grid change")
        let oldHandle = engine.handle
        engine.search("audit-marker");engine.scrollTo(0)
        engine.receive(WireMessage(type: "resume", stream: "second", replayID: "epoch", sequence: 10))
        precondition(engine.handle == oldHandle && engine.stream == "second" && engine.frame()?.scrollOffset == 0,
                     "Resume must preserve scrollback, selection/search state and the existing parser")
        let output = WireMessage(type: "output", stream: "second", data: Data("\r\nreplay-marker".utf8), replayID: "epoch", sequence: 12, previousSequence: 10)
        engine.receive(output);engine.receive(output)
        precondition(engine.sequence == 12 && gaps == 0)
        engine.search("replay-marker");precondition(engine.frame()?.searchCount == 1, "Duplicate output must not be applied twice")
        engine.receive(WireMessage(type: "resize", stream: "first", cols: 55, rows: 8, replayID: "epoch", sequence: 13, previousSequence: 12))
        precondition(engine.columns == 120 && engine.sequence == 12, "Old streams must not resize a resumed terminal")
        engine.receive(WireMessage(type: "resize", stream: "second", cols: 55, rows: 8, replayID: "epoch", sequence: 13, previousSequence: 12))
        precondition(engine.columns == 55 && engine.sequence == 13)
        engine.receive(WireMessage(type: "output", stream: "second", data: Data("dropped predecessor".utf8), replayID: "epoch", sequence: 15, previousSequence: 14))
        precondition(gaps == 1 && engine.attachmentRequest().replayID == nil && engine.stream == nil,
                     "A gap must request a full snapshot instead of corrupting the parser")
        engine.receive(WireMessage(type: "resync", text: "recent output is no longer retained"))
        engine.receive(WireMessage(type: "snapshot", stream: "third", data: ready, cols: 120, rows: 12, replayID: "new-epoch", sequence: 1))
        precondition(engine.stream == "third" && engine.columns == 120 && engine.replayID == "new-epoch")

        let mailbox = InboundMailbox()
        for (previous, next) in [(10, 11), (11, 12), (14, 15)] {
            _ = mailbox.enqueue(.message(WireMessage(type: "output", block: "replay", stream: "one", data: Data("x".utf8), replayID: "epoch", sequence: UInt64(next), previousSequence: UInt64(previous))))
        }
        let batch = mailbox.takeBatch()
        precondition(batch.count == 2, "Only contiguous output may be coalesced")
        if case .message(let combined) = batch[0] {
            precondition(combined.previousSequence == 10 && combined.sequence == 12 && combined.data?.count == 2)
        } else { fatalError("Expected coalesced output") }
        print("Replay: complete-history gate, same-parser resume, deduplication, stream isolation, gaps, resync and contiguous coalescing passed.")
    }
}
