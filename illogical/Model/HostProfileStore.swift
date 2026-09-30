import Combine
import Foundation

/// Remote host profiles shared by every window. Changes reach all live
/// workspaces synchronously so each can connect or disconnect at once.
@MainActor
final class HostProfileStore: ObservableObject {
    static let shared = HostProfileStore()
    @Published private(set) var hosts: [HostProfile]

    private init() {
        let saved = UserDefaults.standard.data(forKey: "hosts")
            .flatMap { try? JSONDecoder().decode([HostProfile].self, from: $0) } ?? []
        hosts = [.local] + saved.filter { !$0.isLocal }
    }

    /// Validates and adds a host, returning a message when the address is unusable.
    @discardableResult
    func add(name: String, address: String, executable: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.hasPrefix("-"),
              address.range(of: #"^[A-Za-z0-9_.@:\[\]-]+$"#, options: .regularExpression) != nil else {
            return "Enter a hostname, SSH alias, or user@host."
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(hosts + [HostProfile(id: UUID().uuidString, name: name.isEmpty ? address : name, address: address,
                                  executable: executable.isEmpty ? "illogical" : executable)])
        return nil
    }

    func remove(_ id: String) { save(hosts.filter { $0.id != id || $0.isLocal }) }

    private func save(_ updated: [HostProfile]) {
        guard updated != hosts, let data = try? JSONEncoder().encode(updated.filter { !$0.isLocal }) else { return }
        UserDefaults.standard.set(data, forKey: "hosts")
        hosts = updated
    }
}
