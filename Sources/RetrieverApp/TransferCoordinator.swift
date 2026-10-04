import Foundation
import RetrieverCore

struct TransferItem: Sendable {
    let id: UUID
    let remotePath: Data
    let localURL: URL
    let isDirectory: Bool
    let validationError: TransferIssue?

    init(id: UUID = UUID(), remotePath: Data, localURL: URL, isDirectory: Bool, validationError: TransferIssue? = nil) {
        self.id = id
        self.remotePath = remotePath
        self.localURL = localURL
        self.isDirectory = isDirectory
        self.validationError = validationError
    }
}

enum TransferDirection: Sendable { case download, upload }
enum TransferDecision { case replace, merge, skip, cancel }
struct TransferConflict {
    enum Kind { case file, folder }
    let item: TransferItem
    let kind: Kind
}
struct TransferProgress {
    let item: TransferItem
    let bytes: UInt64
    let completedFiles: Int
}
struct TransferFailure {
    let item: TransferItem
    let error: Error
}
struct TransferRootOutcome {
    let item: TransferItem
    let error: Error?
    let skipped: Bool
    var succeeded: Bool { error == nil && !skipped }
}
struct TransferSummary {
    var completedFiles = 0
    var skippedItems = 0
    var failures: [TransferFailure] = []
    var outcomes: [TransferRootOutcome] = []
    var cancelled = false
    var connectionLost = false
}

enum TransferIssue: LocalizedError {
    case unsupportedItem, typeMismatch, invalidName, missingSource, invalidDecision, nestingLimit
    var errorDescription: String? {
        switch self {
        case .unsupportedItem: "Only regular files and folders can be transferred. Symbolic links are skipped."
        case .typeMismatch: "The destination has a different file type. It was not replaced."
        case .invalidName: "A filename cannot be safely represented at the destination."
        case .missingSource: "The source no longer exists."
        case .invalidDecision: "The requested action is not valid for this conflict."
        case .nestingLimit: "This folder exceeds the transfer limit of 128 nested levels. Its contents were not transferred."
        }
    }
}

