import Foundation

/// Fails without trapping, so a failing test never opens the crash reporter.
nonisolated private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #fileID, line: UInt = #line) {
    guard !condition() else { return }
    FileHandle.standardError.write(Data("FAIL \(file):\(line) \(message())\n".utf8))
    exit(1)
}

@main enum JSONLineFramerTests {
    static func main() throws {
        let expected = [Data("{\"text\":\"👩🏽‍💻 café\"}".utf8), Data(repeating: 65, count: 350_000), Data("{}".utf8)]
        var stream = Data()
        for line in expected { stream.append(line); stream.append(10) }
        for chunkSize in [1, 7, 4096, 16384, 262144, stream.count] {
            var framer = JSONLineFramer(maximumMessageSize: 350_000)
            var actual: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + chunkSize)
                actual += try framer.append(Data(stream[offset..<end]))
                offset = end
            }
            expect(actual == expected, "Corrupted stream with chunk size \(chunkSize)")
        }
        var limited = JSONLineFramer(maximumMessageSize: 3)
        _ = try limited.append(Data("abc".utf8))
        do { _ = try limited.append(Data("d\n".utf8)); fatalError("Accepted oversized message") }
        catch JSONLineFramer.Failure.messageTooLarge { }
        var small = JSONLineFramer(maximumMessageSize: 2)
        let complete = try small.append(Data("{}\n{}\n".utf8))
        expect(complete == [Data("{}".utf8), Data("{}".utf8)])
        print("Message framing: split UTF-8, 350 KB messages, boundary sizes, and limits passed")
    }
}
