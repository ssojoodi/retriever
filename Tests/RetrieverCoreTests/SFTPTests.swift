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

    func testUploadRoundTripAndExplicitReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        let target = fixture.appendingPathComponent("uploaded café.txt")
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        XCTAssertEqual(try session.upload(source, to: Data(target.path.utf8)), UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try Data().write(to: source)
        XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8))) {
            XCTAssertEqual($0 as? SFTPError, .uploadDestinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try session.upload(source, to: Data(target.path.utf8), policy: .replaceApproved), 0)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testCancelledUploadPreservesDestinationAndSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        let target = fixture.appendingPathComponent("remote")
        try Data(repeating: 7, count: 100_000).write(to: source)
        let original = Data("original".utf8)
        try original.write(to: target)
        let signal = SFTPCancellation()
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: signal)
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8), policy: .replaceApproved) { _ in signal.cancel() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
        session.cancellation = SFTPCancellation()
        XCTAssertEqual(try session.listDirectory(Data(fixture.path.utf8)).count, 2)
    }

    func testUploadRejectsSymlinksAndFoldersAndConcurrentDestination() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        let target = fixture.appendingPathComponent("remote")
        try Data(repeating: 7, count: 100_000).write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.upload(fixture, to: Data(target.path.utf8)))
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: source.path)
        XCTAssertThrowsError(try session.upload(target, to: Data(fixture.appendingPathComponent("other").path.utf8)))
        XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8), policy: .replaceApproved))
        try FileManager.default.removeItem(at: target)
        let original = Data("other writer".utf8)
        XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8)) { _ in
            if !FileManager.default.fileExists(atPath: target.path) { try! original.write(to: target) }
        })
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testReadOnlyUploadFailureKeepsSessionUsable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        try Data("hello".utf8).write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-R"])
        defer { session.disconnect() }
        XCTAssertThrowsError(try session.upload(source, to: Data(fixture.appendingPathComponent("remote").path.utf8)))
        XCTAssertEqual(try session.listDirectory(Data(fixture.path.utf8)).count, 1)
    }

    func testFailedUploadWriteAndCloseNeverPublish() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        let target = fixture.appendingPathComponent("remote")
        try Data("new contents".utf8).write(to: source)
        let original = Data("original".utf8)
        try original.write(to: target)
        for denied in ["write", "close"] {
            let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-P", denied])
            defer { session.disconnect() }
            XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8), policy: .replaceApproved))
            XCTAssertTrue(session.isUsable)
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
        }
    }

    func testUploadDetectsChangedSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        let target = fixture.appendingPathComponent("remote")
        try Data(repeating: 1, count: 100_000).write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        var changed = false
        XCTAssertThrowsError(try session.upload(source, to: Data(target.path.utf8)) { _ in
            if !changed {
                changed = true
                let file = try! FileHandle(forWritingTo: source)
                try! file.truncate(atOffset: 32768)
                try! file.close()
            }
        }) { XCTAssertEqual($0 as? SFTPError, .uploadSourceChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") })
    }

    func testUploadRefusesUnadvertisedReplacementAndReportsLostReplies() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("local")
        try Data("contents".utf8).write(to: source)
        // A small protocol peer drops a chosen reply. It never touches the filesystem.
        let peer = #"""
        import sys, struct
        mode = sys.argv[1]
        def integer(n): return struct.pack('>I', n)
        def string(b): return integer(len(b)) + b
        def send(b):
            sys.stdout.buffer.write(string(b)); sys.stdout.buffer.flush()
        def read():
            header = sys.stdin.buffer.read(4)
            if not header: sys.exit(0)
            return sys.stdin.buffer.read(struct.unpack('>I', header)[0])
        read()
        send(bytes([2]) + integer(3))
        while True:
            packet = read()
            kind, request = packet[0], packet[1:5]
            if mode == 'unsupported':
                assert kind == 7
                send(bytes([105]) + request + integer(4) + integer(0o100600))
                continue
            if str(kind) == mode: sys.exit(0)
            if kind == 7:
                send(bytes([101]) + request + integer(2) + string(b'missing') + string(b''))
            elif kind == 3:
                send(bytes([102]) + request + string(b'handle'))
            elif kind in (6, 4):
                send(bytes([101]) + request + integer(0) + string(b'') + string(b''))
            else: raise AssertionError(kind)
        """#
        for mode in ["unsupported", "3", "6", "18"] {
            let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", peer, mode])
            defer { session.disconnect() }
            XCTAssertThrowsError(try session.upload(source, to: Data("/remote/file".utf8), policy: mode == "unsupported" ? .replaceApproved : .exclusive)) { error in
                if mode == "unsupported" {
                    XCTAssertEqual(error as? SFTPError, .uploadReplacementUnsupported)
                    XCTAssertTrue(session.isUsable)
                } else {
                    guard case SFTPError.uploadIncomplete(let message) = error else { return XCTFail("Expected remote cleanup warning: \(error)") }
                    XCTAssertTrue(message.contains(".partial"))
                    XCTAssertEqual(message.contains("may have completed"), mode == "18")
                    XCTAssertFalse(session.isUsable)
                }
            }
        }
    }

    func testRemoteDirectoryOperationsAndNonFollowingAttributes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let browser = SFTPBrowser(initialPath: Data(fixture.path.utf8)) { _, signal in
            try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [], cancellation: signal)
        }
        _ = try await browser.connect(ConnectionSettings(host: "fixture", username: "test", port: "22"), cancellation: SFTPCancellation())
        let folder = fixture.appendingPathComponent("empty")
        let path = Data(folder.path.utf8)
        let missing = try await browser.attributes(at: path, cancellation: SFTPCancellation())
        XCTAssertNil(missing)
        try await browser.createDirectory(at: path, cancellation: SFTPCancellation())
        let attributes = try await browser.attributes(at: path, cancellation: SFTPCancellation())
        XCTAssertEqual(attributes?.isDirectory, true)
        let empty = try await browser.directory(path, cancellation: SFTPCancellation())
        XCTAssertTrue(empty.entries.isEmpty)
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let linked = try await browser.attributes(at: Data(link.path.utf8), cancellation: SFTPCancellation())
        XCTAssertEqual(linked?.isSymbolicLink, true)
        do {
            try await browser.createDirectory(at: path, cancellation: SFTPCancellation())
            XCTFail("Existing directory must require separate merge approval")
        } catch {}
        let cancelled = SFTPCancellation()
        cancelled.cancel()
        do {
            try await browser.createDirectory(at: Data(fixture.appendingPathComponent("cancelled").path.utf8), cancellation: cancelled)
            XCTFail("Cancelled mkdir must not run")
        } catch is CancellationError {}
        let connected = await browser.isConnected
        XCTAssertTrue(connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("cancelled").path))
        await browser.disconnect()
    }

    func testLocalTreeRejectsSymlinksAndTraversal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = try LocalTransferDirectory(url: fixture)
        let child = try root.createDirectory(named: "empty")
        XCTAssertTrue(try child.entries().isEmpty)
        try Data("visible".utf8).write(to: fixture.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("link"), withDestinationURL: child.url)
        XCTAssertEqual(try root.attributes(of: "link")?.kind, .symbolicLink)
        XCTAssertNil(try root.attributes(of: "absent"))
        XCTAssertThrowsError(try root.openDirectory(named: "link"))
        XCTAssertThrowsError(try LocalTransferDirectory(url: fixture.appendingPathComponent("link/nested")))
        for name in ["", ".", "..", "../escape", "a/b", "a\0b"] {
            XCTAssertThrowsError(try root.createDirectory(named: name))
            XCTAssertThrowsError(try root.attributes(of: name))
        }
        XCTAssertEqual(try root.entries().map(\.name), [".hidden", "empty", "link"])
        XCTAssertEqual(try root.entries().map(\.name), [".hidden", "empty", "link"], "Enumeration must not reuse a spent directory offset")
        let cancelled = SFTPCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try root.entries(cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testDirectoryHandlesKeepTransfersInsideOriginalParent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = try LocalTransferDirectory(url: fixture)
        let destination = try root.createDirectory(named: "destination")
        let outside = try root.createDirectory(named: "outside")
        let source = fixture.appendingPathComponent("source")
        let bytes = Data(repeating: 79, count: 70_000)
        try bytes.write(to: source)
        let session = try SFTPSession(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: [])
        defer { session.disconnect() }
        var moved = false
        try session.download(Data(source.path.utf8), to: destination, name: "result") { _ in
            guard !moved else { return }
            moved = true
            do {
                try FileManager.default.moveItem(at: destination.url, to: fixture.appendingPathComponent("retained"))
                try FileManager.default.createSymbolicLink(at: destination.url, withDestinationURL: outside.url)
            } catch { XCTFail("Could not replace destination parent: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("result").path))
        XCTAssertEqual(try Data(contentsOf: fixture.appendingPathComponent("retained/result")), bytes)
        let target = fixture.appendingPathComponent("uploaded")
        try session.upload(from: destination, name: "result", to: Data(target.path.utf8))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertThrowsError(try session.upload(destination.url.appendingPathComponent("result"), to: Data(fixture.appendingPathComponent("not-created").path.utf8)))
        XCTAssertThrowsError(try session.download(Data(source.path.utf8), to: destination.url.appendingPathComponent("not-created")))
        XCTAssertTrue(try outside.entries().isEmpty)
        XCTAssertFalse(try destination.entries().contains { $0.name.hasSuffix(".partial") })
    }

    private func makeFixture() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("retriever-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}
