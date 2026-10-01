import XCTest
@testable import RetrieverCore

final class SFTPTests: XCTestCase {
    func testApprovedReplacementAndPreviewLimitPreserveOriginal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let target = fixture.appendingPathComponent("target")
        let bytes = Data(repeating: 42, count: 1_000_001)
        let original = Data("original".utf8)
        try bytes.write(to: source)
        try original.write(to: target)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: target, policy: .replaceApproved, maximumBytes: 1_000_000)) {
            XCTAssertEqual($0 as? SFTPError, .previewLimitExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(session.isUsable)
        XCTAssertThrowsError(try session.download(Data(fixture.appendingPathComponent("missing").path.utf8), to: target, policy: .replaceApproved))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let signal = SFTPCancellation()
        session.cancellation = signal
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: target, policy: .replaceApproved) { _ in signal.cancel() })
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(session.isUsable)
        session.cancellation = SFTPCancellation()
        let total = try session.download(Data(source.path.utf8), to: target, policy: .replaceApproved)
        XCTAssertEqual(total, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: link, policy: .replaceApproved)) {
            XCTAssertEqual($0 as? SFTPError, .invalidDestination)
        }
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: fixture, policy: .replaceApproved))
        // The exact threshold is allowed.
        try Data(repeating: 1, count: 1_000_000).write(to: source)
        try session.download(Data(source.path.utf8), to: target, policy: .replaceApproved, maximumBytes: 1_000_000)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testBrowserRetainsSessionAfterLocalAndServerErrors() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data("payload".utf8).write(to: source)
        let browser = SFTPBrowser(initialPath: Data(fixture.path.utf8)) { _, signal in
            try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: signal)
        }
        let settings = try ConnectionSettings(host: "fixture", username: "test", port: "22")
        _ = try await browser.connect(settings, cancellation: SFTPCancellation())
        do {
            try await browser.download(Data(source.path.utf8), to: source, cancellation: SFTPCancellation())
            XCTFail("Expected destination error")
        } catch { XCTAssertEqual(error as? SFTPError, .destinationExists) }
        do {
            _ = try await browser.directory(Data(fixture.appendingPathComponent("missing").path.utf8), cancellation: SFTPCancellation())
            XCTFail("Expected missing folder")
        } catch SFTPError.server {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            try await browser.download(Data(source.path.utf8), to: fixture.appendingPathComponent("missing/file"), cancellation: SFTPCancellation())
            XCTFail("Expected local write error")
        } catch {}
        let cancelled = SFTPCancellation()
        cancelled.cancel()
        do { _ = try await browser.directory(Data(fixture.path.utf8), cancellation: cancelled); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let stillConnected = await browser.isConnected
        XCTAssertTrue(stillConnected)
        let directory = try await browser.directory(Data(fixture.path.utf8), cancellation: SFTPCancellation())
        XCTAssertEqual(directory.entries.map(\.name), ["source"])
        await browser.disconnect()
    }

    @MainActor
    func testDownloadHistoryPersistenceClearAndMissingFiles() throws {
        let suite = "DownloadHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("download")
        try Data("file".utf8).write(to: file)
        let settings = try ConnectionSettings(host: "fixture", username: "test", port: "22")
        let history = DownloadHistory(defaults: defaults)
        for name in ["first", "second"] {
            history.record(filename: name, settings: settings, remotePath: Data(name.utf8), destination: file, byteCount: 4)
        }
        let restored = DownloadHistory(defaults: defaults)
        XCTAssertEqual(restored.entries.map(\.filename), ["second", "first"])
        XCTAssertNotNil(restored.location(for: restored.entries[0].id))
        let moved = fixture.appendingPathComponent("moved-download")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(restored.location(for: restored.entries[0].id)?.standardizedFileURL, moved.standardizedFileURL)
        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(restored.location(for: restored.entries[0].id))
        try Data("file".utf8).write(to: file)
        restored.clear()
        XCTAssertTrue(DownloadHistory(defaults: defaults).entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testReconnectRestoresFolderAndFallsBackWhenMissing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let subfolder = fixture.appendingPathComponent("remember me")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let browser = SFTPBrowser(initialPath: Data(fixture.path.utf8)) { _, cancellation in
            try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: cancellation)
        }
        let settings = try ConnectionSettings(host: "fixture", username: "test", port: "22")
        let first = try await browser.connect(settings, startingAt: Data(subfolder.path.utf8), cancellation: SFTPCancellation())
        XCTAssertTrue(String(decoding: first.path, as: UTF8.self).hasSuffix("/remember me"))
        XCTAssertFalse(first.usedHomeFallback)
        try FileManager.default.removeItem(at: subfolder)
        let fallback = try await browser.connect(settings, startingAt: first.path, cancellation: SFTPCancellation())
        XCTAssertTrue(fallback.usedHomeFallback)
        XCTAssertTrue(fallback.entries.isEmpty)
        // Cancellation is never swallowed by the missing-folder fallback.
        let cancelled = SFTPCancellation()
        cancelled.cancel()
        do {
            _ = try await browser.connect(settings, startingAt: first.path, cancellation: cancelled)
            XCTFail("Cancelled connection unexpectedly succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await browser.disconnect()
    }

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

    func testCancelledHandshakeDoesNotWaitForServer() {
        let cancellation = SFTPCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try SFTPSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testStalledHandshakeTimesOut() {
        let started = Date()
        XCTAssertThrowsError(try SFTPSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], idleTimeout: 0.2)) { error in
            XCTAssertEqual(error as? SFTPError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testBlockedRequestWriteCanBeCancelled() throws {
        let cancellation = SFTPCancellation()
        // Emit an SFTP v3 greeting, then keep stdin open without reading it.
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"printf '\000\000\000\005\002\000\000\000\003'; exec /bin/sleep 5"#], cancellation: cancellation)
        defer { session.disconnect() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try session.canonicalPath(Data(repeating: 65, count: 1_000_000))) { error in
            XCTAssertTrue(error is CancellationError)
            session.handleFailure(error)
        }
        XCTAssertFalse(session.isUsable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testMalformedResponseInvalidatesSession() throws {
        // The greeting succeeds; a reply with the wrong request ID must poison
        // the session even though the complete response frame was received.
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"printf '\000\000\000\005\002\000\000\000\003\000\000\000\005\150\000\000\000\177'; exec /bin/sleep 5"#])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.canonicalPath(Data(".".utf8))) { error in
            XCTAssertEqual(error as? SFTPError, .malformedPacket)
            session.handleFailure(error)
        }
        XCTAssertFalse(session.isUsable)
    }

    func testBlockedRequestWriteTimesOut() throws {
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"printf '\000\000\000\005\002\000\000\000\003'; exec /bin/sleep 5"#], idleTimeout: 0.2)
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.canonicalPath(Data(repeating: 65, count: 1_000_000))) { error in
            XCTAssertEqual(error as? SFTPError, .timedOut)
            session.handleFailure(error)
        }
        XCTAssertFalse(session.isUsable)
    }

    func testClosedServerInputDoesNotTerminateClient() throws {
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"exec 0<&-; printf '\000\000\000\005\002\000\000\000\003'; exec /bin/sleep 5"#])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.canonicalPath(Data(repeating: 65, count: 1_000_000))) { error in
            XCTAssertEqual(error as? SFTPError, .disconnected)
        }
    }

    func testSSHFailureIncludesDiagnosticWithoutControlCharacters() {
        XCTAssertThrowsError(try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"printf 'Permission denied\007\r\n' >&2; exit 1"#])) { error in
            XCTAssertEqual(error as? SFTPError, .transport("Permission denied"))
        }
    }

    func testLargeDiagnosticCannotBlockHandshakeOrGrowWithoutBound() {
        let started = Date()
        XCTAssertThrowsError(try SFTPSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'Server authentication diagnostic line\\n' >&2; i=$((i+1)); done; exit 1"], idleTimeout: 3)) { error in
            guard case .transport(let message) = error as? SFTPError else { return XCTFail("Expected bounded SSH diagnostic, got \(error)") }
            XCTAssertTrue(message.hasPrefix("Server authentication diagnostic line"))
            XCTAssertLessThanOrEqual(message.utf8.count, 16384)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testDownloadReportsActualBytesAndCancellationRemovesPartialFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source.bin")
        let data = Data(repeating: 42, count: 150_000)
        try data.write(to: source)
        let signal = SFTPCancellation()
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: signal)
        defer { session.disconnect() }
        var counts: [UInt64] = []
        let completed = fixture.appendingPathComponent("completed.bin")
        try session.download(Data(source.path.utf8), to: completed) { counts.append($0) }
        XCTAssertEqual(counts.last, UInt64(data.count))
        XCTAssertEqual(counts, counts.sorted())
        XCTAssertGreaterThan(counts.count, 2)
        XCTAssertEqual(try Data(contentsOf: completed), data)
        let cancelled = fixture.appendingPathComponent("cancelled.bin")
        var receivedBeforeCancellation: UInt64 = 0
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: cancelled) { bytes in
            receivedBeforeCancellation = bytes
            signal.cancel()
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(receivedBeforeCancellation, 0)
        XCTAssertLessThan(receivedBeforeCancellation, UInt64(data.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
        XCTAssertEqual(try Data(contentsOf: completed), data)
    }

    func testDestinationCreatedDuringDownloadIsPreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data(repeating: 1, count: 100_000).write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        let destination = fixture.appendingPathComponent("destination")
        let original = Data("Created by another application".utf8)
        var created = false
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: destination) { _ in
            if !created {
                do { try original.write(to: destination); created = true }
                catch { XCTFail("Fixture write failed: \(error)") }
            }
        }) { error in
            XCTAssertEqual(error as? SFTPError, .destinationExists)
        }
        XCTAssertTrue(created)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testDanglingDestinationSymlinkIsPreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data("download".utf8).write(to: source)
        let destination = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "missing-target")
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: destination)) { error in
            XCTAssertEqual(error as? SFTPError, .destinationExists)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "missing-target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("missing-target").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    private func makeFixture() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("retriever-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}
