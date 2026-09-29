import Foundation

public struct SavedHost: Codable, Equatable, Sendable {
    public let settings: ConnectionSettings
    public fileprivate(set) var lastPath: Data
}

/// Local connection metadata only: never passwords, key contents or trust decisions.
@MainActor
public final class ConnectionHistory {
    private let defaults: UserDefaults
    private let key = "savedHosts.v1"
    public private(set) var hosts: [SavedHost]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedHost].self, from: $0) } ?? []
    }

    public func remember(_ settings: ConnectionSettings, path: Data) {
        hosts.removeAll { $0.settings == settings }
        hosts.insert(SavedHost(settings: settings, lastPath: path), at: 0)
        persist()
    }

    public func updateLocation(_ path: Data, for settings: ConnectionSettings) {
        // Forgetting a currently connected host must remain effective while browsing.
        guard let index = hosts.firstIndex(where: { $0.settings == settings }), hosts[index].lastPath != path else { return }
        hosts[index].lastPath = path
        persist()
    }

    public func forget(_ settings: ConnectionSettings) {
        hosts.removeAll { $0.settings == settings }
        persist()
    }

    private func persist() {
        // These concrete value types have no fallible custom encoding.
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: key) }
    }
}
