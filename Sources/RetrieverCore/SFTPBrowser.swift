import Foundation
import Dispatch

/// Every access to the flag is locked; cancellation never touches session/file handles.
public final class SFTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
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

    public func connect(_ settings: ConnectionSettings, cancellation: SFTPCancellation) throws -> RemoteDirectory {
        disconnect()
        do {
            let connection = try makeSession(settings, cancellation)
            session = connection
            return try directory(initialPath, cancellation: cancellation)
        } catch {
            disconnect()
            throw error
        }
    }

    public func directory(_ path: Data, cancellation: SFTPCancellation) throws -> RemoteDirectory {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do {
            let canonical = try session.canonicalPath(path)
            return RemoteDirectory(path: canonical, entries: try session.listDirectory(canonical))
        } catch {
            // A failed or cancelled response can leave the stream out of alignment.
            disconnect()
            throw error
        }
    }

    public func download(_ path: Data, to destination: URL, cancellation: SFTPCancellation, progress: @Sendable (UInt64) -> Void = { _ in }) throws {
        guard let session else { throw SFTPError.disconnected }
        session.cancellation = cancellation
        do {
            var lastUpdate: TimeInterval = 0
            var received: UInt64 = 0
            try session.download(path, to: destination) { bytes in
                received = bytes
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 {
                    progress(bytes)
                    lastUpdate = now
                }
            }
            progress(received)
        }
        catch { disconnect(); throw error }
    }

    public func disconnect() {
        session?.disconnect()
        session = nil
    }
}
