import Foundation
@testable import RetrieverCore

@MainActor
private final class FixtureTransfers: TransferClient {
    struct Node {
        let mode: UInt32
        var data = Data()
        var attributes: RemoteAttributes { RemoteAttributes(size: UInt64(data.count), permissions: mode, modified: nil) }
    }
    var nodes: [Data: Node] = [:]
    var operations: [String] = []
    var attributeRequests: [Data] = []
    var connected = true
    var failingPaths: Set<Data> = []
    var disconnectOnFailure = false
    var isConnected: Bool { get async { connected } }
    func add(_ path: String, mode: UInt32 = 0o100600, text: String = "payload") {
        nodes[Data(path.utf8)] = Node(mode: mode, data: Data(text.utf8))
    }
    func attributes(_ path: Data, cancellation: SFTPCancellation) async throws -> RemoteAttributes? {
        try cancellation.check()
        attributeRequests.append(path)
        return nodes[path]?.attributes
    }
    func entries(_ path: Data, cancellation: SFTPCancellation) async throws -> [RemoteEntry] {
        try cancellation.check()
        let prefix = path + Data([47])
        return nodes.compactMap { key, node -> RemoteEntry? in
            guard key.starts(with: prefix) else { return nil }
            let name = Data(key.dropFirst(prefix.count))
            guard !name.contains(47) else { return nil }
            return RemoteEntry(nameBytes: name, attributes: node.attributes)
        }.sorted { $0.nameBytes.lexicographicallyPrecedes($1.nameBytes) }
    }
    func createDirectory(_ path: Data, cancellation: SFTPCancellation) async throws {
        try cancellation.check()
        operations.append("mkdir " + String(decoding: path, as: UTF8.self))
        precondition(nodes[path] == nil)
        nodes[path] = Node(mode: 0o40700)
    }
    func checkFailure(_ path: Data) throws {
        if failingPaths.contains(path) {
            if disconnectOnFailure { connected = false }
            throw SFTPError.server(3, "Fixture failure")
        }
    }
    func download(_ path: Data, directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try cancellation.check()
        operations.append("download " + String(decoding: path, as: UTF8.self))
        try checkFailure(path)
        let data = nodes[path]!.data
        let url = directory.url.appendingPathComponent(name)
        if policy == .exclusive { precondition(!FileManager.default.fileExists(atPath: url.path)) }
        try data.write(to: url)
        progress(UInt64(data.count))
        return UInt64(data.count)
    }
    func upload(directory: LocalTransferDirectory, name: String, path: Data, policy: UploadDestinationPolicy, cancellation: SFTPCancellation, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try cancellation.check()
        operations.append("upload " + String(decoding: path, as: UTF8.self))
        try checkFailure(path)
        if policy == .exclusive { precondition(nodes[path] == nil) }
        let data = try Data(contentsOf: directory.url.appendingPathComponent(name))
        nodes[path] = Node(mode: 0o100600, data: data)
        progress(UInt64(data.count))
        return UInt64(data.count)
    }
}

