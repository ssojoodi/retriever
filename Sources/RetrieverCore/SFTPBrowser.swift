import Foundation
import Dispatch
import Darwin

public struct DownloadCheckpoint: Codable, Sendable {
    let temporary: String
    let device: dev_t
    let inode: ino_t
    let size: UInt64?
    let modified: Date?
    var digest: Data
}

public struct TransferRecovery: Codable, Sendable, Identifiable {
    public let id: UUID
    public let settings: ConnectionSettings
    public let local: URL
    public let remote: Data
    public var bytes: UInt64
    public var paused: Bool
    var upload: UploadCheckpoint?
    var download: DownloadCheckpoint?
    public var isUpload: Bool { upload != nil }
}

public struct TransferJournal: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    func save(_ record: TransferRecovery) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.id.uuidString), options: .atomic)
    }
    public func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }
    public func records() -> [TransferRecovery] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(TransferRecovery.self, from: data),
                  file.lastPathComponent == record.id.uuidString else { return nil }
            return record
        }.sorted { $0.local.path < $1.local.path }
    }
}

public struct TransferPaused: LocalizedError {
    public var errorDescription: String? { "Transfer paused. Resume it in Transfers." }
}

/// Every access to the flag is locked; cancellation never touches session/file handles.
public final class SFTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pausable = false
    private var paused = false
    public var canPause: Bool { lock.withLock { pausable && !paused && !cancelled } }
    public func pause() { lock.withLock { if pausable { paused = true } } }
    func boundary(finishing: Bool = false) throws {
        try lock.withLock {
            if paused { throw TransferPaused() }
            pausable = !finishing
        }
    }
    func endFile() { lock.withLock { pausable = false } }
    // Configured by the owner before submitting work to the serial worker.
    typealias RecoveryContext = (journal: TransferJournal, settings: ConnectionSettings, record: TransferRecovery?)
    private var context: RecoveryContext?
    var recovery: RecoveryContext? { lock.withLock { context } }
    public func enableRecovery(_ journal: TransferJournal, settings: ConnectionSettings, resuming: TransferRecovery? = nil) {
        lock.withLock { context = (journal, settings, resuming) }
    }
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

private final class SFTPExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "ca.sahand.Retriever.sftp", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

public struct RemoteDirectory: Sendable {
    public let path: Data
    public let entries: [RemoteEntry]
    public let usedHomeFallback: Bool
    init(path: Data, entries: [RemoteEntry], usedHomeFallback: Bool = false) {
        self.path = path
        self.entries = entries
        self.usedHomeFallback = usedHomeFallback
    }
}

/// Resume data is held only in memory; it never contains credentials.
public struct InterruptedUpload: LocalizedError, Sendable {
    public let settings: ConnectionSettings
    public let source: URL
    public var destination: Data { checkpoint.destination }
    let checkpoint: UploadCheckpoint
    let message: String
    public var errorDescription: String? { message }
}

