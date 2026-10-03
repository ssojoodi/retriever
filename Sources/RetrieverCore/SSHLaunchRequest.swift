import Foundation

/// An independent interactive SSH session, never the SFTP subsystem stream.
public struct SSHLaunchRequest: Sendable {
    public let folder: String
    public let title: String
    public let arguments: [String]

    public init(settings: ConnectionSettings, path: Data, isDirectory: Bool) throws {
        guard let selected = String(data: path, encoding: .utf8), selected.hasPrefix("/"),
              !selected.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LaunchError.unsupportedPath
        }
        let target: String
        if isDirectory { target = selected }
        else {
            guard let slash = selected.lastIndex(of: "/") else { throw LaunchError.unsupportedPath }
            target = slash == selected.startIndex ? "/" : String(selected[..<slash])
        }
        guard ![settings.host, settings.username].contains(where: { value in
            value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }) else { throw LaunchError.unsupportedPath }
        folder = target
        title = "\(settings.username)@\(settings.host) — \(target)"
        // SSH joins remote arguments into a shell command. Quote only the literal
        // path; the controlled command never opens a shell if changing folder fails.
        let command = "cd " + Self.quote(target) + " && exec \"${SHELL:-/bin/sh}\" -i"
        arguments = ["-tt", "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask",
                     "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                     "-o", "RemoteCommand=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                     "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                     "-p", String(settings.port), "-l", settings.username, settings.host, command]
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func environment(_ original: [String: String]) -> [String] {
        var result = original
        for name in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "RETRIEVER_ASKPASS"] { result.removeValue(forKey: name) }
        result["TERM"] = "xterm-256color"
        return result.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    public enum LaunchError: LocalizedError {
        case unsupportedPath
        public var errorDescription: String? { "This SSH prototype requires an absolute UTF-8 folder path without control characters." }
    }
}