@main
@MainActor
struct TransferChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Retriever-transfer-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        func item(_ path: String, _ url: URL, directory: Bool = false) -> TransferItem {
            TransferItem(remotePath: Data(path.utf8), localURL: url, isDirectory: directory)
        }
        func regularConflict(_ conflict: TransferConflict) async -> TransferDecision {
            conflict.kind == .folder ? .merge : .replace
        }

        // Nested roots are transferred once, empty folders survive, and history is file-only.
        let downloadArea = try folder("download")
        let source = FixtureTransfers()
        source.add("/tree", mode: 0o40700)
        source.add("/tree/empty", mode: 0o40700)
        source.add("/tree/deep", mode: 0o40700)
        source.add("/tree/deep/a.txt", text: "nested")
        source.add("/tree/b.txt", text: "root")
        let parent = item("/tree", downloadArea.appendingPathComponent("tree"), directory: true)
        let nested = item("/tree/deep/a.txt", parent.localURL.appendingPathComponent("deep/a.txt"))
        var recorded: [Data] = []
        var completed: [UUID] = []
        let download = await TransferCoordinator(client: source).run([parent, nested, parent], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict, didDownload: { item, _ in recorded.append(item.remotePath) }, rootCompleted: { completed.append($0.item.id) })
        precondition(download.completedFiles == 2 && download.failures.isEmpty && download.outcomes.count == 3)
        precondition(download.outcomes.allSatisfy(\.succeeded) && recorded.count == 2 && completed.count == 3)
        precondition(FileManager.default.fileExists(atPath: parent.localURL.appendingPathComponent("empty").path))
        let nestedText = try String(contentsOf: nested.localURL, encoding: .utf8)
        precondition(nestedText == "nested")

        // Skip a folder conflict without visiting its children; keep unrelated successful roots.
        var visited: [TransferConflict.Kind] = []
        source.add("/separate.txt")
        let skipped = await TransferCoordinator(client: source).run([parent, item("/separate.txt", downloadArea.appendingPathComponent("separate.txt"))], direction: .download, cancellation: SFTPCancellation(), conflict: { conflict in visited.append(conflict.kind); return .skip })
        precondition(visited.count == 1 && visited[0] == .folder)
        precondition(skipped.completedFiles == 1 && skipped.skippedItems == 1 && skipped.outcomes[0].skipped)

        // Replacement approval is per file, and a type mismatch cannot replace a folder.
        source.add("/tree/b.txt", text: "replacement")
        let replaced = await TransferCoordinator(client: source).run([item("/tree/b.txt", parent.localURL.appendingPathComponent("b.txt")), item("/separate.txt", parent.localURL.appendingPathComponent("empty"))], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(replaced.completedFiles == 1 && replaced.failures.count == 1)
        let replacedText = try String(contentsOf: parent.localURL.appendingPathComponent("b.txt"), encoding: .utf8)
        precondition(replacedText == "replacement")

        // Symlinks are reported, never followed; other siblings still transfer.
        source.add("/tree/link", mode: 0o120777)
        let withLink = await TransferCoordinator(client: source).run([parent], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(withLink.completedFiles == 2 && withLink.failures.count == 1 && !withLink.outcomes[0].succeeded)
        precondition(!FileManager.default.fileExists(atPath: parent.localURL.appendingPathComponent("link").path))

        // Recursive upload preserves empty folders and does not follow local links.
        let uploadArea = try folder("upload")
        try FileManager.default.createDirectory(at: uploadArea.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("upload".utf8).write(to: uploadArea.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(atPath: uploadArea.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
        let remote = FixtureTransfers()
        let uploaded = await TransferCoordinator(client: remote).run([item("/uploaded", uploadArea, directory: true)], direction: .upload, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(uploaded.completedFiles == 1 && uploaded.failures.count == 1)
        precondition(remote.nodes[Data("/uploaded/empty".utf8)]?.attributes.isDirectory == true)
        precondition(remote.nodes[Data("/uploaded/link".utf8)] == nil)

        try Data("updated upload".utf8).write(to: uploadArea.appendingPathComponent("a.txt"))
        let uploadReplaced = await TransferCoordinator(client: remote).run([item("/uploaded", uploadArea, directory: true)], direction: .upload, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(uploadReplaced.completedFiles == 1 && uploadReplaced.failures.count == 1)
        precondition(remote.nodes[Data("/uploaded/a.txt".utf8)]?.data == Data("updated upload".utf8))

        // Invalid remote names are reported without lossy decoding or escaping the chosen root.
        let names = FixtureTransfers()
        names.add("/names", mode: 0o40700)
        names.nodes[Data("/names/".utf8) + Data([255])] = FixtureTransfers.Node(mode: 0o100600)
        let invalid = await TransferCoordinator(client: names).run([item("/names", downloadArea.appendingPathComponent("names"), directory: true)], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(invalid.failures.count == 1 && invalid.completedFiles == 0 && !invalid.outcomes[0].succeeded)

        // Automatically named roots rejected by the UI must fail before any
        // local parent is opened or remote attribute/transfer request is issued.
        let invalidRootClient = FixtureTransfers()
        invalidRootClient.add("/valid-root")
        let badRawPath = Data("/bad-".utf8) + Data([255])
        let invalidRoot = TransferItem(remotePath: badRawPath,
            localURL: downloadArea.appendingPathComponent("missing-parent/lossy-name"),
            isDirectory: false, validationError: .invalidName)
        let validRoot = item("/valid-root", downloadArea.appendingPathComponent("valid-root"))
        let validated = await TransferCoordinator(client: invalidRootClient).run([invalidRoot, validRoot], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(validated.failures.count == 1 && validated.completedFiles == 1)
        if case .invalidName = validated.failures[0].error as? TransferIssue {} else { preconditionFailure("Expected validation before local access") }
        precondition(invalidRootClient.attributeRequests == [validRoot.remotePath])
        precondition(validated.outcomes.count == 2 && !validated.outcomes[0].succeeded && validated.outcomes[1].succeeded)
        precondition(!FileManager.default.fileExists(atPath: invalidRoot.localURL.deletingLastPathComponent().path))

        // A complete server error continues the queue; transport loss stops every remaining root.
        let errorsArea = try folder("errors")
        let errors = FixtureTransfers()
        errors.add("/bad"); errors.add("/good")
        errors.failingPaths.insert(Data("/bad".utf8))
        let roots = [item("/bad", errorsArea.appendingPathComponent("bad")), item("/good", errorsArea.appendingPathComponent("good"))]
        let recoverable = await TransferCoordinator(client: errors).run(roots, direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(recoverable.completedFiles == 1 && recoverable.failures.count == 1 && !recoverable.connectionLost)
        errors.operations.removeAll(); errors.disconnectOnFailure = true
        let lost = await TransferCoordinator(client: errors).run(roots, direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(lost.connectionLost && lost.completedFiles == 0 && errors.operations.count == 1)
        precondition(lost.outcomes.count == 2 && lost.outcomes.allSatisfy { !$0.succeeded })

        // Cancel preserves completed files, abandons the remaining roots, and emits each outcome.
        let cancelArea = try folder("cancel")
        let cancelClient = FixtureTransfers()
        cancelClient.add("/one"); cancelClient.add("/two"); cancelClient.add("/three")
        let signal = SFTPCancellation()
        let cancelRoots = ["one", "two", "three"].map { item("/" + $0, cancelArea.appendingPathComponent($0)) }
        let cancelled = await TransferCoordinator(client: cancelClient).run(cancelRoots, direction: .download, cancellation: signal, conflict: regularConflict, didDownload: { _, _ in signal.cancel() })
        precondition(cancelled.completedFiles == 1 && cancelled.cancelled && cancelled.outcomes.count == 3)
        precondition(cancelled.outcomes[0].succeeded && !cancelled.outcomes[1].succeeded)
        precondition(FileManager.default.fileExists(atPath: cancelRoots[0].localURL.path))
        precondition(!FileManager.default.fileExists(atPath: cancelRoots[1].localURL.path))
        // Cancelling a collision leaves the existing file intact and suppresses later roots.
        let conflictCancel = await TransferCoordinator(client: cancelClient).run(cancelRoots, direction: .download, cancellation: SFTPCancellation(), conflict: { _ in .cancel })
        precondition(conflictCancel.cancelled && conflictCancel.completedFiles == 0)
        precondition(conflictCancel.outcomes.count == 3 && conflictCancel.outcomes.allSatisfy { !$0.succeeded })
        precondition(!FileManager.default.fileExists(atPath: cancelRoots[1].localURL.path))
        // A hostile or cyclic server tree stops at the depth bound and does not
        // prevent another selected root from completing.
        let deepArea = try folder("depth")
        let deepSource = FixtureTransfers()
        var deepPath = "/deep"
        deepSource.add(deepPath, mode: 0o40700)
        for _ in 0..<130 {
            deepPath += "/d"
            deepSource.add(deepPath, mode: 0o40700)
        }
        deepSource.add("/after-depth")
        let deep = await TransferCoordinator(client: deepSource).run([item("/deep", deepArea.appendingPathComponent("deep"), directory: true), item("/after-depth", deepArea.appendingPathComponent("after-depth"))], direction: .download, cancellation: SFTPCancellation(), conflict: regularConflict)
        precondition(deep.failures.count == 1 && deep.failures[0].error is TransferIssue)
        if case .nestingLimit = deep.failures[0].error as? TransferIssue {} else { preconditionFailure("Expected bounded-depth error") }
        precondition(deep.completedFiles == 1 && !deep.outcomes[0].succeeded && deep.outcomes[1].succeeded)

        // An event on the main actor can cancel while local enumeration runs off
        // the main actor; no enumerated children may start after cancellation.
        let enumerationArea = try folder("enumeration")
        for index in 0..<300 {
            try Data("file".utf8).write(to: enumerationArea.appendingPathComponent("file-\(index)"))
        }
        let enumerationSignal = SFTPCancellation()
        let enumerationRemote = FixtureTransfers()
        var scheduledCancellation = false
        let enumerated = await TransferCoordinator(client: enumerationRemote).run([item("/enumeration", enumerationArea, directory: true)], direction: .upload, cancellation: enumerationSignal, conflict: regularConflict, progress: { _ in
            guard !scheduledCancellation else { return }
            scheduledCancellation = true
            Task { @MainActor in enumerationSignal.cancel() }
        })
        precondition(enumerated.cancelled && enumerated.completedFiles == 0)
        precondition(enumerationRemote.operations.allSatisfy { !$0.hasPrefix("upload ") })
        print("PASS: sequential recursive transfers, root deduplication, merge/replace/skip, symlink rejection, history callbacks, recoverable failures, transport loss, cancellation and bounded traversal")
    }
}
