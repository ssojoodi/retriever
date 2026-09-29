import XCTest
@testable import RetrieverCore

final class SFTPTests: XCTestCase {
    func testRejectsTruncatedAndOversizedStrings() {
        for data in [Data(), Data([0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 2, 65])] {
            var reader = SFTPReader(data)
            XCTAssertThrowsError(try reader.bytes())
        }
    }

    func testDecodesLargeSizeAndDirectoryAttributes() throws {
        var writer = SFTPWriter()
        writer.uint32(13)
        writer.uint64(5_000_000_000)
        writer.uint32(0o40755)
        writer.uint32(0)
        writer.uint32(1234)
        var reader = SFTPReader(writer.data)
        let attributes = try reader.attributes()
        XCTAssertEqual(attributes.size, 5_000_000_000)
        XCTAssertTrue(attributes.isDirectory)
        XCTAssertEqual(attributes.modified, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(reader.remaining, 0)
    }

    func testRejectsUnknownAttributeFlags() {
        var reader = SFTPReader(Data([0, 0, 0, 16]))
        XCTAssertThrowsError(try reader.attributes())
    }

    func testLocalServerListsAndDownloadsExactBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let name = "report 'quoted' ü\n2026.bin"
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: fixture.appendingPathComponent(name))
        try Data().write(to: fixture.appendingPathComponent("empty"))
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        let path = try session.canonicalPath(Data(fixture.path.utf8))
        let entries = try session.listDirectory(path)
        XCTAssertEqual(Set(entries.map(\.name)), Set([name, "empty", "folder"]))
        XCTAssertEqual(entries.first?.name, "folder")
        XCTAssertEqual(entries.first?.attributes.isDirectory, true)
        XCTAssertEqual(entries.first(where: { $0.name == name })?.attributes.size, UInt64(bytes.count))
        let destination = fixture.appendingPathComponent("download")
        try session.download(SFTPSession.appending(Data(name.utf8), to: path), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let empty = fixture.appendingPathComponent("empty-download")
        try session.download(SFTPSession.appending(Data("empty".utf8), to: path), to: empty)
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testFailuresPreserveDestinationAndSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        let path = Data(fixture.path.utf8)
        let missing = SFTPSession.appending(Data("missing".utf8), to: path)
        let destination = fixture.appendingPathComponent("destination")
        XCTAssertThrowsError(try session.download(missing, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let original = Data("Keep my file".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try session.download(missing, to: destination)) { error in
            XCTAssertEqual(error as? SFTPError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertThrowsError(try session.listDirectory(missing))
        XCTAssertEqual(try session.listDirectory(path).map(\.name), ["destination"])
    }

    func testDisconnectedSessionFailsImmediately() throws {
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        session.disconnect()
        XCTAssertThrowsError(try session.canonicalPath(Data(".".utf8))) { error in
            XCTAssertEqual(error as? SFTPError, .disconnected)
        }
    }

    private func makeFixture() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("retriever-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}
