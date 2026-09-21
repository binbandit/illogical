import Foundation
import Darwin

nonisolated struct JSONLineFramer {
    enum Failure: Error { case messageTooLarge }
    let maximumMessageSize: Int
    private var partial = Data()

    // Swift 6.3 gives the memberwise initializer the private buffer's access
    // level, so the explicit one keeps the framer usable across the module.
    init(maximumMessageSize: Int) { self.maximumMessageSize = maximumMessageSize }

    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let start = base.advanced(by: offset)
                let newline = memchr(start, 10, bytes.count - offset)
                let count = newline.map { start.distance(to: $0) } ?? (bytes.count - offset)
                guard count <= maximumMessageSize - partial.count else { throw Failure.messageTooLarge }
                if let newline {
                    if partial.isEmpty {
                        lines.append(Data(bytes: start, count: count))
                    } else {
                        partial.append(start.assumingMemoryBound(to: UInt8.self), count: count)
                        lines.append(partial)
                        partial = Data()
                    }
                    offset = base.distance(to: newline) + 1
                } else {
                    partial.append(start.assumingMemoryBound(to: UInt8.self), count: count)
                    break
                }
            }
        }
        return lines
    }
}
