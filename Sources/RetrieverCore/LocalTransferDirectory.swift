import Foundation
import Darwin

public struct LocalTransferEntry: Sendable {
    public enum Kind: Sendable { case regularFile, directory, symbolicLink, other }
    public let name: String
    public let kind: Kind
    public let byteCount: UInt64
}

/// Retains the directory being transferred, so replacing a path with a symlink
/// cannot redirect subsequent file creation or publication outside that directory.
public final class LocalTransferDirectory: @unchecked Sendable {
    public let url: URL
    let descriptor: Int32

    public convenience init(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var path = url.path
        // These fixed macOS filesystem aliases are not user-controlled traversal.
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        do {
            for component in path.split(separator: "/").map(String.init) {
                try Self.validate(component)
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.error() }
                Darwin.close(fd)
                fd = next
            }
        } catch { Darwin.close(fd); throw error }
        self.init(url: URL(fileURLWithPath: path, isDirectory: true), descriptor: fd)
    }

    private init(url: URL, descriptor: Int32) { self.url = url; self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    public func attributes(of name: String) throws -> LocalTransferEntry? {
        try Self.validate(name)
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.error()
        }
        let kind: LocalTransferEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return LocalTransferEntry(name: name, kind: kind, byteCount: UInt64(max(0, info.st_size)))
    }

    public func entries(cancellation: SFTPCancellation? = nil) throws -> [LocalTransferEntry] {
        try cancellation?.check()
        // openat gives an independent enumeration offset, unlike dup.
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw Self.error() }
        defer { closedir(stream) }
        var result: [LocalTransferEntry] = []
        while true {
            try cancellation?.check()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.error() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            if name == "." || name == ".." { continue }
            if let info = try attributes(of: name) { result.append(info) }
        }
        return result.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    public func openDirectory(named name: String) throws -> LocalTransferDirectory {
        try Self.validate(name)
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        return LocalTransferDirectory(url: url.appendingPathComponent(name, isDirectory: true), descriptor: fd)
    }

    public func createDirectory(named name: String) throws -> LocalTransferDirectory {
        try Self.validate(name)
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw Self.error() }
        return try openDirectory(named: name)
    }

    func openFile(named name: String) throws -> Int32 {
        try Self.validate(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        return fd
    }
}
