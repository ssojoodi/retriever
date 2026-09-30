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
        let suite = "RetrieverBrowserChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ConnectionHistory(defaults: defaults)
        let controller = MainWindowController(browser: browser, history: history)
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
        let folder = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        precondition(folder?.textField?.stringValue.contains("Empty folder") == true)
        let outline = table as! NSOutlineView
        let emptyFolder = root.appendingPathComponent("files/Empty folder")
        let nestedFolder = emptyFolder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        let nestedData = Data("Nested file retrieval".utf8)
        try nestedData.write(to: nestedFolder.appendingPathComponent("nested.txt"))
        let rootPath = history.hosts[0].lastPath
        let parentItem = outline.item(atRow: 0)!
        let disclosure = descendants(outline.rowView(atRow: 0, makeIfNecessary: true)!).compactMap { $0 as? NSButton }.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }!
        disclosure.performClick(nil)
        waitUntil("Inline folder expansion") { !controller.busy && outline.numberOfRows == 3 }
        let nestedItem = outline.item(atRow: 1)!
        outline.expandItem(nestedItem)
        waitUntil("Nested expansion") { !controller.busy && outline.numberOfRows == 4 }
        precondition(history.hosts[0].lastPath == rootPath, "Expansion must not change the root location")
        precondition(outline.frameOfOutlineCell(atRow: 0).width >= 20)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let nestedDestination = root.appendingPathComponent("nested-download.txt")
        controller.retrieveSelection(to: nestedDestination)
        waitUntil("Nested file download") { !controller.busy && FileManager.default.fileExists(atPath: nestedDestination.path) }
        let nestedActual = try Data(contentsOf: nestedDestination)
        precondition(nestedActual == nestedData)
        try capture(window)
        try Data(contentsOf: URL(fileURLWithPath: "artifacts/verification/authenticated-browser-content.png")).write(to: URL(fileURLWithPath: "artifacts/verification/expanded-tree.png"))
        disclosure.performClick(nil)
        precondition(outline.numberOfRows == 2)
        outline.expandItem(parentItem)
        precondition(!controller.busy && outline.numberOfRows >= 3, "Loaded folders reopen immediately")
        try FileManager.default.removeItem(at: nestedFolder)
        controller.refresh(nil)
        waitUntil("Refresh resets tree") { !controller.busy && outline.numberOfRows == 2 }
        let refreshedFolder = outline.item(atRow: 0)!
        outline.expandItem(refreshedFolder)
        waitUntil("Empty expansion") { !controller.busy && !outline.isExpandable(refreshedFolder) }
        precondition(outline.numberOfRows == 2)
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
        precondition(history.hosts.count == 1)
        let savedPath = history.hosts[0].lastPath
        precondition(String(decoding: savedPath, as: UTF8.self).hasSuffix("/Empty folder"))
        controller.disconnect(nil)
        waitUntil("Disconnect before reconnect") { !controller.busy && window.title == "Retriever" }
        controller.openConnection(nil)
        waitUntil("Saved host sheet") { window.attachedSheet != nil }
        let savedSheet = window.attachedSheet!
        let controls = descendants(savedSheet.contentView!)
        let savedPicker = controls.compactMap { $0 as? NSPopUpButton }.first!
        precondition(savedPicker.indexOfSelectedItem == 1, "Most recent host must be selected")
        let savedFolder = controls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Remote folder" }!
        precondition(savedFolder.stringValue == String(decoding: savedPath, as: UTF8.self))
        savedPicker.selectItem(at: 0)
        NSApp.sendAction(savedPicker.action!, to: savedPicker.target, from: savedPicker)
        let savedServer = controls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Server" }!
        precondition(savedServer.stringValue.isEmpty && savedFolder.stringValue.isEmpty, "New connection clears saved values")
        savedPicker.selectItem(at: 1)
        NSApp.sendAction(savedPicker.action!, to: savedPicker.target, from: savedPicker)
        savedServer.stringValue = "other-server"
        savedServer.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: savedServer))
        precondition(savedPicker.indexOfSelectedItem == 0 && savedFolder.stringValue.isEmpty, "Changed identity must clear another host's path")
        savedPicker.selectItem(at: 1)
        NSApp.sendAction(savedPicker.action!, to: savedPicker.target, from: savedPicker)
        pump()
        let savedScreenshot = Process()
        savedScreenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        savedScreenshot.arguments = ["-x", "-D", "1", "artifacts/verification/saved-hosts-sheet.png"]
        try savedScreenshot.run()
        savedScreenshot.waitUntilExit()
        precondition(savedScreenshot.terminationStatus == 0)
        controls.compactMap { $0 as? NSButton }.first { $0.title == "Connect" }!.performClick(nil)
        waitUntil("Reconnect to last folder") { !controller.busy && window.title == "127.0.0.1 — Retriever" }
        precondition(table.numberOfRows == 0, "Reconnect should restore the empty folder, not home")
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
        controller.openConnection(nil)
        waitUntil("Forget host sheet") { window.attachedSheet != nil }
        let forgetSheet = window.attachedSheet!
        let forgetControls = descendants(forgetSheet.contentView!)
        forgetControls.compactMap { $0 as? NSButton }.first { $0.title == "Forget" }!.performClick(nil)
        precondition(history.hosts.isEmpty, "Forget must remove persisted host")
        precondition(forgetControls.compactMap { $0 as? NSPopUpButton }.first!.indexOfSelectedItem == 0)
        forgetControls.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        waitUntil("Forget sheet dismissal") { window.attachedSheet == nil }
        window.performClose(nil)
        print("PASS: authenticated native connection sheet, navigation, save cancellation, exact download, existing-file preservation, error state, saved-folder reconnect, forget and disconnect")
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
