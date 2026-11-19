import Foundation
import Darwin
import CryptoKit

public enum DownloadDestinationPolicy: Sendable {
    case exclusive
    case replaceApproved
}

public enum UploadDestinationPolicy: Sendable {
    case exclusive
    case replaceApproved
}

/// Checkpoint metadata for an upload created by Retriever.
public struct UploadCheckpoint: Codable, Sendable {
    let temporary: Data
    let destination: Data
    let source: UploadSourceIdentity
    var publicationAttempted = false
}

struct UploadSourceIdentity: Codable, Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

struct PartialUploadError: LocalizedError {
    let checkpoint: UploadCheckpoint
    let message: String
    var errorDescription: String? { message }
}

/// A synchronous session. Own and call it on a dedicated serial worker, never the UI thread.
/// SSH owns encryption, authentication and host-key verification.
public final class SFTPSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private var diagnosticBytes = Data()
    private var diagnosticsOpen = false
    private var requestID: UInt32 = 0
    private var supportsAtomicReplacement = false
    private var connected = false
    private var exchangeInFlight = false
    private var cleanupDeadline: TimeInterval?
    private var finalizationDeadline: TimeInterval?
    public var isUsable: Bool { connected && !exchangeInFlight }
    var cancellation: SFTPCancellation
    private let idleTimeout: TimeInterval
    private let authenticationTimeout: TimeInterval
    private var negotiating = true
    private var responseTimeout: TimeInterval { negotiating ? authenticationTimeout : idleTimeout }
    private static let maximumPacket = 4 * 1024 * 1024

    public convenience init(settings: ConnectionSettings, cancellation: SFTPCancellation = SFTPCancellation(), askpass: URL? = nil) throws {
        let environment = askpass.map(Self.askpassEnvironment)
        try self.init(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: Self.sshArguments(settings, interactive: askpass != nil), cancellation: cancellation, authenticationTimeout: askpass == nil ? 30 : 300, environment: environment)
    }

    static func askpassEnvironment(_ executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = executable.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["RETRIEVER_ASKPASS"] = "1"
        environment["LC_ALL"] = "C"
        return environment
    }

    static func sshArguments(_ settings: ConnectionSettings, interactive: Bool = false) -> [String] {
        [
            "-T", "-o", interactive ? "BatchMode=no" : "BatchMode=yes", "-o", interactive ? "StrictHostKeyChecking=ask" : "StrictHostKeyChecking=yes",
            "-o", "NumberOfPasswordPrompts=3",
            "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2", "-o", "ClearAllForwardings=yes",
            "-p", String(settings.port), "-l", settings.username, "-s", settings.host, "sftp"
        ]
    }

    // Internal injection permits real protocol integration tests without SSH credentials.
    init(executable: URL, arguments: [String], cancellation: SFTPCancellation = SFTPCancellation(), idleTimeout: TimeInterval = 30, authenticationTimeout: TimeInterval? = nil, environment: [String: String]? = nil) throws {
        self.cancellation = cancellation
        self.idleTimeout = idleTimeout
        self.authenticationTimeout = authenticationTimeout ?? idleTimeout
        try cancellation.check()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        // The parent must not retain the child's pipe ends, or EOF cannot arrive.
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        diagnosticsOpen = true
        do {
            guard fcntl(diagnostics.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else { throw SFTPError.disconnected }
            let descriptor = input.fileHandleForWriting.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1,
                  fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { throw SFTPError.disconnected }
            var initialization = SFTPWriter()
            initialization.byte(1)
            initialization.uint32(3)
            try send(initialization)
            var response = try receive()
            guard try response.byte() == 2 else { throw SFTPError.malformedPacket }
            let version = try response.uint32()
            guard version == 3 else { throw SFTPError.unsupportedVersion(version) }
            while response.remaining > 0 {
                let name = try response.bytes()
                let version = try response.bytes()
                if name == Data("posix-rename@openssh.com".utf8), version == Data("1".utf8) {
                    supportsAtomicReplacement = true
                }
            }
            connected = true
            negotiating = false
        } catch {
            disconnect()
            throw error
        }
    }

    deinit { disconnect() }

    public func disconnect() {
        connected = false
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if diagnosticsOpen {
            try? diagnostics.fileHandleForReading.close()
            diagnosticsOpen = false
        }
        if process.isRunning { process.terminate() }
    }

    public func canonicalPath(_ path: Data) throws -> Data {
        var payload = SFTPWriter()
        payload.bytes(path)
        var response = try request(16, payload: payload, expecting: 104)
        guard try response.uint32() == 1 else { throw SFTPError.malformedPacket }
        let canonical = try response.bytes()
        _ = try response.bytes()
        _ = try response.attributes()
        guard response.remaining == 0 else { throw SFTPError.malformedPacket }
        return canonical
    }

    public func listDirectory(_ path: Data) throws -> [RemoteEntry] {
        var payload = SFTPWriter()
        payload.bytes(path)
        var response = try request(11, payload: payload, expecting: 102)
        let handle = try response.bytes()
        defer { finishHandle(handle) }
        var entries: [RemoteEntry] = []
        while true {
            var read = SFTPWriter()
            read.bytes(handle)
            do { response = try request(12, payload: read, expecting: 104) }
            catch SFTPError.server(1, _) { break }
            let count = try response.uint32()
            guard count > 0, count <= response.remaining / 12 else { throw SFTPError.malformedPacket }
            for _ in 0..<count {
                let name = try response.bytes()
                _ = try response.bytes() // longname is presentation only, never parsed.
                let attributes = try response.attributes()
                guard !name.isEmpty, !name.contains(0), !name.contains(47) else { throw SFTPError.malformedPacket }
                if name != Data(".".utf8), name != Data("..".utf8) {
                    entries.append(RemoteEntry(nameBytes: name, attributes: attributes))
                }
            }
            guard response.remaining == 0 else { throw SFTPError.malformedPacket }
        }
        return entries.sorted {
            if $0.attributes.isDirectory != $1.attributes.isDirectory { return $0.attributes.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Nil means only SSH_FX_NO_SUCH_FILE; permission and transport errors remain visible.
    public func attributes(at path: Data) throws -> RemoteAttributes? {
        var payload = SFTPWriter()
        payload.bytes(path)
        do {
            var response = try request(7, payload: payload, expecting: 105)
            let attributes = try response.attributes()
            guard response.remaining == 0 else { throw SFTPError.malformedPacket }
            return attributes
        } catch SFTPError.server(2, _) { return nil }
    }

    public func createDirectory(at path: Data) throws {
        var payload = SFTPWriter()
        payload.bytes(path)
        payload.uint32(4)
        payload.uint32(0o700)
        _ = try request(14, payload: payload, expecting: 101)
    }

    /// Writes a sibling temporary file, then atomically publishes under an explicit destination policy.
    /// Recoverable transfers retain the temporary file after pause or transport loss.
    @discardableResult
    public func download(_ path: Data, to destination: URL, policy: DownloadDestinationPolicy = .exclusive, maximumBytes: UInt64? = nil, progress: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        let directory = try LocalTransferDirectory(url: destination.deletingLastPathComponent())
        return try download(path, to: directory, name: destination.lastPathComponent, policy: policy, maximumBytes: maximumBytes, progress: progress)
    }

    @discardableResult
    public func download(_ path: Data, to directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy = .exclusive, maximumBytes: UInt64? = nil, progress: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        try validateDestination(directory, name: name, policy: policy)
        var payload = SFTPWriter()
        payload.bytes(path)
        payload.uint32(1) // SSH_FXF_READ
        payload.uint32(0) // no requested attributes
        var response = try request(3, payload: payload, expecting: 102)
        let handle = try response.bytes()
        defer { finishHandle(handle) }
        let context = cancellation.recovery
        let previous = context?.record?.download
        let temporary = previous?.temporary ?? ".retriever-\(UUID().uuidString).partial"
        guard !temporary.contains("/"), temporary.hasPrefix(".retriever-"), temporary.hasSuffix(".partial") else { throw POSIXError(.EINVAL) }
        let attributes = context == nil ? nil : try handleAttributes(handle)
        if let previous {
            guard let current = try self.attributes(at: path), !current.isSymbolicLink,
                  current.size == previous.size, current.modified == previous.modified else { throw SFTPError.downloadResumeMismatch }
            guard previous.size != nil, previous.modified != nil, attributes?.size == previous.size,
                  attributes?.modified == previous.modified, attributes?.isSymbolicLink == false else { throw SFTPError.downloadResumeMismatch }
        }
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (previous == nil ? O_CREAT | O_EXCL : 0)
        var descriptor = openat(directory.descriptor, temporary, flags, mode_t(0o600))
        var alreadyPublished = false
        if descriptor < 0, errno == ENOENT, previous != nil {
            // The process may have exited between the atomic rename and journal removal.
            descriptor = try directory.openFile(named: name)
            alreadyPublished = true
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var keep = previous != nil
        defer {
            cancellation.endFile()
            if !keep { _ = unlinkat(directory.descriptor, temporary, 0) }
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_nlink == 1 else { throw POSIXError(.EINVAL) }
        var hash = SHA256()
        var record = context.map { _, settings, old in
            old ?? TransferRecovery(id: UUID(), settings: settings, local: directory.url.appendingPathComponent(name), remote: path, bytes: 0, paused: false, download: DownloadCheckpoint(temporary: temporary, device: identity.st_dev, inode: identity.st_ino, size: attributes?.size, modified: attributes?.modified, digest: Data(hash.finalize())))
        }
        var offset: UInt64 = 0
        if let previous, let record {
            guard previous.device == identity.st_dev, previous.inode == identity.st_ino, identity.st_size >= record.bytes else { throw SFTPError.downloadResumeMismatch }
            while offset < record.bytes {
                try cancellation.check()
                try cancellation.boundary()
                guard let data = try file.read(upToCount: Int(min(record.bytes - offset, 262144))), !data.isEmpty else { throw POSIXError(.EIO) }
                hash.update(data: data)
                offset += UInt64(data.count)
                progress(offset)
            }
            guard Data(hash.finalize()) == previous.digest else { throw SFTPError.downloadResumeMismatch }
            if alreadyPublished {
                guard previous.size == offset, identity.st_size == offset else { throw SFTPError.downloadResumeMismatch }
                try context?.journal.remove(record.id)
                return offset
            }
            try file.truncate(atOffset: offset)
        }
        func save(_ paused: Bool) throws {
            guard var current = record, let context else { return }
            try file.synchronize()
            current.download?.digest = Data(hash.finalize())
            current.bytes = offset
            current.paused = paused
            try context.journal.save(current)
            record = current
        }
        try save(false)
        do {
            if context != nil {
                try cancellation.boundary()
                progress(offset)
            }
            while true {
                if context != nil { try cancellation.boundary() }
                var read = SFTPWriter()
                read.bytes(handle)
                read.uint64(offset)
                read.uint32(32768)
                do { response = try request(5, payload: read, expecting: 103) }
                catch SFTPError.server(1, _) { break }
                let bytes = try response.bytes()
                guard !bytes.isEmpty, bytes.count <= 32768, response.remaining == 0 else { throw SFTPError.malformedPacket }
                if let maximumBytes, offset + UInt64(bytes.count) > maximumBytes { throw SFTPError.previewLimitExceeded }
                try file.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                if let record {
                    hash.update(data: bytes)
                    if offset - record.bytes >= 8 * 1024 * 1024 { try save(false) }
                }
                progress(offset)
            }
            if context != nil {
                try cancellation.boundary(finishing: true)
                let final = try handleAttributes(handle)
                guard final.modified == attributes?.modified, final.size == attributes?.size,
                      final.size == nil || final.size == offset else { throw SFTPError.downloadResumeMismatch }
                try save(false)
            }
            try cancellation.check()
            try file.synchronize()
            try file.close()
            try cancellation.check()
            var namedPartial = stat()
            guard fstatat(directory.descriptor, temporary, &namedPartial, AT_SYMLINK_NOFOLLOW) == 0,
                  namedPartial.st_dev == identity.st_dev, namedPartial.st_ino == identity.st_ino,
                  namedPartial.st_size == offset else { throw SFTPError.downloadResumeMismatch }
            try validateDestination(directory, name: name, policy: policy)
            // Keep publication relative to the retained parent, including after a rename.
            let published = renameatx_np(directory.descriptor, temporary, directory.descriptor, name,
                                         policy == .exclusive ? UInt32(RENAME_EXCL) : 0)
            guard published == 0 else {
                if errno == EEXIST { throw SFTPError.destinationExists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            keep = true
            if let record { try context?.journal.remove(record.id) }
            progress(offset)
            return offset
        } catch {
            handleFailure(error)
            if record != nil, error is TransferPaused || (!isUsable && !(error is CancellationError)) {
                keep = true
                try save(error is TransferPaused)
            } else if previous == nil, let record {
                try context?.journal.remove(record.id)
            }
            throw error
        }
    }

    private func validateDestination(_ directory: LocalTransferDirectory, name: String, policy: DownloadDestinationPolicy) throws {
        if let info = try directory.attributes(of: name) {
            guard policy == .replaceApproved else { throw SFTPError.destinationExists }
            guard info.kind == .regularFile else { throw SFTPError.invalidDestination }
        }
    }

    private func uploadTarget(_ path: Data, policy: UploadDestinationPolicy) throws {
        if let attributes = try attributes(at: path) {
            guard attributes.permissions.map({ $0 & 0xF000 == 0x8000 }) == true else { throw SFTPError.invalidUploadFile }
            if policy == .exclusive { throw SFTPError.uploadDestinationExists }
        }
        if policy == .replaceApproved, !supportsAtomicReplacement { throw SFTPError.uploadReplacementUnsupported }
    }

    /// Publish only after all writes and CLOSE succeed. Never unlink the destination.
    @discardableResult
    public func upload(_ source: URL, to path: Data, policy: UploadDestinationPolicy = .exclusive, progress: (UInt64) -> Void = { _ in }, finishing: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        let directory = try LocalTransferDirectory(url: source.deletingLastPathComponent())
        return try upload(from: directory, name: source.lastPathComponent, to: path, policy: policy, progress: progress, finishing: finishing)
    }

    @discardableResult
    public func upload(from directory: LocalTransferDirectory, name: String, to path: Data, policy: UploadDestinationPolicy = .exclusive, progress: (UInt64) -> Void = { _ in }, finishing: (UInt64) -> Void = { _ in }, resuming: UploadCheckpoint? = nil, retainForResume: Bool = false, verifying: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        let descriptor = try directory.openFile(named: name)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw POSIXError(.EIO) }
        guard original.st_mode & S_IFMT == S_IFREG else { throw SFTPError.invalidUploadFile }
        let identity = UploadSourceIdentity(original)
        guard let slash = path.lastIndex(of: 47) else { throw SFTPError.invalidUploadFile }
        if let resuming {
            guard resuming.destination == path, resuming.source == identity else { throw SFTPError.uploadSourceChanged }
        } else {
            try uploadTarget(path, policy: policy)
        }
        let temporary = resuming?.temporary ?? Self.appending(Data(".retriever-\(UUID().uuidString).partial".utf8), to: Data(path.prefix(through: slash)))
        var checkpoint = resuming ?? UploadCheckpoint(temporary: temporary, destination: path, source: identity)
        let context = cancellation.recovery
        var record = context.map { _, settings, previous in
            previous ?? TransferRecovery(id: UUID(), settings: settings, local: directory.url.appendingPathComponent(name), remote: path, bytes: 0, paused: false, upload: checkpoint)
        }
        func save(_ bytes: UInt64, paused: Bool = false) throws {
            guard var current = record, let context else { return }
            current.bytes = bytes
            current.upload = checkpoint
            current.paused = paused
            try context.journal.save(current)
            record = current
        }
        defer { cancellation.endFile() }
        var offset: UInt64 = 0
        var handle: Data?
        var created = false
        var opening = false
        var publishing = false
        do {
            try save(record?.bytes ?? 0)
            if resuming != nil {
                guard let partial = try attributes(at: temporary) else {
                    guard checkpoint.publicationAttempted, let final = try attributes(at: path),
                          final.size == UInt64(original.st_size) else { throw SFTPError.uploadResumeUnavailable }
                    let completedHandle = try openResumeFile(path, attributes: final, writable: false)
                    defer { finishHandle(completedHandle) }
                    try verifyUploadPrefix(completedHandle, file: file, size: UInt64(original.st_size), verifying: verifying)
                    try validateUploadSource(descriptor, identity: identity)
                    if let record { try context?.journal.remove(record.id) }
                    return UInt64(original.st_size)
                }
                guard let size = partial.size, size <= UInt64(original.st_size) else { throw SFTPError.uploadResumeMismatch }
                handle = try openResumeFile(temporary, attributes: partial, writable: true)
                verifying(0)
                try verifyUploadPrefix(handle!, file: file, size: size, verifying: verifying)
                try validateUploadSource(descriptor, identity: identity)
                try uploadTarget(path, policy: policy)
                offset = size
                progress(offset)
            } else {
                var open = SFTPWriter()
                open.bytes(temporary)
                open.uint32(2 | 8 | 32) // WRITE | CREAT | EXCL
                open.uint32(4) // permissions: private until published, and thereafter.
                open.uint32(0o600)
                opening = true
                var response = try request(3, payload: open, expecting: 102)
                created = true
                handle = try response.bytes()
                guard response.remaining == 0 else { throw SFTPError.malformedPacket }
                opening = false
            }
            if context != nil {
                try cancellation.boundary()
                progress(offset)
            }
            while true {
                try cancellation.check()
                if context != nil { try cancellation.boundary() }
                guard let bytes = try file.read(upToCount: 32768), !bytes.isEmpty else { break }
                var write = SFTPWriter()
                write.bytes(handle!)
                write.uint64(offset)
                write.bytes(bytes)
                _ = try request(6, payload: write, expecting: 101)
                offset += UInt64(bytes.count)
                if let record, offset >= record.bytes + 8388608 { try save(offset) }
                progress(offset)
            }
            if context != nil { try cancellation.boundary(finishing: true) }
            var final = stat()
            guard fstat(descriptor, &final) == 0,
                  original.st_size == final.st_size, offset == UInt64(original.st_size),
                  original.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
                  original.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
                  original.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
                  original.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else { throw SFTPError.uploadSourceChanged }
            // Bound the whole CLOSE/check/RENAME sequence, even if replies trickle in.
            finalizationDeadline = ProcessInfo.processInfo.systemUptime + idleTimeout
            defer { finalizationDeadline = nil }
            finishing(offset)
            if resuming != nil, try handleAttributes(handle!).size != offset { throw SFTPError.uploadResumeMismatch }
            // CLOSE invalidates the handle even if the server reports a flush error.
            let closing = handle!
            try cancellation.check()
            handle = nil
            try closeHandle(closing)
            try uploadTarget(path, policy: policy)
            var rename = SFTPWriter()
            if policy == .replaceApproved { rename.string("posix-rename@openssh.com") }
            rename.bytes(temporary)
            rename.bytes(path)
            publishing = true
            checkpoint.publicationAttempted = true
            try save(offset)
            _ = try request(policy == .replaceApproved ? 200 : 18, payload: rename, expecting: 101)
            if let record { try context?.journal.remove(record.id) }
            return offset
        } catch {
            let uncertainPublication = publishing && exchangeInFlight
            let uncertainCreation = opening && exchangeInFlight
            handleFailure(error)
            if let record {
                if error is TransferPaused || (!isUsable && !(error is CancellationError)) {
                    if let handle, isUsable { finishHandle(handle) }
                    try save(max(offset, record.bytes), paused: error is TransferPaused)
                    if uncertainPublication {
                        throw SFTPError.uploadIncomplete("The server may have completed the upload. Resume from Transfers to check the destination.")
                    }
                    throw error
                }
                if resuming == nil { try context?.journal.remove(record.id) }
            }
            // A resumed partial belongs to a prior attempt. Never delete it on
            // verification/conflict failure or cancellation while checking it.
            if resuming != nil, let handle, isUsable { finishHandle(handle) }
            if created, isUsable {
                let originalCancellation = cancellation
                cancellation = SFTPCancellation()
                cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
                defer { cancellation = originalCancellation; cleanupDeadline = nil }
                do {
                    if let handle { try closeHandle(handle) }
                    var remove = SFTPWriter()
                    remove.bytes(temporary)
                    _ = try request(13, payload: remove, expecting: 101)
                    created = false
                } catch { handleFailure(error) }
            }
            if created || uncertainCreation {
                let outcome = uncertainPublication ? "The server may have completed the upload. Check the destination before retrying." : "The upload did not complete."
                let message = "\(error.localizedDescription)\n\n\(outcome) A temporary file may remain at:\n\(String(decoding: temporary, as: UTF8.self))"
                if retainForResume, !isUsable, !opening, !(error is CancellationError) {
                    throw PartialUploadError(checkpoint: checkpoint, message: message)
                }
                throw SFTPError.uploadIncomplete(message)
            }
            if resuming != nil, !isUsable, !(error is CancellationError) {
                throw PartialUploadError(checkpoint: checkpoint, message: error.localizedDescription)
            }
            throw error
        }
    }

    func discard(_ checkpoint: UploadCheckpoint, source: URL) throws {
        let path = checkpoint.temporary
        guard let slash = path.lastIndex(of: 47), let end = checkpoint.destination.lastIndex(of: 47),
              path.prefix(through: slash) == checkpoint.destination.prefix(through: end),
              String(decoding: path.suffix(from: slash + 1), as: UTF8.self).hasPrefix(".retriever-"),
              path != checkpoint.destination else { throw SFTPError.uploadResumeMismatch }
        guard let attributes = try attributes(at: path) else { return }
        let directory = try LocalTransferDirectory(url: source.deletingLastPathComponent())
        let fd = try directory.openFile(named: source.lastPathComponent)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try validateUploadSource(fd, identity: checkpoint.source)
        let handle = try openResumeFile(path, attributes: attributes, writable: false)
        defer { finishHandle(handle) }
        guard let size = attributes.size, size <= UInt64(checkpoint.source.size) else { throw SFTPError.uploadResumeMismatch }
        try verifyUploadPrefix(handle, file: file, size: size, verifying: { _ in })
        guard try self.attributes(at: path) == attributes else { throw SFTPError.uploadResumeMismatch }
        var remove = SFTPWriter()
        remove.bytes(path)
        _ = try request(13, payload: remove, expecting: 101)
    }

    private func validateUploadSource(_ descriptor: Int32, identity: UploadSourceIdentity) throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0, UploadSourceIdentity(current) == identity else { throw SFTPError.uploadSourceChanged }
    }

    private func handleAttributes(_ handle: Data) throws -> RemoteAttributes {
        var payload = SFTPWriter()
        payload.bytes(handle)
        var response = try request(8, payload: payload, expecting: 105)
        let attributes = try response.attributes()
        guard response.remaining == 0 else { throw SFTPError.malformedPacket }
        return attributes
    }

    private func openResumeFile(_ path: Data, attributes: RemoteAttributes, writable: Bool) throws -> Data {
        guard attributes.permissions.map({ $0 & 0xF000 == 0x8000 }) == true else { throw SFTPError.uploadResumeMismatch }
        var open = SFTPWriter()
        open.bytes(path)
        open.uint32(writable ? 3 : 1) // READ (+ WRITE); never CREATE or TRUNCATE.
        open.uint32(0)
        var response = try request(3, payload: open, expecting: 102)
        let handle = try response.bytes()
        do {
            guard response.remaining == 0 else { throw SFTPError.malformedPacket }
            let actual = try handleAttributes(handle)
            guard actual.permissions.map({ $0 & 0xF000 == 0x8000 }) == true,
                  actual.size == attributes.size else { throw SFTPError.uploadResumeMismatch }
            return handle
        } catch { finishHandle(handle); throw error }
    }

    private func verifyUploadPrefix(_ handle: Data, file: FileHandle, size: UInt64, verifying: (UInt64) -> Void) throws {
        let before = try handleAttributes(handle)
        guard before.size == size else { throw SFTPError.uploadResumeMismatch }
        try file.seek(toOffset: 0)
        var offset: UInt64 = 0
        while offset < size {
            if cancellation.recovery != nil { try cancellation.boundary() }
            try cancellation.check()
            var read = SFTPWriter()
            read.bytes(handle); read.uint64(offset)
            let count = UInt32(min(32768, size - offset))
            read.uint32(count)
            var response = try request(5, payload: read, expecting: 103)
            let remote = try response.bytes()
            guard !remote.isEmpty, remote.count <= count, response.remaining == 0 else { throw SFTPError.malformedPacket }
            guard try file.read(upToCount: remote.count) == remote else { throw SFTPError.uploadResumeMismatch }
            offset += UInt64(remote.count)
            verifying(offset)
        }
        guard try handleAttributes(handle) == before else { throw SFTPError.uploadResumeMismatch }
    }

    // Cancellation before a new exchange can preserve the stream. Never send a
    // CLOSE into a partially received response; cleanup has an absolute deadline.
    private func finishHandle(_ handle: Data) {
        guard isUsable else { disconnect(); return }
        let original = cancellation
        cancellation = SFTPCancellation()
        cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
        defer { cancellation = original; cleanupDeadline = nil }
        do { try closeHandle(handle) } catch { disconnect() }
    }

    func handleFailure(_ error: Error) {
        if let error = error as? SFTPError {
            switch error {
            case .malformedPacket, .unsupportedVersion, .disconnected, .timedOut, .transport:
                disconnect()
            case .server(let code, _) where code == 6 || code == 7: disconnect()
            default: break
            }
        }
        if exchangeInFlight { disconnect() }
    }

    public static func appending(_ name: Data, to directory: Data) -> Data {
        var result = directory
        if result.last != 47 { result.append(47) }
        result.append(name)
        return result
    }

    private func closeHandle(_ handle: Data) throws {
        var payload = SFTPWriter()
        payload.bytes(handle)
        _ = try request(4, payload: payload, expecting: 101)
    }

    private func request(_ type: UInt8, payload: SFTPWriter, expecting: UInt8) throws -> SFTPReader {
        guard connected else { throw SFTPError.disconnected }
        try cancellation.check()
        exchangeInFlight = true
        requestID &+= 1
        var packet = SFTPWriter()
        packet.byte(type)
        packet.uint32(requestID)
        packet.data.append(payload.data)
        try send(packet)
        var response = try receive()
        let responseType = try response.byte()
        guard try response.uint32() == requestID else { throw SFTPError.malformedPacket }
        if responseType == 101 {
            let code = try response.uint32()
            let message = String(decoding: try response.bytes(), as: UTF8.self)
            _ = try response.bytes()
            guard response.remaining == 0 else { throw SFTPError.malformedPacket }
            exchangeInFlight = false
            if code != 0 { throw SFTPError.server(code, message) }
            guard expecting == 101 else { throw SFTPError.malformedPacket }
            return response
        }
        guard responseType == expecting else { throw SFTPError.malformedPacket }
        exchangeInFlight = false
        return response
    }

    private func drainDiagnostics() {
        guard diagnosticsOpen else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Limit each pass even if a process continuously writes stderr.
        for _ in 0..<16 {
            let count = Darwin.read(diagnostics.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            let remaining = 16384 - diagnosticBytes.count
            if remaining > 0 { diagnosticBytes.append(contentsOf: buffer.prefix(min(count, remaining))) }
        }
    }

    private func connectionFailure() -> SFTPError {
        drainDiagnostics()
        let message = String(decoding: diagnosticBytes, as: UTF8.self)
        let filtered = String(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? .disconnected : .transport(filtered)
    }

    private func send(_ packet: SFTPWriter) throws {
        let bytes = packet.framed()
        let descriptor = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        var lastWrite = ProcessInfo.processInfo.systemUptime
        while offset < bytes.count {
            try cancellation.check()
            if let cleanupDeadline, ProcessInfo.processInfo.systemUptime >= cleanupDeadline { throw SFTPError.timedOut }
            if let finalizationDeadline, ProcessInfo.processInfo.systemUptime >= finalizationDeadline { throw SFTPError.timedOut }
            drainDiagnostics()
            guard ProcessInfo.processInfo.systemUptime - lastWrite < responseTimeout else { throw SFTPError.timedOut }
            var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&state, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw connectionFailure()
            }
            if ready == 0 { continue }
            guard state.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw connectionFailure() }
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(bytes.count - offset, 32768))
            }
            if written < 0, errno == EAGAIN || errno == EINTR { continue }
            guard written > 0 else { throw connectionFailure() }
            offset += written
            lastWrite = ProcessInfo.processInfo.systemUptime
        }
    }

    private func receive() throws -> SFTPReader {
        var header = SFTPReader(try readExactly(4))
        let length = Int(try header.uint32())
        guard length > 0, length <= Self.maximumPacket else { throw SFTPError.malformedPacket }
        return SFTPReader(try readExactly(length))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        var lastRead = ProcessInfo.processInfo.systemUptime
        let descriptor = output.fileHandleForReading.fileDescriptor
        while result.count < count {
            try cancellation.check()
            if let cleanupDeadline, ProcessInfo.processInfo.systemUptime >= cleanupDeadline { throw SFTPError.timedOut }
            if let finalizationDeadline, ProcessInfo.processInfo.systemUptime >= finalizationDeadline { throw SFTPError.timedOut }
            drainDiagnostics()
            guard ProcessInfo.processInfo.systemUptime - lastRead < responseTimeout else { throw SFTPError.timedOut }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorState, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw connectionFailure()
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: min(count - result.count, 65536))
            let received = Darwin.read(descriptor, &buffer, buffer.count)
            guard received > 0 else { throw connectionFailure() }
            result.append(contentsOf: buffer.prefix(received))
            lastRead = ProcessInfo.processInfo.systemUptime
        }
        return result
    }
}
