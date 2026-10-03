import Foundation
@testable import RetrieverCore

@main
struct SSHChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = try ConnectionSettings(host: "127.0.0.1", username: CommandLine.arguments[3], port: CommandLine.arguments[2])
        func connect(hosts: String = "known_hosts", key: String = "client_key", helper: String? = nil) throws -> SFTPSession {
            let options = ["-F", "/dev/null", "-i", root.appendingPathComponent(key).path,
                           "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                           "-o", "GlobalKnownHostsFile=/dev/null",
                           "-o", "UserKnownHostsFile=\(root.appendingPathComponent(hosts).path)"]
            return try SFTPSession(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: options + SFTPSession.sshArguments(settings, interactive: helper != nil), environment: helper.map { SFTPSession.askpassEnvironment(root.appendingPathComponent($0)) })
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
        let uploadPath = SFTPSession.appending(Data("uploaded.bin".utf8), to: path)
        try session.upload(destination, to: uploadPath)
        let uploaded = try Data(contentsOf: root.appendingPathComponent("files/uploaded.bin"))
        precondition(uploaded == expected, "Authenticated upload bytes differ")
        try Data("replacement".utf8).write(to: destination)
        try session.upload(destination, to: uploadPath, policy: .replaceApproved)
        let replaced = try Data(contentsOf: root.appendingPathComponent("files/uploaded.bin"))
        precondition(replaced == Data("replacement".utf8))
        print("PASS: authenticated upload and explicit remote replacement")
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
        let interactive = try connect(hosts: "new_hosts", key: "encrypted_key", helper: "askpass")
        _ = try interactive.canonicalPath(Data(".".utf8))
        interactive.disconnect()
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("new_hosts").path), "Explicit trust must persist its host key")
        do {
            let rejected = try connect(hosts: "rejected_hosts", helper: "reject-askpass")
            rejected.disconnect()
            fatalError("Cancelled trust must fail")
        } catch SFTPError.transport { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("rejected_hosts").path), "Cancelled trust must not persist")
        print("PASS: first-host askpass confirmation, encrypted-key passphrase and cancelled trust")
        print("PASS: authenticated SSH negotiation, listing, exact download, unknown/changed host rejection and unauthorized-key rejection")
    }
}
