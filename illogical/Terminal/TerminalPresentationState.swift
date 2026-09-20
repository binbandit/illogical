/// Coalesces redraw requests without losing a final update or reusing GPU buffers.
struct TerminalPresentationState {
    private(set) var requestedRevision: UInt64 = 1
    private(set) var submittedRevision: UInt64 = 0
    private(set) var acquiringDrawable = false
    private(set) var cancelled = false
    private var freeBuffers = [0, 1, 2]
    private var cleanSince: Double?
    var needsFrame: Bool { requestedRevision != submittedRevision }

    mutating func invalidate() {
        if !cancelled { requestedRevision &+= 1; cleanSince = nil }
    }
    mutating func shouldPauseDisplayLink(at time: Double) -> Bool {
        guard !needsFrame, !acquiringDrawable else { cleanSince = nil; return false }
        if let cleanSince { return time - cleanSince >= 0.1 }
        cleanSince = time
        return false
    }
    mutating func cancel() { cancelled = true }
    mutating func beginAcquisition() -> Int? {
        guard !cancelled, needsFrame, !acquiringDrawable, let slot = freeBuffers.popLast() else { return nil }
        acquiringDrawable = true
        return slot
    }
    mutating func acquired() { acquiringDrawable = false }
    mutating func submitted(revision: UInt64) { if !cancelled { submittedRevision = revision } }
    mutating func release(_ slot: Int) {
        assert(!freeBuffers.contains(slot), "Metal buffer released twice")
        freeBuffers.append(slot)
    }
}

/// Active renderers retain their resources. The pool shares those resources
/// without keeping every obsolete font or display scale alive indefinitely.
/// One recent resource stays warm for tab changes and window reopening.
@MainActor
final class TerminalResourcePool<Key: Hashable, Resource: AnyObject> {
    private final class Reference {
        weak var value: Resource?
        init(_ value: Resource) { self.value = value }
    }
    private var references: [Key: Reference] = [:]
    private var recent: Resource?

    func resource(for key: Key, usable: (Resource) -> Bool, create: () -> Resource) -> Resource {
        if let existing = references[key]?.value, usable(existing) {
            recent = existing
            return existing
        }
        // Prune only on a cache miss, not on the frame rendering path.
        references = references.filter { $0.value.value != nil }
        let resource = create()
        references[key] = Reference(resource)
        recent = resource
        return resource
    }
}

/// Geometry capacity follows the viewport, not changing terminal contents.
/// Hysteresis avoids reallocating on ordinary window-resize steps or clears.
struct TerminalGeometryCapacity {
    private var peakCells = 0

    mutating func resize(cells: Int) -> Bool {
        guard cells > 0 else { return false }
        if cells <= peakCells / 4 {
            peakCells = cells
            return true
        }
        peakCells = max(peakCells, cells)
        return false
    }
}

/// Text blinking exists only while visible, non-concealed content requests it.
/// Hiding a surface resets the phase so its first resumed frame is readable.
struct TerminalTextBlinkState {
    private(set) var hasBlinkingText = false
    private(set) var phaseVisible = true
    private var canPresent = false
    var timerRequired: Bool { hasBlinkingText && canPresent }

    mutating func update(hasBlinkingText: Bool, canPresent: Bool) {
        self.hasBlinkingText = hasBlinkingText; self.canPresent = canPresent
        if !timerRequired { phaseVisible = true }
    }
    mutating func advance() -> Bool {
        guard timerRequired else { return false }
        phaseVisible.toggle()
        return true
    }
    func drawsText(attributes: UInt8) -> Bool {
        attributes & 2 == 0 && (attributes & 4 == 0 || phaseVisible)
    }
}
