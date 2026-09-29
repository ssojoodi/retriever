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
