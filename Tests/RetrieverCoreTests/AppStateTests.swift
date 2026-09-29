import XCTest
@testable import RetrieverCore

final class AppStateTests: XCTestCase {
    func testTrimsConnectionFields() throws {
        let value = try ConnectionSettings(host: " example.com ", username: " user ", port: "22")
        XCTAssertEqual(value.host, "example.com")
        XCTAssertEqual(value.username, "user")
        XCTAssertEqual(value.port, 22)
    }
    func testRejectsInvalidHosts() {
        for host in ["", "-option", "sftp://example.com", "user@host", "two hosts"] {
            XCTAssertThrowsError(try ConnectionSettings(host: host, username: "user", port: "22"))
        }
    }
    func testPortBoundaries() throws {
        for port in ["0", "65536", "-1", "abc", ""] {
            XCTAssertThrowsError(try ConnectionSettings(host: "host", username: "user", port: port))
        }
        for port in ["1", "65535"] {
            XCTAssertNoThrow(try ConnectionSettings(host: "host", username: "user", port: port))
        }
    }
    func testRequiresUsername() {
        XCTAssertThrowsError(try ConnectionSettings(host: "host", username: " ", port: "22"))
    }
    func testAcceptsIPv6() throws {
        XCTAssertEqual(try ConnectionSettings(host: "::1", username: "user", port: "22").host, "::1")
    }
}

@MainActor
final class ConnectionHistoryTests: XCTestCase {
    func testHistorySurvivesReloadAndSeparatesAccountsAndPorts() throws {
        let suite = "RetrieverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = try ConnectionSettings(host: "server", username: "alice", port: "22")
        let b = try ConnectionSettings(host: "server", username: "bob", port: "22")
        let c = try ConnectionSettings(host: "server", username: "alice", port: "2222")
        let history = ConnectionHistory(defaults: defaults)
        history.remember(a, path: Data("/first".utf8))
        history.remember(b, path: Data("/bob".utf8))
        history.remember(c, path: Data("/alternate".utf8))
        let rawPath = Data([47, 255, 10, 97])
        history.updateLocation(rawPath, for: a)
        history.remember(a, path: rawPath)
        let reloaded = ConnectionHistory(defaults: defaults)
        XCTAssertEqual(reloaded.hosts.map(\.settings), [a, c, b])
        XCTAssertEqual(reloaded.hosts.first?.lastPath, rawPath)
        reloaded.forget(a)
        reloaded.updateLocation(Data("/new".utf8), for: a)
        XCTAssertEqual(ConnectionHistory(defaults: defaults).hosts.map(\.settings), [c, b])
    }

    func testInvalidStorageDoesNotCrashOrBypassValidation() {
        let suite = "RetrieverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "savedHosts.v1")
        XCTAssertTrue(ConnectionHistory(defaults: defaults).hosts.isEmpty)
        let data = Data(#"{"host":"-option","username":"user","port":22}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ConnectionSettings.self, from: data))
    }
}
