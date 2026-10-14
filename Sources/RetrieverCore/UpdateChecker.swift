import Foundation

public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    private let components: [Int]
    public var description: String { components.map(String.init).joined(separator: ".") }

    public init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw UpdateError.invalidVersion }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { throw UpdateError.invalidVersion }
            numbers.append(number)
        }
        components = numbers
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum UpdateError: LocalizedError, Sendable {
    case configuration, invalidVersion, invalidManifest, httpStatus(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .configuration: "Update URLs are missing or invalid. Please contact the app developer."
        case .invalidVersion: "The app or release version is invalid. Unable to check for updates."
        case .invalidManifest: "The update server returned invalid release information."
        case .httpStatus(let status): "The update server returned HTTP \(status). Please try again later."
        case .invalidResponse: "The update server returned an invalid response."
        }
    }
}

public struct UpdateConfiguration: Sendable {
    public static let automaticInterval: TimeInterval = 24 * 60 * 60
    public static let requestTimeout: TimeInterval = 15
    public let manifestURL: URL
    public let downloadURL: URL
    public let releaseNotesURL: URL

    public init(metadata: [String: Any]) throws {
        manifestURL = try Self.validatedURL(metadata["RetrieverUpdateManifestURL"])
        downloadURL = try Self.validatedURL(metadata["RetrieverUpdateDownloadURL"])
        releaseNotesURL = try Self.validatedURL(metadata["RetrieverUpdateReleaseNotesURL"])
    }

    public static func validatedURL(_ value: Any?) throws -> URL {
        guard let string = value as? String, !string.isEmpty,
              !string.contains("$("), !string.contains("${"),
              string.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let parts = URLComponents(string: string), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url else { throw UpdateError.configuration }
        return url
    }
}

public struct UpdateManifest: Sendable {
    public let version: ReleaseVersion
    public init(data: Data) throws {
        struct Fields: Decodable {
            let version: String
            let file: String
            let sha256: String
            let bytes: Int64
            let published: String
        }
        do {
            let fields = try JSONDecoder().decode(Fields.self, from: data)
            let date = ISO8601DateFormatter()
            date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractionalDate = date.date(from: fields.published)
            date.formatOptions = [.withInternetDateTime]
            guard fields.file == "Retriever.dmg", fields.bytes > 0,
                  fields.sha256.utf8.count == 64,
                  fields.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  fractionalDate != nil || date.date(from: fields.published) != nil else {
                throw UpdateError.invalidManifest
            }
            version = try ReleaseVersion(fields.version)
        } catch { throw UpdateError.invalidManifest }
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case checking
    case current(installed: String)
    case available(installed: String, latest: String)
    case failed(String)
}

public typealias UpdateTransport = @Sendable (URLRequest) async throws -> Data

public enum UpdateNetwork {
    public static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try validatedResponse(data, response: response)
    }

    static func validatedResponse(_ data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse,
              let url = http.url, (try? UpdateConfiguration.validatedURL(url.absoluteString)) != nil else {
            throw UpdateError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else { throw UpdateError.httpStatus(http.statusCode) }
        return data
    }
}

/// Owns update policy independently of AppKit, SFTP, and terminal sessions.
/// The app calls `checkAutomaticallyIfDue` on activation and while active.
@MainActor
public final class UpdateChecker {
    private let defaults: UserDefaults
    private let configuration: Result<UpdateConfiguration, Error>
    private let installed: String?
    private let clock: () -> Date
    private let transport: UpdateTransport
    private var request: Task<Void, Never>?
    private var wantsManual = false
    private var allowsAutomaticResult = false
    private var pending: (UpdateStatus, manual: Bool)?
    public private(set) var isActive = false
    public var present: ((UpdateStatus, _ manual: Bool) -> Void)?
    public var isChecking: Bool { request != nil }
    private static let enabledKey = "updates.automatic.v1"
    private static let attemptKey = "updates.lastAttempt.v1"
    private static let presentedKey = "updates.lastPresentedVersion.v1"

    public init(configuration: Result<UpdateConfiguration, Error>, installedVersion: String?,
                defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
                transport: @escaping UpdateTransport = UpdateNetwork.fetch) {
        self.configuration = configuration
        installed = installedVersion
        self.defaults = defaults
        self.clock = clock
        self.transport = transport
    }

    public var automaticEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                allowsAutomaticResult = false
                if pending?.manual == false { pending = nil }
            }
        }
    }

    public var nextAutomaticAttempt: Date? {
        (defaults.object(forKey: Self.attemptKey) as? Date)?.addingTimeInterval(UpdateConfiguration.automaticInterval)
    }

    public func setActive(_ active: Bool) {
        isActive = active
        if active {
            if let pending { self.pending = nil; deliver(pending.0, manual: pending.manual) }
            checkAutomaticallyIfDue()
        }
    }

    public func checkAutomaticallyIfDue() {
        guard automaticEnabled, isActive, request == nil,
              nextAutomaticAttempt.map({ clock() >= $0 }) ?? true else { return }
        start(manual: false)
    }

    public func checkManually() {
        pending = nil
        wantsManual = true
        deliver(.checking, manual: true)
        if request == nil { start(manual: true) }
    }

    public func stop() {
        request?.cancel()
        request = nil
        pending = nil
        present = nil
    }

    private func start(manual: Bool) {
        wantsManual = manual
        allowsAutomaticResult = !manual && automaticEnabled
        let config: UpdateConfiguration
        let version: ReleaseVersion
        do {
            config = try configuration.get()
            version = try ReleaseVersion(installed ?? "")
        } catch {
            if manual { deliver(.failed(error.localizedDescription), manual: true) }
            return
        }
        defaults.set(clock(), forKey: Self.attemptKey)
        var urlRequest = URLRequest(url: config.manifestURL, cachePolicy: .reloadRevalidatingCacheData,
                                    timeoutInterval: UpdateConfiguration.requestTimeout)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let transport = self.transport
        request = Task { [weak self] in
            let status: UpdateStatus
            do {
                let manifest = try UpdateManifest(data: await transport(urlRequest))
                status = manifest.version > version
                    ? .available(installed: version.description, latest: manifest.version.description)
                    : .current(installed: version.description)
            } catch { status = .failed(error.localizedDescription) }
            guard !Task.isCancelled, let self else { return }
            self.request = nil
            if self.wantsManual { self.deliver(status, manual: true) }
            else if self.allowsAutomaticResult { self.deliver(status, manual: false) }
        }
    }

    private func deliver(_ status: UpdateStatus, manual: Bool) {
        if !manual {
            guard automaticEnabled, case .available(_, let latest) = status else { return }
            if let previous = defaults.string(forKey: Self.presentedKey),
               let priorVersion = try? ReleaseVersion(previous), let version = try? ReleaseVersion(latest),
               version <= priorVersion { return }
        }
        guard isActive else { pending = (status, manual); return }
        guard let present else { return }
        present(status, manual)
        if !manual, case .available(_, let latest) = status {
            defaults.set(latest, forKey: Self.presentedKey)
        }
    }
}
