import Foundation

/// A single-reader, single-consumer wire queue. Only producers wait for space;
/// the UI drains bounded batches and never waits for the reader.
nonisolated final class InboundMailbox: @unchecked Sendable {
    enum Event: Sendable { case message(WireMessage), finished(String?) }
    enum EnqueueResult { case accepted(schedule: Bool), cancelled }
    private struct Packet { var event: Event; var charge: Int }
    private let condition = NSCondition()
    private let maximumBytes: Int
    private let maximumItems: Int
    private var packets: [Packet?] = []
    private var head = 0
    private var bytes = 0
    private var scheduled = false
    private var cancelled = false
    private var sealed = false

    init(maximumBytes: Int = 8 * 1024 * 1024, maximumItems: Int = 1024) {
        precondition(maximumBytes > 0 && maximumItems > 0)
        self.maximumBytes = maximumBytes; self.maximumItems = maximumItems
    }

    func enqueue(_ event: Event, wireBytes: Int = 0) -> EnqueueResult {
        let payload: Int
        if case .message(let message) = event { payload = message.data?.count ?? 0 } else { payload = 0 }
        let charge = max(payload, wireBytes) + 512
        condition.lock(); defer { condition.unlock() }
        // An individual large snapshot is admitted exclusively. Its maximum
        // size is already enforced by the wire framer, so it cannot deadlock.
        while !cancelled && !sealed && packets.count > head &&
                (charge > maximumBytes - bytes || packets.count - head >= maximumItems) {
            condition.wait()
        }
        guard !cancelled && !sealed else { return .cancelled }
        packets.append(Packet(event: event, charge: charge)); bytes += charge
        if case .finished = event { sealed = true }
        let needsSchedule = !scheduled
        scheduled = true
        return .accepted(schedule: needsSchedule)
    }

    func takeBatch(maximumBytes: Int = 256 * 1024, maximumItems: Int = 128) -> [Event] {
        condition.lock()
        var result: [Event] = []
        var consumed = 0
        while !cancelled && head < packets.count && result.count < maximumItems {
            guard let packet = packets[head] else { break }
            if !result.isEmpty && packet.charge > maximumBytes - consumed { break }
            packets[head] = nil; head += 1; bytes -= packet.charge; consumed += packet.charge
            result.append(packet.event)
        }
        if head == packets.count { packets.removeAll(keepingCapacity: true); head = 0 }
        else if head >= 1024 && head * 2 >= packets.count { packets.removeFirst(head); head = 0 }
        condition.broadcast()
        condition.unlock()
        // Coalesce after releasing the lock; the socket reader can keep filling
        // the mailbox while the UI prepares this batch. Barriers stay in place.
        var coalesced: [Event] = []
        for event in result {
            if case .message(let next) = event, next.type == "output", next.id == nil,
               case .message(var previous)? = coalesced.last, previous.type == "output", previous.id == nil,
               previous.block == next.block, previous.stream == next.stream,
               previous.replayID == next.replayID, previous.sequence == next.previousSequence,
               let data = next.data, (previous.data?.count ?? 0) + data.count <= 256 * 1024 {
                coalesced.removeLast()
                if previous.data == nil { previous.data = data } else { previous.data?.append(data) }
                previous.sequence = next.sequence
                coalesced.append(.message(previous))
            } else { coalesced.append(event) }
        }
        return coalesced
    }

    /// Called after every drain, even an empty one. The lock closes the race
    /// between a producer enqueueing and the consumer going idle.
    func finishDrain() -> Bool {
        condition.lock(); defer { condition.unlock() }
        if cancelled || head == packets.count { scheduled = false; return false }
        return true
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true; packets.removeAll(); head = 0; bytes = 0; scheduled = false
        condition.broadcast()
    }
}