/// A small injectable boundary keeps queue policy independent of AppKit and SSH fixtures.
@MainActor
protocol TransferClient {
    var isConnected: Bool { get async }
    func attributes(_ path: Data, cancellation: SFTPCancellation) async throws -> RemoteAttributes?
    func entries(_ path: Data, cancellation: SFTPCancellation) async throws -> [RemoteEntry]
    func createDirectory(_ path: Data, cancellation: SFTPCancellation) async throws
    func download(_ path: Data, directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64
    func upload(directory: LocalTransferDirectory, name: String, path: Data, policy: UploadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64
}

@MainActor
private struct BrowserTransferClient: TransferClient {
    let browser: SFTPBrowser
    var isConnected: Bool { get async { await browser.isConnected } }
    func attributes(_ path: Data, cancellation: SFTPCancellation) async throws -> RemoteAttributes? {
        try await browser.attributes(at: path, cancellation: cancellation)
    }
    func entries(_ path: Data, cancellation: SFTPCancellation) async throws -> [RemoteEntry] {
        try await browser.directory(path, cancellation: cancellation).entries
    }
    func createDirectory(_ path: Data, cancellation: SFTPCancellation) async throws {
        try await browser.createDirectory(at: path, cancellation: cancellation)
    }
    func download(_ path: Data, directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try await browser.download(path, to: directory, name: name, policy: policy, cancellation: cancellation, progress: progress)
    }
    func upload(directory: LocalTransferDirectory, name: String, path: Data, policy: UploadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try await browser.upload(from: directory, name: name, to: path, policy: policy, cancellation: cancellation, progress: progress)
    }
}

/// One batch owns one cancellation signal. Folder traversal is iterative and all
/// local work below a captured root uses retained directory descriptors.
@MainActor
final class TransferCoordinator {
    private let client: any TransferClient
    private var progressGeneration: UUID?
    init(browser: SFTPBrowser) { client = BrowserTransferClient(browser: browser) }
    init(client: any TransferClient) { self.client = client }

    private struct Work {
        let item: TransferItem
        let parent: LocalTransferDirectory
        let depth: Int
    }

    func run(_ items: [TransferItem], direction: TransferDirection, cancellation: SFTPCancellation,
             conflict: @escaping @MainActor (TransferConflict) async -> TransferDecision,
             progress: @escaping @MainActor (TransferProgress) -> Void = { _ in },
             didDownload: @escaping @MainActor (TransferItem, UInt64) -> Void = { _, _ in },
             rootCompleted: @escaping @MainActor (TransferRootOutcome) -> Void = { _ in }) async -> TransferSummary {
        var summary = TransferSummary()
        let groups = Self.rootGroups(items, direction: direction)
        for group in groups {
            let root = group[0]
            var firstError: Error?
            var rootSkipped = false
            var stack: [Work] = []
            if summary.cancelled || summary.connectionLost {
                firstError = summary.cancelled ? CancellationError() : SFTPError.disconnected
            } else {
                do {
                    try cancellation.check()
                    if let error = root.validationError { throw error }
                    stack.append(Work(item: root, parent: try LocalTransferDirectory(url: root.localURL.deletingLastPathComponent()), depth: 0))
                } catch {
                    firstError = error
                    if error is CancellationError { summary.cancelled = true }
                    else { summary.failures.append(TransferFailure(item: root, error: error)) }
                }
            }
            while let work = stack.popLast() {
                do {
                    try cancellation.check()
                    guard work.depth <= 128 else { throw TransferIssue.nestingLimit }
                    let item = work.item
                    let name = item.localURL.lastPathComponent
                    guard Self.validName(name) else { throw TransferIssue.invalidName }
                    progress(TransferProgress(item: item, bytes: 0, completedFiles: summary.completedFiles))
                    let local = try work.parent.attributes(of: name)
                    let remote = try await client.attributes(item.remotePath, cancellation: cancellation)
                    let sourceKind: Kind?
                    let destinationKind: Kind?
                    switch direction {
                    case .download:
                        sourceKind = remote.map(Self.kind)
                        destinationKind = local.map { Self.kind($0.kind) }
                    case .upload:
                        sourceKind = local.map { Self.kind($0.kind) }
                        destinationKind = remote.map(Self.kind)
                    }
                    guard let sourceKind else { throw TransferIssue.missingSource }
                    guard sourceKind != .unsupported else { throw TransferIssue.unsupportedItem }
                    guard (sourceKind == .folder) == item.isDirectory else { throw TransferIssue.typeMismatch }
                    if let destinationKind, sourceKind != destinationKind { throw TransferIssue.typeMismatch }
                    var replace = false
                    if destinationKind != nil {
                        let answer = await conflict(TransferConflict(item: item, kind: item.isDirectory ? .folder : .file))
                        try cancellation.check()
                        switch answer {
                        case .cancel: cancellation.cancel(); throw CancellationError()
                        case .skip:
                            summary.skippedItems += 1
                            rootSkipped = true
                            continue
                        case .merge: guard item.isDirectory else { throw TransferIssue.invalidDecision }
                        case .replace: guard !item.isDirectory else { throw TransferIssue.invalidDecision }; replace = true
                        }
                    }
                    if item.isDirectory {
                        let localDirectory: LocalTransferDirectory
                        if direction == .download {
                            localDirectory = try destinationKind == nil ? work.parent.createDirectory(named: name) : work.parent.openDirectory(named: name)
                            let entries = try await client.entries(item.remotePath, cancellation: cancellation)
                            for (index, entry) in entries.reversed().enumerated() {
                                if index % 256 == 0 { await Task.yield() }
                                try cancellation.check()
                                guard let childName = String(data: entry.nameBytes, encoding: .utf8), Self.validName(childName) else {
                                    let error = TransferIssue.invalidName
                                    firstError = firstError ?? error
                                    summary.failures.append(TransferFailure(item: item, error: error))
                                    continue
                                }
                                let child = TransferItem(remotePath: SFTPSession.appending(entry.nameBytes, to: item.remotePath), localURL: item.localURL.appendingPathComponent(childName), isDirectory: entry.attributes.isDirectory)
                                stack.append(Work(item: child, parent: localDirectory, depth: work.depth + 1))
                            }
                        } else {
                            localDirectory = try work.parent.openDirectory(named: name)
                            if destinationKind == nil { try await client.createDirectory(item.remotePath, cancellation: cancellation) }
                            let entries = try await Task.detached(priority: .userInitiated) {
                                try localDirectory.entries(cancellation: cancellation)
                            }.value
                            try cancellation.check()
                            for (index, entry) in entries.reversed().enumerated() {
                                if index % 256 == 0 { await Task.yield() }
                                try cancellation.check()
                                guard Self.validName(entry.name) else { throw TransferIssue.invalidName }
                                let child = TransferItem(remotePath: SFTPSession.appending(Data(entry.name.utf8), to: item.remotePath), localURL: item.localURL.appendingPathComponent(entry.name), isDirectory: entry.kind == .directory)
                                stack.append(Work(item: child, parent: localDirectory, depth: work.depth + 1))
                            }
                        }
                    } else {
                        let completed = summary.completedFiles
                        let generation = UUID()
                        progressGeneration = generation
                        defer { progressGeneration = nil }
                        let report: @Sendable (UInt64) -> Void = { bytes in
                            Task { @MainActor [weak self] in
                                guard self?.progressGeneration == generation else { return }
                                progress(TransferProgress(item: item, bytes: bytes, completedFiles: completed))
                            }
                        }
                        let bytes: UInt64
                        if direction == .download {
                            bytes = try await client.download(item.remotePath, directory: work.parent, name: name, policy: replace ? .replaceApproved : .exclusive, cancellation: cancellation, progress: report)
                            didDownload(item, bytes)
                        } else {
                            bytes = try await client.upload(directory: work.parent, name: name, path: item.remotePath, policy: replace ? .replaceApproved : .exclusive, cancellation: cancellation, progress: report)
                        }
                        summary.completedFiles += 1
                        progress(TransferProgress(item: item, bytes: bytes, completedFiles: summary.completedFiles))
                    }
                } catch {
                    firstError = firstError ?? error
                    if error is CancellationError {
                        summary.cancelled = true
                        break
                    }
                    summary.failures.append(TransferFailure(item: work.item, error: error))
                    if !(await client.isConnected) {
                        summary.connectionLost = true
                        break
                    }
                }
            }
            for original in group {
                let outcome = TransferRootOutcome(item: original, error: firstError, skipped: rootSkipped)
                summary.outcomes.append(outcome)
                rootCompleted(outcome)
            }
        }
        return summary
    }

    private enum Kind { case file, folder, unsupported }
    private static func kind(_ attributes: RemoteAttributes) -> Kind {
        if attributes.isDirectory { return .folder }
        return attributes.permissions.map { $0 & 0xF000 == 0x8000 } == true ? .file : .unsupported
    }
    private static func kind(_ kind: LocalTransferEntry.Kind) -> Kind {
        switch kind {
        case .regularFile: .file
        case .directory: .folder
        default: .unsupported
        }
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    private static func rootGroups(_ items: [TransferItem], direction: TransferDirection) -> [[TransferItem]] {
        func path(_ item: TransferItem) -> Data {
            direction == .download ? item.remotePath : Data(item.localURL.standardizedFileURL.path.utf8)
        }
        let sorted = items.enumerated().sorted {
            let a = path($0.element).count, b = path($1.element).count
            return a == b ? $0.offset < $1.offset : a < b
        }
        var groups: [[TransferItem]] = []
        for (_, item) in sorted {
            let itemPath = path(item)
            if let index = groups.firstIndex(where: { group in
                let rootPath = path(group[0])
                return rootPath == itemPath || (group[0].isDirectory && itemPath.starts(with: rootPath + Data([47])))
            }) { groups[index].append(item) }
            else { groups.append([item]) }
        }
        // Roots remain in the user's selection order after removing nested duplicates.
        return groups.sorted { a, b in
            items.firstIndex(where: { $0.id == a[0].id })! < items.firstIndex(where: { $0.id == b[0].id })!
        }
    }
}
