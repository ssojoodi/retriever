import Foundation

public struct CompletedDownload: Codable, Identifiable, Sendable {
    public let id: UUID
    public let filename: String
    public let settings: ConnectionSettings
    public let remotePath: Data
    public let completedAt: Date
    public let byteCount: UInt64
    public let destination: URL
    public fileprivate(set) var bookmark: Data?
}

@MainActor
public final class DownloadHistory {
    private let defaults: UserDefaults
    private let key = "completedDownloads.v1"
    public private(set) var entries: [CompletedDownload]
    public var didChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([CompletedDownload].self, from: $0) } ?? []
    }

    public func record(filename: String, settings: ConnectionSettings, remotePath: Data, destination: URL, byteCount: UInt64) {
        let bookmark = try? destination.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        entries.insert(CompletedDownload(id: UUID(), filename: filename, settings: settings, remotePath: remotePath, completedAt: Date(), byteCount: byteCount, destination: destination, bookmark: bookmark), at: 0)
        persist()
        didChange?()
    }

    public func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: key)
        didChange?()
    }

    public func location(for id: UUID) -> URL? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var location = entries[index].destination
        if let bookmark = entries[index].bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            location = resolved
            if stale {
                entries[index].bookmark = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                persist()
            }
        }
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    private func persist() {
        // These value types contain no custom or fallible encoders.
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
