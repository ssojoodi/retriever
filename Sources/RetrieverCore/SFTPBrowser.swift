import Foundation
import Dispatch

/// Every access to the flag is locked; cancellation never touches session/file handles.
public final class SFTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
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

public actor SFTPBrowser {
    private nonisolated let executor = SFTPExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var session: SFTPSession?
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

    @discardableResult
    public func download(_ path: Data, to destination: URL, policy: DownloadDestinationPolicy = .exclusive, maximumBytes: UInt64? = nil, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }) throws -> UInt64 {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do {
            var lastUpdate: TimeInterval = 0
            var received: UInt64 = 0
            let total = try session.download(path, to: destination, policy: policy, maximumBytes: maximumBytes) { bytes in
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

    public func disconnect() {
        session?.disconnect()
        session = nil
    }
}
