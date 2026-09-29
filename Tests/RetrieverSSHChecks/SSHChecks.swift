import Foundation
@testable import RetrieverCore

@main
struct SSHChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = try ConnectionSettings(host: "127.0.0.1", username: CommandLine.arguments[3], port: CommandLine.arguments[2])
        func connect(hosts: String = "known_hosts", key: String = "client_key") throws -> SFTPSession {
            let options = ["-F", "/dev/null", "-i", root.appendingPathComponent(key).path,
                           "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                           "-o", "GlobalKnownHostsFile=/dev/null",
                           "-o", "UserKnownHostsFile=\(root.appendingPathComponent(hosts).path)"]
            return try SFTPSession(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: options + SFTPSession.sshArguments(settings))
        }
        let session = try connect()
        defer { session.disconnect() }
        let path = try session.canonicalPath(Data(root.appendingPathComponent("files").path.utf8))
        let listing = try session.listDirectory(path)
        precondition(listing.contains { $0.name == "payload.bin" })
        let destination = root.appendingPathComponent("download.bin")
        try session.download(SFTPSession.appending(Data("payload.bin".utf8), to: path), to: destination)
        let expected = try Data(contentsOf: root.appendingPathComponent("files/payload.bin"))
        let downloaded = try Data(contentsOf: destination)
        precondition(expected == downloaded, "Authenticated download bytes differ")
        for (hosts, key, expectedMessage) in [
            ("empty_hosts", "client_key", "Host key verification failed"),
            ("changed_hosts", "client_key", "REMOTE HOST IDENTIFICATION HAS CHANGED"),
            ("known_hosts", "host_key", "Permission denied")
        ] {
            do {
                let unexpected = try connect(hosts: hosts, key: key)
                unexpected.disconnect()
                fatalError("Invalid host or client key was accepted")
            } catch SFTPError.transport(let message) {
                precondition(message.contains(expectedMessage), "Unexpected rejection: \(message)")
            }
        }
        print("PASS: authenticated SSH negotiation, listing, exact download, unknown/changed host rejection and unauthorized-key rejection")
    }
}
