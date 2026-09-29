import AppKit
@testable import RetrieverCore

@main
@MainActor
struct BrowserChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let browser = SFTPBrowser(initialPath: Data(root.appendingPathComponent("files").path.utf8)) { settings, signal in
            let options = ["-F", "/dev/null", "-i", root.appendingPathComponent("client_key").path,
                           "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                           "-o", "GlobalKnownHostsFile=/dev/null",
                           "-o", "UserKnownHostsFile=\(root.appendingPathComponent("known_hosts").path)"]
            return try SFTPSession(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: options + SFTPSession.sshArguments(settings), cancellation: signal)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        AppMenu.install()
        let controller = MainWindowController(browser: browser)
        let window = controller.window!
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump()
        controller.openConnection(nil)
        waitUntil("Connection sheet") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        let fields = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }
        for (label, value) in [("Server", "127.0.0.1"), ("Username", CommandLine.arguments[3]), ("Port", CommandLine.arguments[2])] {
            guard let field = fields.first(where: { $0.accessibilityLabel() == label }) else { fatalError("Missing \(label) field") }
            field.stringValue = value
        }
        sheet.makeFirstResponder(nil)
        guard let connect = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Connect" }) else { fatalError("Missing Connect button") }
        connect.performClick(nil)
        guard let table = descendants(window.contentView!).compactMap({ $0 as? NSTableView }).first else { fatalError("Missing file table") }
        waitUntil("Authenticated file listing") { !controller.busy && table.numberOfRows == 2 }
        let folder = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
        precondition(folder?.stringValue.contains("Empty folder") == true)
        try capture(window)
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-D", "1", "artifacts/verification/authenticated-browser-display.png"]
        try screenshot.run()
        screenshot.waitUntilExit()
        precondition(screenshot.terminationStatus == 0, "Screen capture failed")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openSelected(nil)
        waitUntil("Empty folder navigation") { !controller.busy && table.numberOfRows == 0 }
        controller.goUp(nil)
        waitUntil("Parent navigation") { !controller.busy && table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.downloadSelected(nil)
        waitUntil("Save panel") { window.attachedSheet is NSSavePanel }
        (window.attachedSheet as! NSSavePanel).cancel(nil)
        waitUntil("Save cancellation") { window.attachedSheet == nil }
        precondition(!controller.busy)
        // Native save confirmation cannot be driven by NSSavePanel.ok on this OS.
        // Exercise the same selected-file operation with an explicit destination.
        let destination = root.appendingPathComponent("ui-download.bin")
        controller.retrieveSelection(to: destination)
        waitUntil("UI download") { !controller.busy && FileManager.default.fileExists(atPath: destination.path) }
        let actual = try Data(contentsOf: destination)
        let expected = try Data(contentsOf: root.appendingPathComponent("files/payload.bin"))
        precondition(actual == expected, "UI download must preserve exact bytes")
        // Repeating the download must report the occupied destination, preserve
        // its bytes, and expose the disconnected state consistently.
        controller.retrieveSelection(to: destination)
        waitUntil("Existing destination error") { !controller.busy && window.attachedSheet != nil }
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == expected, "Failed download changed existing file")
        precondition(table.numberOfRows == 0 && window.title == "Retriever", "Failure must clear remote identity and listing")
        let download = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "download" }!
        let open = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "connect" }!
        let errorSheet = window.attachedSheet!
        guard let dismiss = descendants(errorSheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "OK" }) else { fatalError("Missing error dismissal") }
        dismiss.performClick(nil)
        waitUntil("Error dismissal") { window.attachedSheet == nil }
        pump()
        precondition(!download.isEnabled && open.isEnabled, "Failure must allow reconnect and disable download")
        controller.disconnect(nil)
        waitUntil("Disconnect") { !controller.busy && table.numberOfRows == 0 }
        window.performClose(nil)
        print("PASS: authenticated native connection sheet, navigation, save cancellation, exact download, existing-file preservation, error state and disconnect")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private static func pump() {
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    private static func waitUntil(_ reason: String, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { pump() }
        precondition(condition(), "Timed out: \(reason)")
    }
    private static func capture(_ window: NSWindow) throws {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render connected browser") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: "artifacts/verification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("authenticated-browser-content.png"))
    }
}
