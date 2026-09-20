@main
struct TerminalPresentationTests {
    @MainActor
    static func main() {
        var state = TerminalPresentationState()
        for _ in 0..<10_000 { state.invalidate() }
        let first = state.beginAcquisition()!
        precondition(state.beginAcquisition() == nil, "Only one drawable acquisition may wait at a time")
        state.invalidate()
        state.acquired()
        let drawn = state.requestedRevision
        state.invalidate()
        state.submitted(revision: drawn)
        precondition(state.needsFrame, "An update arriving during a draw must reach a later frame")
        state.release(first)
        let final = state.beginAcquisition()!
        state.acquired()
        state.submitted(revision: state.requestedRevision)
        state.release(final)
        precondition(!state.needsFrame && state.beginAcquisition() == nil, "An unchanged terminal must stop presenting")
        precondition(!state.shouldPauseDisplayLink(at: 1), "One clean tick must not tear down the display link")
        precondition(!state.shouldPauseDisplayLink(at: 1.05), "Brief output gaps must retain the existing display link")
        state.invalidate()
        let burst = state.beginAcquisition()!
        state.acquired();state.submitted(revision:state.requestedRevision);state.release(burst)
        precondition(!state.shouldPauseDisplayLink(at: 1.09), "New output must reset the idle grace period")
        precondition(!state.shouldPauseDisplayLink(at: 1.15))
        precondition(state.shouldPauseDisplayLink(at: 1.20), "A quiet terminal must eventually pause its display link")

        var busy = TerminalPresentationState()
        var buffers: [Int] = []
        for _ in 0..<3 {
            busy.invalidate()
            buffers.append(busy.beginAcquisition()!)
            busy.acquired()
            busy.submitted(revision: busy.requestedRevision)
        }
        precondition(Set(buffers).count == 3, "Frames may not reuse a buffer still owned by the GPU")
        busy.invalidate()
        precondition(busy.beginAcquisition() == nil && busy.needsFrame, "GPU pressure must retain the pending frame without waiting")
        busy.release(buffers.removeLast())
        let available = busy.beginAcquisition()!
        busy.acquired()
        busy.release(available) // Simulates a timed-out nextDrawable or a resized surface.
        precondition(busy.needsFrame, "A failed drawable acquisition must not consume the final update")
        let retry = busy.beginAcquisition()!
        busy.cancel()
        let cancelledRevision = busy.requestedRevision
        busy.invalidate()
        busy.acquired()
        busy.release(retry)
        for slot in buffers { busy.release(slot) }
        precondition(busy.beginAcquisition() == nil && busy.requestedRevision == cancelledRevision, "Detaching must cancel deferred draws")
        // A sustained stream never pauses the display link; a stopped stream
        // presents its final update and then makes no more GPU acquisitions.
        var stream = TerminalPresentationState()
        var frames = 0
        for tick in 0..<7_200 {
            if tick < 3_600 { for _ in 0..<8 { stream.invalidate() } }
            if let slot = stream.beginAcquisition() {
                frames += 1
                stream.acquired(); stream.submitted(revision: stream.requestedRevision); stream.release(slot)
            }
            if tick < 3_600 { precondition(!stream.shouldPauseDisplayLink(at: Double(tick) / 120)) }
        }
        precondition(frames == 3_600 && !stream.needsFrame)
        precondition(stream.shouldPauseDisplayLink(at: 60))

        testResourceLifetime()
        var capacity = TerminalGeometryCapacity()
        precondition(!capacity.resize(cells: 40_000))
        precondition(!capacity.resize(cells: 20_000), "Ordinary resize steps should reuse geometry")
        precondition(capacity.resize(cells: 10_000), "A viewport four times smaller should release peak geometry")
        precondition(!capacity.resize(cells: 10_000), "Unchanged geometry must not allocate each frame")
        precondition(!capacity.resize(cells: 9_000))
        precondition(!capacity.resize(cells: 0), "A transient empty layout must not discard reusable geometry")
        precondition(capacity.resize(cells: 2_500), "Gradual shrinking must eventually release retained capacity")
        var blink = TerminalTextBlinkState()
        blink.update(hasBlinkingText: false, canPresent: true)
        precondition(!blink.timerRequired && !blink.advance() && blink.drawsText(attributes: 0))
        blink.update(hasBlinkingText: true, canPresent: true)
        precondition(blink.timerRequired && blink.drawsText(attributes: 4))
        precondition(blink.advance() && !blink.drawsText(attributes: 4) && blink.drawsText(attributes: 0))
        precondition(!blink.drawsText(attributes: 2), "Invisible text must stay concealed in both blink phases")
        blink.update(hasBlinkingText: true, canPresent: false)
        precondition(!blink.timerRequired && !blink.advance() && blink.phaseVisible, "Hidden/occluded surfaces must stop their blink timer")
        blink.update(hasBlinkingText: true, canPresent: true)
        precondition(blink.timerRequired && blink.drawsText(attributes: 4), "Revealing a surface starts with readable text")
        blink.update(hasBlinkingText: false, canPresent: true)
        precondition(!blink.timerRequired && !blink.advance(), "Removing the last blinking cell must stop scheduling")
        print("Metal presentation: burst coalescing, idle grace, final-frame delivery, bounded drawable acquisition, GPU buffer ownership, retry, cancellation, and shared resource lifetime passed.")
    }

    @MainActor
    static func testResourceLifetime() {
        final class Resource { var usable = true }
        let pool = TerminalResourcePool<Int, Resource>()
        func acquire(_ key: Int) -> Resource {
            pool.resource(for: key, usable: { $0.usable }, create: { Resource() })
        }
        var active: Resource? = acquire(0)
        weak let first = active
        precondition(acquire(0) === active, "Surfaces with the same font must share their atlas")
        var unusedReferences: [() -> Resource?] = []
        for key in 1...100 {
            let resource = acquire(key)
            unusedReferences.append({ [weak resource] in resource })
        }
        precondition(first != nil, "Changing other fonts must not evict an active surface's atlas")
        precondition(unusedReferences.filter { $0() != nil }.count == 1, "Only one inactive atlas may remain warm")
        precondition(acquire(0) === active, "An active atlas must remain discoverable after many other fonts")
        precondition(unusedReferences.allSatisfy { $0() == nil }, "Reusing an active atlas releases the last stale warm atlas")
        active?.usable = false
        let replacement = acquire(0)
        precondition(replacement !== active, "An exhausted atlas must be replaceable")
        active = nil
        precondition(first == nil, "Replacing an atlas must release it after the last surface lets go")
    }
}
