import XCTest
@testable import RetrieverCore

private actor UpdateResponseGate {
    var requests: [URLRequest] = []
    var continuation: CheckedContinuation<Data, Error>?
    func fetch(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Data, Error>) { continuation?.resume(with: result); continuation = nil }
    var count: Int { requests.count }
}

final class UpdateCheckerTests: XCTestCase {
    private func metadata(_ url: String = "https://updates.example.com/release.json") -> [String: Any] {
        ["RetrieverUpdateManifestURL": url, "RetrieverUpdateDownloadURL": "https://downloads.example.com/Retriever.dmg",
         "RetrieverUpdateReleaseNotesURL": "https://example.com/notes"]
    }
    private func manifest(_ version: String = "0.10.0") -> Data {
        Data("""
        {"version":"\(version)","file":"Retriever.dmg","sha256":"\(String(repeating: "a", count: 64))","bytes":1234,"published":"2026-10-04T00:30:03.020849+00:00","extra":true}
        """.utf8)
    }
    func testNumericVersionOrderingAndInvalidVersions() throws {
        XCTAssertLessThan(try ReleaseVersion("0.9.0"), try ReleaseVersion("0.10.0"))
        XCTAssertLessThan(try ReleaseVersion("0.10.0"), try ReleaseVersion("1.0.0"))
        XCTAssertEqual(try ReleaseVersion("0.05.0"), try ReleaseVersion("0.5.0"))
        for value in ["", "0.5", "0.5.0.1", "-1.0.0", "+1.0.0", "1.0.0-beta", " 1.0.0", "١.0.0", "1..0", "9999999999999999999999999.0.0"] {
            XCTAssertThrowsError(try ReleaseVersion(value), value)
        }
    }
    func testConfiguration() throws {
        XCTAssertEqual(try UpdateConfiguration(metadata: metadata()).manifestURL.host, "updates.example.com")
        for url in ["", "http://example.com", "https:///", "/release.json", "https://user:pass@example.com", "https://example.com/#fragment", "https://example.com/a b", "https://example.com/\n", "$(URL)", "https://example.com/${PATH}"] {
            XCTAssertThrowsError(try UpdateConfiguration(metadata: metadata(url)), url)
        }
        XCTAssertThrowsError(try UpdateConfiguration(metadata: [:]))
        var invalid = metadata(); invalid["RetrieverUpdateDownloadURL"] = "http://example.com"
        XCTAssertThrowsError(try UpdateConfiguration(metadata: invalid))
    }
    func testManifestValidation() throws {
        XCTAssertEqual(try UpdateManifest(data: manifest()).version.description, "0.10.0")
        let valid = String(decoding: manifest(), as: UTF8.self)
        for invalid in ["{}", "null", "[]", valid.replacingOccurrences(of: "Retriever.dmg", with: "../other.dmg"),
                        valid.replacingOccurrences(of: "1234", with: "0"), valid.replacingOccurrences(of: "1234", with: "1.5"),
                        valid.replacingOccurrences(of: String(repeating: "a", count: 64), with: "bad"),
                        valid.replacingOccurrences(of: "2026-10-04T00:30:03.020849+00:00", with: "yesterday"),
                        valid.replacingOccurrences(of: "0.10.0", with: "invalid")] {
            XCTAssertThrowsError(try UpdateManifest(data: Data(invalid.utf8)))
        }
    }

