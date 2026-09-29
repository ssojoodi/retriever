import Foundation

public struct ConnectionSettings: Equatable, Sendable {
    public let host: String
    public let username: String
    public let port: UInt16

    public init(host: String, username: String, port: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains("/"), !host.contains("@") else { throw ConnectionError.invalidHost }
        guard !username.isEmpty, !username.hasPrefix("-"),
              username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !username.contains("@") else { throw ConnectionError.invalidUsername }
        guard let value = UInt16(port), value > 0 else { throw ConnectionError.invalidPort }
        self.host = host
        self.username = username
        self.port = value
    }
}

public enum ConnectionError: LocalizedError {
    case invalidHost, invalidUsername, invalidPort
    public var errorDescription: String? {
        switch self {
        case .invalidHost: "Enter a server hostname or IP address, without a URL prefix."
        case .invalidUsername: "Enter a valid username."
        case .invalidPort: "Enter a port between 1 and 65535."
        }
    }
}
