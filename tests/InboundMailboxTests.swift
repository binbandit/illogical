import Foundation

/// Fails without trapping, so a failing test never opens the crash reporter.
nonisolated private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #fileID, line: UInt = #line) {
    guard !condition() else { return }
    FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
    exit(1)
}

nonisolated private func message(_ type: String, block: String = "a", stream: String = "one", bytes: Data? = nil) -> InboundMailbox.Event {
    .message(WireMessage(type: type, block: block, stream: stream, data: bytes))
}

@main
enum InboundMailboxTests {
    static func main() {
        let queue = InboundMailbox()
        let events: [InboundMailbox.Event] = [
            message("snapshot", bytes: Data([1])), message("output", bytes: Data([2])), message("output", bytes: Data([3])),
            message("history", bytes: Data([4])), message("output", bytes: Data([5])),
            message("output", block: "b", bytes: Data([6])), message("output", block: "b", stream: "two", bytes: Data([7])),
            .finished("end")
        ]
        var scheduled = 0
        for event in events {
            guard case .accepted(let schedule) = queue.enqueue(event) else { fatalError("Rejected valid stream") }
            if schedule { scheduled += 1 }
        }
        expect(scheduled == 1, "One notification schedules the entire pending stream")
        let batch = queue.takeBatch()
        var seen: [String] = []
        for event in batch {
            switch event {
            case .message(let value): seen.append("\(value.type):\(value.block!):\(value.stream!):\(Array(value.data ?? Data()))")
            case .finished(let reason): seen.append("EOF:\(reason!)")
            }
        }
        expect(seen == ["snapshot:a:one:[1]", "output:a:one:[2, 3]", "history:a:one:[4]", "output:a:one:[5]", "output:b:one:[6]", "output:b:two:[7]", "EOF:end"], "Coalescing must preserve all protocol barriers and EOF order")
        expect(!queue.finishDrain())
        guard case .cancelled = queue.enqueue(message("output")) else { fatalError("Data accepted after EOF") }

        for countBound in [false, true] {
            let limited = InboundMailbox(maximumBytes: countBound ? 65536 : 4096, maximumItems: countBound ? 2 : 100)
            let packet = message("output", bytes: Data(repeating: 65, count: 1536))
            _ = limited.enqueue(packet); _ = limited.enqueue(packet)
            let attempted = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                attempted.signal()
                guard case .accepted = limited.enqueue(packet) else { fatalError("Drain did not release producer") }
                completed.signal()
            }
            expect(attempted.wait(timeout: .now() + 2) == .success)
            expect(completed.wait(timeout: .now() + 0.05) == .timedOut, "Producer must wait at the byte/count limit")
            expect(limited.takeBatch(maximumBytes: 1).count == 1)
            expect(completed.wait(timeout: .now() + 2) == .success, "Consumer progress must wake producer")
            limited.cancel()
        }

        let cancelled = InboundMailbox(maximumBytes: 512, maximumItems: 1)
        _ = cancelled.enqueue(message("snapshot", bytes: Data(repeating: 1, count: 2048)))
        let blocked = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            blocked.signal()
            guard case .cancelled = cancelled.enqueue(.finished(nil)) else { fatalError("Cancelled producer published EOF") }
            released.signal()
        }
        expect(blocked.wait(timeout: .now() + 2) == .success)
        expect(released.wait(timeout: .now() + 0.05) == .timedOut)
        cancelled.cancel()
        expect(released.wait(timeout: .now() + 2) == .success)
        expect(cancelled.takeBatch().isEmpty && !cancelled.finishDrain())

        // Drain and enqueue race repeatedly, as happens between display frames.
        let streaming = InboundMailbox(maximumBytes: 1024 * 1024, maximumItems: 64)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for index in 0..<8192 {
                let bytes = Data(repeating: UInt8(index % 251), count: 4096)
                if case .accepted(let schedule) = streaming.enqueue(message("output", bytes: bytes)), schedule { ready.signal() }
            }
            if case .accepted(let schedule) = streaming.enqueue(.finished(nil)), schedule { ready.signal() }
            finished.signal()
        }
        var offset = 0, eof = false
        while !eof {
            expect(ready.wait(timeout: .now() + 5) == .success, "Lost wakeup in streaming delivery")
            repeat {
                for event in streaming.takeBatch() {
                    switch event {
                    case .message(let value):
                        for byte in value.data! { expect(byte == UInt8((offset / 4096) % 251)); offset += 1 }
                    case .finished: eof = true
                    }
                }
            } while streaming.finishDrain()
        }
        expect(offset == 32 * 1024 * 1024 && finished.wait(timeout: .now() + 2) == .success)
        print("Connection delivery: 32MiB ordered stream, barriers/EOF, coalescing, byte/count backpressure, cancellation and wakeups passed.")
    }
}