    func testHTTPResponses() throws {
        let url = URL(string: "https://example.com/release.json")!
        for code in [200, 201] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertEqual(try UpdateNetwork.validatedResponse(manifest(), response: response), manifest())
        }
        for code in [301, 304, 404, 503] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try UpdateNetwork.validatedResponse(manifest(), response: response))
        }
        XCTAssertThrowsError(try UpdateNetwork.validatedResponse(manifest(), response: URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
        let insecure = HTTPURLResponse(url: URL(string: "http://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try UpdateNetwork.validatedResponse(manifest(), response: insecure))
    }

    @MainActor
    func testSchedulingCoalescingPersistenceAndDeferral() async throws {
        let suite = "UpdateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 100_000)
        let gate = UpdateResponseGate()
        let config = try UpdateConfiguration(metadata: metadata())
        let checker = UpdateChecker(configuration: .success(config), installedVersion: "0.9.0", defaults: defaults,
                                    clock: { now }, transport: { try await gate.fetch($0) })
        var shown: [(UpdateStatus, Bool)] = []
        checker.present = { shown.append(($0, $1)) }
        XCTAssertFalse(checker.automaticEnabled)
        checker.setActive(true)
        XCTAssertFalse(checker.isChecking)
        checker.automaticEnabled = true
        checker.setActive(false)
        checker.checkAutomaticallyIfDue()
        XCTAssertFalse(checker.isChecking)
        checker.setActive(true)
        await waitForRequest(gate)
        checker.checkManually() // joins the automatic request
        let firstCount = await gate.count
        XCTAssertEqual(firstCount, 1)
        let sent = await gate.requests
        XCTAssertEqual(sent.first?.url, config.manifestURL)
        XCTAssertEqual(sent.first?.timeoutInterval, UpdateConfiguration.requestTimeout)
        XCTAssertEqual(sent.first?.cachePolicy, .reloadRevalidatingCacheData)
        XCTAssertEqual(shown.last?.0, .checking)
        checker.automaticEnabled = false
        await gate.finish(.success(manifest()))
        await waitForCompletion(checker)
        XCTAssertEqual(shown.last?.0, .available(installed: "0.9.0", latest: "0.10.0"))
        XCTAssertEqual(shown.last?.1, true) // disabling must preserve joined manual checks
        checker.automaticEnabled = true
        now.addTimeInterval(UpdateConfiguration.automaticInterval - 1)
        checker.checkAutomaticallyIfDue()
        XCTAssertFalse(checker.isChecking)
        now.addTimeInterval(1)
        checker.checkAutomaticallyIfDue()
        await waitForRequest(gate, count: 2)
        checker.setActive(false)
        let countBefore = shown.count
        await gate.finish(.success(manifest()))
        await waitForCompletion(checker)
        XCTAssertEqual(shown.count, countBefore)
        checker.setActive(true)
        XCTAssertEqual(shown.last?.1, false)
        XCTAssertEqual(shown.count, countBefore + 1)
        now.addTimeInterval(UpdateConfiguration.automaticInterval)
        checker.checkAutomaticallyIfDue()
        await waitForRequest(gate, count: 3)
        await gate.finish(.success(manifest()))
        await waitForCompletion(checker)
        XCTAssertEqual(shown.count, countBefore + 1) // same automatic version suppressed
        let restored = UpdateChecker(configuration: .success(config), installedVersion: "0.9.0", defaults: defaults, clock: { now })
        XCTAssertTrue(restored.automaticEnabled)
        XCTAssertEqual(restored.nextAutomaticAttempt, now.addingTimeInterval(UpdateConfiguration.automaticInterval))
        checker.checkManually() // manual bypass
        await waitForRequest(gate, count: 4)
        await gate.finish(.failure(URLError(.timedOut)))
        await waitForCompletion(checker)
        guard case .failed = shown.last?.0 else { return XCTFail("Expected manual error") }
        XCTAssertEqual(checker.nextAutomaticAttempt, now.addingTimeInterval(UpdateConfiguration.automaticInterval))
        checker.stop(); restored.stop()
    }

    @MainActor
    func testAutomaticDisableAndSilentResults() async throws {
        let suite = "UpdateTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = UpdateResponseGate()
        var now = Date()
        let checker = UpdateChecker(configuration: .success(try UpdateConfiguration(metadata: metadata())),
                                    installedVersion: "0.9.0", defaults: defaults, clock: { now },
                                    transport: { try await gate.fetch($0) })
        var shown: [UpdateStatus] = []
        checker.present = { status, _ in shown.append(status) }
        checker.automaticEnabled = true
        checker.setActive(true)
        await waitForRequest(gate)
        checker.automaticEnabled = false
        checker.automaticEnabled = true
        await gate.finish(.success(manifest()))
        await waitForCompletion(checker)
        XCTAssertTrue(shown.isEmpty)
        for (index, result) in [Result<Data, Error>.success(manifest("0.9.0")), .success(manifest("0.8.0")), .failure(UpdateError.httpStatus(503))].enumerated() {
            now.addTimeInterval(UpdateConfiguration.automaticInterval)
            checker.checkAutomaticallyIfDue()
            await waitForRequest(gate, count: index + 2)
            await gate.finish(result)
            await waitForCompletion(checker)
            XCTAssertTrue(shown.isEmpty)
        }
        now.addTimeInterval(UpdateConfiguration.automaticInterval)
        checker.checkAutomaticallyIfDue()
        await waitForRequest(gate, count: 5)
        checker.setActive(false)
        await gate.finish(.success(manifest()))
        await waitForCompletion(checker)
        checker.automaticEnabled = false
        checker.setActive(true)
        XCTAssertTrue(shown.isEmpty) // deferred result also suppressed
        checker.stop()
    }

    @MainActor
    func testNotificationPersistsAndManualCurrentResultDefers() async throws {
        let suite = "UpdateTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = try UpdateConfiguration(metadata: metadata())
        var now = Date()
        let newer = manifest()
        let first = UpdateChecker(configuration: .success(config), installedVersion: "0.9.0", defaults: defaults,
                                  clock: { now }, transport: { _ in newer })
        var automaticCount = 0
        first.present = { _, manual in if !manual { automaticCount += 1 } }
        first.automaticEnabled = true
        first.setActive(true)
        await waitForCompletion(first)
        XCTAssertEqual(automaticCount, 1)
        first.stop()
        now.addTimeInterval(UpdateConfiguration.automaticInterval)
        let gate = UpdateResponseGate()
        let restored = UpdateChecker(configuration: .success(config), installedVersion: "0.9.0", defaults: defaults,
                                     clock: { now }, transport: { try await gate.fetch($0) })
        var shown: [UpdateStatus] = []
        restored.present = { status, _ in shown.append(status) }
        restored.setActive(true)
        await waitForRequest(gate)
        await gate.finish(.success(newer))
        await waitForCompletion(restored)
        XCTAssertTrue(shown.isEmpty, "Do not repeat automatic notifications after relaunch")
        restored.checkManually()
        await waitForRequest(gate, count: 2)
        restored.setActive(false)
        await gate.finish(.success(manifest("0.8.0")))
        await waitForCompletion(restored)
        XCTAssertEqual(shown, [.checking])
        restored.setActive(true)
        XCTAssertEqual(shown.last, .current(installed: "0.9.0"))
        restored.stop()
    }

    @MainActor
    func testInvalidConfigurationAndInstalledVersionNeverRequest() throws {
        let suite = "UpdateTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (config, version) in [(Result<UpdateConfiguration, Error>.failure(UpdateError.configuration), "0.5.0"),
                                  (.success(try UpdateConfiguration(metadata: metadata())), "bad")] {
            let checker = UpdateChecker(configuration: config, installedVersion: version, defaults: defaults,
                                        transport: { _ in XCTFail("Unexpected request"); return Data() })
            var status: UpdateStatus?
            checker.present = { value, _ in status = value }
            checker.setActive(true); checker.checkManually()
            guard case .failed = status else { return XCTFail("Expected error") }
            XCTAssertFalse(checker.isChecking)
            XCTAssertNil(checker.nextAutomaticAttempt)
        }
    }

    @MainActor private func waitForRequest(_ gate: UpdateResponseGate, count: Int = 1) async {
        for _ in 0..<1000 {
            if await gate.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Request did not start")
    }
    @MainActor private func waitForCompletion(_ checker: UpdateChecker) async {
        for _ in 0..<1000 {
            if !checker.isChecking { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Request did not finish")
    }
}