public actor SFTPBrowser {
    private nonisolated let executor = SFTPExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var session: SFTPSession?
    private var sessionSettings: ConnectionSettings?
    private let makeSession: @Sendable (ConnectionSettings, SFTPCancellation) throws -> SFTPSession
    private let initialPath: Data
    public init(askpass: URL? = nil) {
        initialPath = Data(".".utf8)
        makeSession = { settings, cancellation in
            try SFTPSession(settings: settings, cancellation: cancellation, askpass: askpass)
        }
    }

    // Available to @testable integration runners; production keeps standard SSH setup.
    init(initialPath: Data, makeSession: @escaping @Sendable (ConnectionSettings, SFTPCancellation) throws -> SFTPSession) {
        self.initialPath = initialPath
        self.makeSession = makeSession
    }

    public func connect(_ settings: ConnectionSettings, startingAt path: Data? = nil, cancellation: SFTPCancellation) throws -> RemoteDirectory {
        disconnect()
        do {
            let connection = try makeSession(settings, cancellation)
            session = connection
            sessionSettings = settings
            if let path, !path.isEmpty {
                do {
                    let canonical = try connection.canonicalPath(path)
                    return RemoteDirectory(path: canonical, entries: try connection.listDirectory(canonical))
                } catch SFTPError.server(let code, _) where [2, 3, 4].contains(code) {
                    // A complete SFTP status response leaves the stream aligned.
                    // Missing/inaccessible/non-directory locations may fall back;
                    // transport, authentication and cancellation errors must surface.
                    try cancellation.check()
                    let canonical = try connection.canonicalPath(initialPath)
                    return RemoteDirectory(path: canonical, entries: try connection.listDirectory(canonical), usedHomeFallback: true)
                }
            }
            return try directory(initialPath, cancellation: cancellation)
        } catch {
            disconnect()
            throw error
        }
    }

    public var isConnected: Bool { session?.isUsable == true }

    private func handleFailure(_ error: Error) {
        session?.handleFailure(error)
        if session?.isUsable != true { disconnect() }
    }

    public func directory(_ path: Data, cancellation: SFTPCancellation) throws -> RemoteDirectory {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do {
            let canonical = try session.canonicalPath(path)
            return RemoteDirectory(path: canonical, entries: try session.listDirectory(canonical))
        } catch {
            handleFailure(error)
            throw error
        }
    }

    public func attributes(at path: Data, cancellation: SFTPCancellation) throws -> RemoteAttributes? {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do { return try session.attributes(at: path) }
        catch { handleFailure(error); throw error }
    }

    public func createDirectory(at path: Data, cancellation: SFTPCancellation) throws {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do { try session.createDirectory(at: path) }
        catch { handleFailure(error); throw error }
    }

    @discardableResult
    public func download(_ path: Data, to destination: URL, policy: DownloadDestinationPolicy = .exclusive, maximumBytes: UInt64? = nil, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard session != nil else { throw SFTPError.disconnected }
        let directory = try LocalTransferDirectory(url: destination.deletingLastPathComponent())
        return try download(path, to: directory, name: destination.lastPathComponent, policy: policy, maximumBytes: maximumBytes, cancellation: cancellation, progress: progress)
    }

    @discardableResult
    public func download(_ path: Data, to directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy = .exclusive, maximumBytes: UInt64? = nil, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard let session else { throw SFTPError.disconnected }
        if let context = cancellation.recovery {
            guard context.settings == sessionSettings else { throw SFTPError.disconnected }
            if let record = context.record {
                guard !record.isUpload, record.settings == sessionSettings, record.remote == path,
                      record.local == directory.url.appendingPathComponent(name) else { throw SFTPError.downloadResumeMismatch }
            }
        }
        session.cancellation = cancellation
        do {
            var lastUpdate: TimeInterval = 0
            var received: UInt64 = 0
            let total = try session.download(path, to: directory, name: name, policy: policy, maximumBytes: maximumBytes) { bytes in
                received = bytes
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 {
                    progress(bytes)
                    lastUpdate = now
                }
            }
            progress(received)
            return total
        }
        catch { handleFailure(error); throw error }
    }

    @discardableResult
    public func upload(_ source: URL, to path: Data, policy: UploadDestinationPolicy = .exclusive, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }, finishing: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard session != nil else { throw SFTPError.disconnected }
        let directory = try LocalTransferDirectory(url: source.deletingLastPathComponent())
        return try upload(from: directory, name: source.lastPathComponent, to: path, policy: policy, cancellation: cancellation, progress: progress, finishing: finishing)
    }

    @discardableResult
    public func upload(from directory: LocalTransferDirectory, name: String, to path: Data, policy: UploadDestinationPolicy = .exclusive, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }, finishing: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard let session, let settings = sessionSettings else { throw SFTPError.disconnected }
        if let context = cancellation.recovery {
            guard context.settings == settings else { throw SFTPError.disconnected }
            if let record = context.record {
                guard record.isUpload, record.settings == settings, record.remote == path,
                      record.local == directory.url.appendingPathComponent(name) else { throw SFTPError.uploadResumeMismatch }
            }
        }
        session.cancellation = cancellation
        do {
            var lastUpdate: TimeInterval = 0
            let total = try session.upload(from: directory, name: name, to: path, policy: policy, progress: { bytes in
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 { progress(bytes); lastUpdate = now }
            }, finishing: finishing, resuming: cancellation.recovery?.record?.upload, retainForResume: true, verifying: progress)
            progress(total)
            return total
        } catch {
            handleFailure(error)
            if let partial = error as? PartialUploadError {
                throw InterruptedUpload(settings: settings, source: directory.url.appendingPathComponent(name), checkpoint: partial.checkpoint, message: partial.message)
            }
            throw error
        }
    }

    @discardableResult
    public func resumeUpload(_ upload: InterruptedUpload, policy: UploadDestinationPolicy = .exclusive,
                             cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in },
                             verifying: @Sendable (UInt64) -> Void = { _ in }, finishing: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard let session, sessionSettings == upload.settings else { throw SFTPError.uploadResumeUnavailable }
        session.cancellation = cancellation
        let directory = try LocalTransferDirectory(url: upload.source.deletingLastPathComponent())
        do {
            var lastProgress: TimeInterval = 0
            var lastVerification: TimeInterval = 0
            return try session.upload(from: directory, name: upload.source.lastPathComponent, to: upload.destination, policy: policy,
                progress: { bytes in
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.1 { progress(bytes); lastProgress = now }
                }, finishing: finishing, resuming: upload.checkpoint, retainForResume: true, verifying: { bytes in
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastVerification >= 0.1 { verifying(bytes); lastVerification = now }
                })
        } catch {
            handleFailure(error)
            if let partial = error as? PartialUploadError {
                throw InterruptedUpload(settings: upload.settings, source: upload.source, checkpoint: partial.checkpoint, message: partial.message)
            }
            throw error
        }
    }

    public func discard(_ record: TransferRecovery, cancellation: SFTPCancellation) throws {
        if let download = record.download {
            let parent = try LocalTransferDirectory(url: record.local.deletingLastPathComponent())
            guard download.temporary.hasPrefix(".retriever-"), download.temporary.hasSuffix(".partial"),
                  !download.temporary.contains("/") else { throw POSIXError(.EINVAL) }
            var info = stat()
            if fstatat(parent.descriptor, download.temporary, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_dev == download.device,
                  info.st_ino == download.inode else { throw POSIXError(.ESTALE) }
            guard unlinkat(parent.descriptor, download.temporary, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if let upload = record.upload {
            guard let session, sessionSettings == record.settings else { throw SFTPError.disconnected }
            session.cancellation = cancellation
            do { try session.discard(upload, source: record.local) }
            catch { handleFailure(error); throw error }
        }
    }

    public func disconnect() {
        session?.disconnect()
        session = nil
        sessionSettings = nil
    }
}
