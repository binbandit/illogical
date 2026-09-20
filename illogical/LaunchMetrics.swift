import Foundation
import Metal
import os

@MainActor
enum LaunchMetrics {
    nonisolated private static let completion = LaunchCompletion()
    nonisolated private static let logger = Logger(subsystem: "dev.illogical.app", category: "launch")
    nonisolated static let tracing = ProcessInfo.processInfo.environment["ILLOGICAL_TRACE_LAUNCH"] == "1"
    static func mark(_ name: String) {
        guard tracing else { return }
        completion.mark(name, milliseconds: il_process_age_ms())
    }
    static func firstTerminalFrame(drawable: MTLDrawable) {
        guard !completion.hasReported else { return }
        drawable.addPresentedHandler { _ in
            guard completion.claim() else { return }
            let milliseconds = il_process_age_ms()
            logger.info("First usable terminal presented: \(milliseconds, format: .fixed(precision: 1)) ms from process creation")
            let record = LaunchRecord(date: ISO8601DateFormatter().string(from: Date()), firstTerminalFrameMS: milliseconds,
                                      pid: ProcessInfo.processInfo.processIdentifier, stages: tracing ? completion.stages : nil)
            guard var data = try? JSONEncoder().encode(record) else { return }
            data.append(10)
            let entry = data
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("illogical")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("launch.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                guard let file = try? FileHandle(forWritingTo: url) else { return }
                defer { try? file.close() }
                _ = try? file.seekToEnd(); try? file.write(contentsOf: entry)
            }
        }
    }
}

nonisolated private struct LaunchRecord: Encodable {
    let date: String
    let firstTerminalFrameMS: Double
    let pid: Int32
    let stages: [String: Double]?
}

nonisolated private final class LaunchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    private var stageTimes: [String: Double] = [:]
    var stages: [String: Double] { lock.withLock { stageTimes } }
    func mark(_ name: String, milliseconds: Double) {
        lock.withLock { if !reported && stageTimes[name] == nil { stageTimes[name] = milliseconds } }
    }
    var hasReported: Bool { lock.withLock { reported } }
    func claim() -> Bool {
        lock.withLock {
            guard !reported else { return false }
            reported = true
            return true
        }
    }
}
