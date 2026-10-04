import AppKit
import UniformTypeIdentifiers

/// Finder owns the destination. Keep the delegate alive with its pasteboard writer.
final class RemoteFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let filename: String
    private let fulfill: @MainActor @Sendable (URL, @escaping @Sendable (Error?) -> Void) -> Void

    @MainActor
    init(filename: String, directory: Bool, fulfill: @escaping @MainActor @Sendable (URL, @escaping @Sendable (Error?) -> Void) -> Void) {
        self.filename = filename
        self.fulfill = fulfill
        super.init()
        fileType = directory ? UTType.folder.identifier : (UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier ?? UTType.data.identifier)
        delegate = self
    }
    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { filename }
    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let completion = PromiseCompletion(completionHandler)
        let callback = fulfill
        // AppKit invokes this on operationQueue(for:), explicitly the main queue.
        MainActor.assumeIsolated {
            callback(url) { completion.finish($0) }
        }
    }
}

/// AppKit's completion is not annotated Sendable. Call it at most once.
private final class PromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func finish(_ error: Error?) {
        let callback = lock.withLock { let result = handler; handler = nil; return result }
        callback?(error)
    }
}
