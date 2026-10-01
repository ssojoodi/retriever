import Foundation

public enum SFTPError: LocalizedError, Equatable {
    case malformedPacket
    case unsupportedVersion(UInt32)
    case disconnected
    case timedOut
    case transport(String)
    case server(UInt32, String)
    case previewLimitExceeded
    case invalidDestination
    case destinationExists

    public var errorDescription: String? {
        switch self {
        case .malformedPacket: "The server sent an invalid SFTP response."
        case .unsupportedVersion(let version): "The server uses unsupported SFTP version \(version)."
        case .transport(let message): "SSH connection failed: \(message)"
        case .timedOut: "The server stopped responding. Connect again to retry."
        case .disconnected: "The SFTP connection closed. Check the server, SSH key and known-host settings."
        case .server(_, let message): message.isEmpty ? "The server could not complete the request." : message
        case .previewLimitExceeded: "This file is larger than 1 MB. Confirm before downloading it for preview."
        case .invalidDestination: "Choose a regular file destination, not a folder or symbolic link."
        case .destinationExists: "A file already exists at the download destination. Choose a different name."
        }
    }
}

struct SFTPWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func uint64(_ value: UInt64) {
        uint32(UInt32(truncatingIfNeeded: value >> 32))
        uint32(UInt32(truncatingIfNeeded: value))
    }
    mutating func bytes(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    func framed() -> Data {
        var result = SFTPWriter()
        result.bytes(data)
        return result.data
    }
}

struct SFTPReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SFTPError.malformedPacket }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1).first! }
    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        let low = try uint32()
        return UInt64(high) << 32 | UInt64(low)
    }
    mutating func bytes() throws -> Data { try take(Int(uint32())) }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw SFTPError.malformedPacket }
        return value
    }
    mutating func attributes() throws -> RemoteAttributes {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000F) == 0 else { throw SFTPError.malformedPacket }
        let size = flags & 1 != 0 ? try uint64() : nil
        if flags & 2 != 0 { _ = try take(8) }
        let permissions = flags & 4 != 0 ? try uint32() : nil
        var modified: Date?
        if flags & 8 != 0 {
            _ = try uint32()
            modified = Date(timeIntervalSince1970: TimeInterval(try uint32()))
        }
        if flags & 0x80000000 != 0 {
            let count = try uint32()
            guard count <= remaining / 8 else { throw SFTPError.malformedPacket }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return RemoteAttributes(size: size, permissions: permissions, modified: modified)
    }
}

public struct RemoteAttributes: Equatable, Sendable {
    public let size: UInt64?
    public let permissions: UInt32?
    public let modified: Date?
    public var isDirectory: Bool { permissions.map { $0 & 0xF000 == 0x4000 } ?? false }
    public var isSymbolicLink: Bool { permissions.map { $0 & 0xF000 == 0xA000 } ?? false }
}

public struct RemoteEntry: Equatable, Sendable {
    // Keep bytes for protocol operations, even when a filename is not valid UTF-8.
    public let nameBytes: Data
    public let attributes: RemoteAttributes
    public var name: String { String(decoding: nameBytes, as: UTF8.self) }
}
