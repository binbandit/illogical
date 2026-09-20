import Foundation

@main
struct TerminalGraphicsTests {
    @MainActor static func main() throws {
        let image = WireGraphicsImage(id: 12, generation: 40, width: 1, height: 1, format: 1, data: Data([255, 0, 0, 128]))
        let placement = WireGraphicsPlacement(imageID: 12, imageGeneration: 40, id: 2, column: 1, row: -30,
            xOffset: 1, yOffset: 2, pixelWidth: 8, pixelHeight: 16, sourceX: 0, sourceY: 0, sourceWidth: 1, sourceHeight: 1, z: -1)
        let full = WireGraphicsState(generation: 50, reset: true, cellWidth: 8, cellHeight: 16, images: [image], placements: [placement])
        var state = TerminalGraphicsState()
        precondition(state.apply(full) && state.images.count == 1 && state.placements[0].row == -30)
        var delta = full; delta.reset = false; delta.images = []; delta.placements[0].row = -31
        precondition(state.apply(delta) && state.images.count == 1 && state.placements[0].row == -31)
        var replacement = image; replacement.generation = 41; replacement.data = Data([0, 255, 0, 255])
        delta.images = [replacement]; delta.placements[0].imageGeneration = 41
        precondition(state.apply(delta) && state.images[12]?.data == replacement.data)
        var invalid = delta; invalid.images[0].data = Data([0])
        precondition(!state.apply(invalid) && state.images[12]?.generation == 41, "Invalid transactions cannot replace valid pixels")
        invalid = delta; invalid.placements[0].sourceX = UInt32.max
        precondition(!state.apply(invalid))
        invalid = delta; invalid.placements = [WireGraphicsPlacement](repeating: placement, count: 1_025)
        precondition(!state.apply(invalid))
        invalid = delta; invalid.cellWidth = 0
        precondition(!state.apply(invalid))
        invalid = delta; invalid.placements[0].row = Int64.min
        precondition(!state.apply(invalid))
        delta.images = []; delta.placements = []
        precondition(state.apply(delta) && state.images.isEmpty && state.placements.isEmpty, "Deletion must release CPU pixel blobs")
        var orphan = full; orphan.images = []
        precondition(!state.apply(orphan), "A fresh snapshot must supply pixels for all referenced generations")
        for (format, bytes) in [(0, [UInt8](repeating: 1, count: 3)), (3, [UInt8](repeating: 2, count: 2)), (4, [UInt8](repeating: 3, count: 1))] {
            var scene = full; scene.images[0].format = format; scene.images[0].data = Data(bytes)
            precondition(state.apply(scene))
        }
        let serialized = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(WireGraphicsState.self, from: serialized)
        precondition(decoded.images[0].data == image.data && decoded.placements[0].row == -30)

        let ready = try Data(contentsOf: URL(fileURLWithPath: ".build/tests/graphics/ready.bin"))
        let pageCount = Int(try String(contentsOfFile: ".build/tests/graphics/history-count.txt", encoding: .utf8))!
        let history = try (0..<pageCount).map { try Data(contentsOf: URL(fileURLWithPath: ".build/tests/graphics/history-\($0).bin")) }
        let engine = TerminalEngine(blockID: "image-replay", theme: .merinoDark)
        var gaps = 0; engine.onReplayGap = { gaps += 1 }
        func snapshot(_ stream: String, _ epoch: String, _ sequence: UInt64) {
            engine.receive(WireMessage(type: "snapshot", stream: stream, data: ready, cols: 20, rows: 4, replayID: epoch, sequence: sequence))
            for (index, bytes) in history.enumerated() {
                engine.receive(WireMessage(type: "history", stream: stream, data: bytes, final: index == history.count - 1, replayID: epoch, sequence: sequence))
            }
        }
        snapshot("first", "epoch", 5)
        engine.receive(WireMessage(type: "graphics", stream: "first", replayID: "epoch", sequence: 5, graphics: full))
        precondition(engine.graphics.images.count == 1 && engine.sequence == 5 && gaps == 0, "Snapshot scene shares the snapshot sequence")
        engine.receive(WireMessage(type: "resume", stream: "second", replayID: "epoch", sequence: 5))
        delta = full; delta.reset = false; delta.images = []; delta.placements[0].row = -32
        let next = WireMessage(type: "graphics", stream: "second", replayID: "epoch", sequence: 6, previousSequence: 5, graphics: delta)
        engine.receive(next); engine.receive(next)
        precondition(engine.graphics.placements[0].row == -32 && engine.sequence == 6 && gaps == 0)
        engine.receive(WireMessage(type: "graphics", stream: "first", replayID: "epoch", sequence: 7, previousSequence: 6, graphics: full))
        precondition(engine.sequence == 6, "An old attachment cannot change images")
        engine.receive(WireMessage(type: "graphics", stream: "second", replayID: "epoch", sequence: 8, previousSequence: 7, graphics: full))
        precondition(gaps == 1 && engine.attachmentRequest().sequence == nil, "Missing graphics mutations require a fresh complete snapshot")
        snapshot("third", "new-epoch", 1)
        precondition(engine.graphics.images.isEmpty)
        engine.receive(WireMessage(type: "graphics", stream: "third", replayID: "new-epoch", sequence: 1, graphics: full))
        precondition(engine.graphics.images.count == 1 && engine.graphics.placements[0].row == -30)
        engine.search("chosen-text")
        engine.selectAll();let selected = engine.copy()
        engine.scrollTo(100)
        var viewportEvents: [UInt64] = [];engine.onViewportChange = { viewportEvents.append($0) }
        engine.receive(WireMessage(type: "snapshot", stream: "corrected", data: ready, text: "graphics", cols: 20, rows: 4, replayID: "new-epoch", sequence: 2))
        for (index, bytes) in history.enumerated() {
            engine.receive(WireMessage(type: "history", stream: "corrected", data: bytes, final: index == history.count - 1, replayID: "new-epoch", sequence: 2))
        }
        precondition(engine.frame()?.scrollOffset == 100 && engine.frame()?.searchCount == 2_000)
        precondition(engine.copy() == selected && selected?.isEmpty == false, "A graphics correction must preserve the local selection across delayed history")
        precondition(viewportEvents.isEmpty, "Correction snapshots cannot echo or reset a synchronized viewport")
        engine.scrollBottom();viewportEvents.removeAll()
        engine.receive(WireMessage(type: "snapshot", stream: "corrected-again", data: ready, text: "graphics", cols: 20, rows: 4, replayID: "new-epoch", sequence: 3))
        // An intentional user scroll while correction history is loading must
        // cancel the old preservation request, rather than snap back later.
        engine.scrollTo(0)
        for (index, bytes) in history.enumerated() {
            engine.receive(WireMessage(type: "history", stream: "corrected-again", data: bytes, final: index == history.count - 1, replayID: "new-epoch", sequence: 3))
        }
        precondition(il_terminal_scroll_distance(engine.handle) > 0)
        print("Native graphics: atomic pixel/placement deltas, formats/bounds/limits, delete release, complete snapshot restoration, reconnect replay ordering, duplicate/stale rejection, and gap resync passed.")
    }
}
