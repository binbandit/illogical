import Combine
import Foundation

@MainActor
final class HostDiscovery: ObservableObject {
    struct Host: Decodable, Identifiable {
        var id: String { address }
        let name: String
        let address: String
        let service: String
    }
    @Published var hosts: [Host] = []
    @Published var message: String?
    @Published var loading = false

    func discover() {
        guard !loading else { return }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("bin/illogical"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            message = "The connection helper is missing from this app."; return
        }
        loading = true; message = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), output = Pipe()
            process.executableURL = executable
            process.arguments = ["tailscale", "discover"]
            var environment = ProcessInfo.processInfo.environment; environment["TAILSCALE_BE_CLI"] = "1"; process.environment = environment
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
                defer { timeout.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                let hosts = try JSONDecoder().decode([Host].self, from: data).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                Task { @MainActor [weak self] in self?.hosts = hosts; self?.loading = false; if hosts.isEmpty { self?.message = "No advertised illogical services found on your tailnet." } }
            } catch {
                Task { @MainActor [weak self] in self?.loading = false; self?.message = "Could not discover services. Check that Tailscale is installed and connected." }
            }
        }
    }
}
