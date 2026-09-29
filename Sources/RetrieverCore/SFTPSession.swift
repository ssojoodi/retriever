import Foundation
import Darwin

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
    private var connected = false
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
            while response.remaining > 0 { _ = try response.bytes(); _ = try response.bytes() }
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
        defer { try? closeHandle(handle) }
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

    /// Writes a sibling temporary file, then publishes without replacing an existing destination.
    /// Failed reads leave the destination untouched and remove the temporary file.
    public func download(_ path: Data, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SFTPError.destinationExists }
        var payload = SFTPWriter()
        payload.bytes(path)
        payload.uint32(1) // SSH_FXF_READ
        payload.uint32(0) // no requested attributes
        var response = try request(3, payload: payload, expecting: 102)
        let handle = try response.bytes()
        defer { try? closeHandle(handle) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".retriever-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var offset: UInt64 = 0
        while true {
            var read = SFTPWriter()
            read.bytes(handle)
            read.uint64(offset)
            read.uint32(32768)
            do { response = try request(5, payload: read, expecting: 103) }
            catch SFTPError.server(1, _) { break }
            let bytes = try response.bytes()
            guard !bytes.isEmpty, bytes.count <= 32768, response.remaining == 0 else { throw SFTPError.malformedPacket }
            try file.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        try cancellation.check()
        try file.synchronize()
        try file.close()
        // link creates the destination atomically and fails if it already exists.
        try FileManager.default.linkItem(at: temporary, to: destination)
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
            if code != 0 { throw SFTPError.server(code, message) }
            guard expecting == 101 else { throw SFTPError.malformedPacket }
            return response
        }
        guard responseType == expecting else { throw SFTPError.malformedPacket }
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
