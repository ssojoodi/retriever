import AppKit
import Quartz
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
        let downloads = DownloadHistory(defaults: defaults)
        let controller = MainWindowController(browser: browser, history: history, downloads: downloads)
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
        precondition(window.firstResponder === outline, "Disclosure click must return focus to the outline")
        func key(_ code: UInt16, _ characters: String, window target: NSWindow = window) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline.keyDown(with: key(125, "\u{f701}"))
        precondition(outline.selectedRow == 1, "Down arrow must select after expansion")
        outline.keyDown(with: key(124, "\u{f703}"))
        waitUntil("Nested expansion") { !controller.busy && outline.numberOfRows == 4 }
        precondition(history.hosts[0].lastPath == rootPath, "Expansion must not change the root location")
        precondition(outline.frameOfOutlineCell(atRow: 0).width >= 20)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let nestedDestination = root.appendingPathComponent("nested-download.txt")
        controller.retrieveSelection(to: nestedDestination)
        waitUntil("Nested file download") { !controller.busy && FileManager.default.fileExists(atPath: nestedDestination.path) }
        let nestedActual = try Data(contentsOf: nestedDestination)
        precondition(nestedActual == nestedData)
        func contextMenu(row: Int) -> NSMenu? {
            let rect = table.rect(ofRow: row)
            let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = table.menu(for: event)
            menu?.update()
            return menu
        }
        let blankLocation = table.convert(NSPoint(x: 20, y: table.bounds.maxY - 4), to: nil)
        let blankEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: blankLocation, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(table.menu(for: blankEvent) == nil, "Empty space must not act on the prior selection")
        let folderMenu = contextMenu(row: 0)!
        precondition(folderMenu.items.map(\.title) == ["Download", "Preview", "", "SSH into Folder"])
        precondition(folderMenu.items[0].isEnabled && !folderMenu.items[1].isEnabled, "Folders support download but not preview")
        precondition(folderMenu.items.last!.isEnabled, "Folders support SSH")
        precondition(table.allowsMultipleSelection)
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let multiMenu = contextMenu(row: 2)!
        precondition(table.selectedRowIndexes == IndexSet([0, 2]), "Right-click within selection must preserve all selected items")
        precondition(multiMenu.items[0].isEnabled && !multiMenu.items[1].isEnabled && !multiMenu.items.last!.isEnabled,
                     "Multiple items support Download, while Preview and SSH require one item")
        try capture(window)
        try Data(contentsOf: URL(fileURLWithPath: "artifacts/verification/authenticated-browser-content.png")).write(to: URL(fileURLWithPath: "artifacts/verification/multiple-selection.png"))
        _ = contextMenu(row: 3)
        precondition(table.selectedRowIndexes == IndexSet(integer: 3), "Right-click outside selection must select the pointed item")
        let fileMenu = contextMenu(row: 2)!
        precondition(table.selectedRow == 2 && fileMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "Right click must target the pointed file")
        fileMenu.performActionForItem(at: 0)
        waitUntil("Context Download uses save panel") { window.attachedSheet is NSSavePanel }
        (window.attachedSheet as! NSSavePanel).cancel(nil)
        waitUntil("Context save cancellation") { window.attachedSheet == nil }
        table.keyDown(with: key(49, " "))
        precondition(contextMenu(row: 0) == nil, "Busy tree must not retarget a context action")
        waitUntil("Nested Quick Look preview") { !controller.busy && NSApp.windows.contains { $0.title == "nested.txt" && $0.isVisible } }
        let previewPanel = NSApp.windows.first { $0.title == "nested.txt" && $0.isVisible }!
        let preview = previewPanel.contentView as! QLPreviewView
        let previewURL = preview.previewItem.previewItemURL!
        let previewBytes = try Data(contentsOf: previewURL)
        precondition(previewBytes == nestedData, "Preview must fetch the pointed nested file")
        let previewFolder = previewURL.deletingLastPathComponent()
        precondition(history.hosts[0].lastPath == rootPath)
        for _ in 0..<15 { pump() }
        let previewShot = Process()
        previewShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        previewShot.arguments = ["-x", "-D", "1", "artifacts/verification/file-preview.png"]
        try previewShot.run()
        previewShot.waitUntilExit()
        fileMenu.performActionForItem(at: 1)
        waitUntil("Replacement preview") { !controller.busy && !previewPanel.isVisible }
        precondition(!FileManager.default.fileExists(atPath: previewFolder.path), "Replacing preview removes its previous temporary file")
        let replacement = NSApp.windows.first { $0.title == "nested.txt" && $0.isVisible }!
        let replacementURL = (replacement.contentView as! QLPreviewView).previewItem.previewItemURL!
        replacement.sendEvent(key(53, "\u{1b}", window: replacement))
        precondition(!FileManager.default.fileExists(atPath: replacementURL.deletingLastPathComponent().path))
        precondition(!FileManager.default.fileExists(atPath: previewFolder.path), "Closing preview removes temporary files")
        precondition(table.numberOfRows == 4 && window.title == "127.0.0.1 — Retriever", "Closing preview must preserve the connection")
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
        // its bytes, and keep the session and listing usable.
        controller.retrieveSelection(to: destination)
        waitUntil("Existing destination confirmation") { controller.busy && window.attachedSheet != nil }
        for _ in 0..<5 { pump() }
        let conflictShot = Process()
        conflictShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        conflictShot.arguments = ["-x", "-l", String(window.attachedSheet!.windowNumber), "artifacts/verification/transfer-conflict.png"]
        try conflictShot.run()
        conflictShot.waitUntilExit()
        precondition(conflictShot.terminationStatus == 0, "Conflict screenshot failed")
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == expected, "Failed download changed existing file")
        precondition(table.numberOfRows == 2 && window.title == "127.0.0.1 — Retriever", "Local errors must preserve listing and connection")
        let download = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "download" }!
        let open = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "connect" }!
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel Remaining" }!.performClick(nil)
        waitUntil("Download cancellation summary") { !controller.busy && window.attachedSheet != nil }
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        waitUntil("Summary dismissal") { window.attachedSheet == nil }
        pump()
        precondition(download.isEnabled && open.isEnabled, "A recoverable error must permit another download")
        try Data("replace me".utf8).write(to: destination)
        controller.retrieveSelection(to: destination, policy: .replaceApproved)
        waitUntil("Approved replacement") { !controller.busy }
        let replacedBytes = try Data(contentsOf: destination)
        precondition(replacedBytes == expected)
        precondition(downloads.entries.count == 3, "Only successful downloads belong in history")
        controller.showDownloads(nil)
        let downloadsWindow = NSApp.windows.first { $0.title == "Downloads — Retriever" }!
        let historyTable = descendants(downloadsWindow.contentView!).compactMap { $0 as? NSTableView }.first!
        precondition(historyTable.numberOfRows == 3)
        controller.showDownloads(nil)
        precondition(NSApp.windows.filter { $0.title == "Downloads — Retriever" }.count == 1)
        historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(descendants(downloadsWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Show in Finder" }!.isEnabled)
        for _ in 0..<5 { pump() }
        let historyShot = Process()
        historyShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        historyShot.arguments = ["-x", "-l", String(downloadsWindow.windowNumber), "artifacts/verification/downloads-history.png"]
        try historyShot.run()
        historyShot.waitUntilExit()
        precondition(historyShot.terminationStatus == 0)
        descendants(downloadsWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Clear History…" }!.performClick(nil)
        waitUntil("Clear history confirmation") { downloadsWindow.attachedSheet != nil }
        descendants(downloadsWindow.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Clear History" }!.performClick(nil)
        waitUntil("History cleared") { downloads.entries.isEmpty && downloadsWindow.attachedSheet == nil }
        precondition(historyTable.numberOfRows == 0 && FileManager.default.fileExists(atPath: destination.path))
        downloadsWindow.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        let temporary = FileManager.default.temporaryDirectory
        func previewFolders() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("Retriever-preview-") })
        }
        let existingPreviews = try previewFolders()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.previewSelected(nil)
        window.sendEvent(key(53, "\u{1b}"))
        waitUntil("Cancelled preview") { !controller.busy }
        precondition(table.numberOfRows == 2, "Cancellation must preserve cached listing")
        let remainingPreviews = try previewFolders()
        precondition(remainingPreviews == existingPreviews, "Cancellation must remove temporary preview files")
        precondition(!NSApp.windows.contains { $0.isVisible && $0.contentView is QLPreviewView })
        // A genuine transport loss retains the snapshot and offers explicit reconnect.
        var disconnected = false
        Task { await browser.disconnect(); disconnected = true }
        waitUntil("Drop transport") { disconnected }
        controller.refresh(nil)
        waitUntil("Disconnected error") { !controller.busy && window.attachedSheet != nil }
        precondition(table.numberOfRows == 2 && window.title.contains("Disconnected"))
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        waitUntil("Dismiss disconnected error") { window.attachedSheet == nil }
        controller.reconnect(nil)
        waitUntil("Explicit reconnect") { !controller.busy && window.title == "127.0.0.1 — Retriever" }
        // Large previews ask before transferring. A file that grows after listing
        // is also stopped by the streaming limit and asks before retrying.
        let payload = root.appendingPathComponent("files/payload.bin")
        try Data(repeating: 65, count: 1_000_001).write(to: payload)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.previewSelected(nil)
        waitUntil("Grown file preview confirmation") { !controller.busy && window.attachedSheet != nil }
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
        waitUntil("Decline grown preview") { window.attachedSheet == nil }
        controller.refresh(nil)
        waitUntil("Refresh large file") { !controller.busy }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.previewSelected(nil)
        precondition(!controller.busy && window.attachedSheet != nil, "Known large file must ask before transfer")
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Download and Preview" }!.performClick(nil)
        waitUntil("Approved large preview") { !controller.busy && NSApp.windows.contains { $0.isVisible && $0.contentView is QLPreviewView } }
        controller.closePreview()
        precondition(downloads.entries.isEmpty, "Previews must not enter cleared download history")
        controller.uploadSelected(nil)
        waitUntil("Upload picker") { window.attachedSheet is NSOpenPanel }
        let uploadPicker = window.attachedSheet as! NSOpenPanel
        precondition(uploadPicker.allowsMultipleSelection && uploadPicker.canChooseFiles && uploadPicker.canChooseDirectories,
                     "Upload picker must accept multiple files and folders")
        uploadPicker.cancel(nil)
        waitUntil("Upload picker cancellation") { window.attachedSheet == nil }
        precondition(!controller.busy)
        let cancelledSource = root.appendingPathComponent("cancel-upload.bin")
        try Data(repeating: 9, count: 1_000_000).write(to: cancelledSource)
        controller.uploadFile(cancelledSource)
        controller.cancel(nil)
        waitUntil("Cancelled upload") { !controller.busy }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("files/cancel-upload.bin").path))
        precondition(table.numberOfRows == 2)
        if let sheet = window.attachedSheet {
            descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
            waitUntil("Dismiss cancelled upload warning") { window.attachedSheet == nil }
        }
        let reconnect = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "reconnect" }!
        if reconnect.isEnabled {
            controller.reconnect(nil)
            waitUntil("Reconnect after cancelled upload") { !controller.busy }
        }
        let uploadSource = root.appendingPathComponent("upload-test.txt")
        let uploadTarget = root.appendingPathComponent("files/upload-test.txt")
        let uploadBytes = Data("Uploaded with Retriever.".utf8)
        try uploadBytes.write(to: uploadSource)
        controller.uploadFile(uploadSource)
        waitUntil("Upload and refreshed listing") { !controller.busy }
        let uploadResult = try Data(contentsOf: uploadTarget)
        precondition(uploadResult == uploadBytes && table.numberOfRows == 3)
        precondition(table.selectedRow >= 0 && window.firstResponder === table)
        try Data("replacement upload".utf8).write(to: uploadSource)
        controller.uploadFile(uploadSource)
        waitUntil("Remote replacement confirmation") { controller.busy && window.attachedSheet != nil }
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel Remaining" }!.performClick(nil)
        waitUntil("Upload cancellation summary") { !controller.busy && window.attachedSheet != nil }
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        waitUntil("Decline remote replacement") { window.attachedSheet == nil }
        let unchangedUpload = try Data(contentsOf: uploadTarget)
        precondition(unchangedUpload == uploadBytes)
        controller.uploadFile(uploadSource)
        waitUntil("Second replacement confirmation") { controller.busy && window.attachedSheet != nil }
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Replace" }!.performClick(nil)
        waitUntil("Approved upload replacement") { window.attachedSheet == nil && !controller.busy && (try? Data(contentsOf: uploadTarget)) == Data("replacement upload".utf8) }
        let replacedUpload = try Data(contentsOf: uploadTarget)
        precondition(replacedUpload == Data("replacement upload".utf8))
        precondition(downloads.entries.isEmpty, "Uploads must not enter download history")
        for _ in 0..<5 { pump() }
        let uploadShot = Process()
        uploadShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        uploadShot.arguments = ["-x", "-l", String(window.windowNumber), "artifacts/verification/upload-browser.png"]
        try uploadShot.run()
        uploadShot.waitUntilExit()
        precondition(uploadShot.terminationStatus == 0)
        print("PASS: native upload picker cancellation, upload, refreshed selection, replacement approval and rejection")
        // The same batch path powers pickers and native file-promise fulfillment.
        let uploadTree = root.appendingPathComponent("Batch folder")
        try FileManager.default.createDirectory(at: uploadTree.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        let batchBytes = Data("Recursive batch transfer".utf8)
        try batchBytes.write(to: uploadTree.appendingPathComponent("Nested/inside.txt"))
        let batchFile = root.appendingPathComponent("batch-file.txt")
        try batchBytes.write(to: batchFile)
        controller.uploadFiles([uploadTree, batchFile])
        waitUntil("Recursive multi-item upload") { !controller.busy }
        precondition(window.attachedSheet == nil, "Successful recursive upload should not show an error")
        let remoteTree = root.appendingPathComponent("files/Batch folder")
        precondition(FileManager.default.fileExists(atPath: remoteTree.appendingPathComponent("Nested/Empty").path))
        precondition(tryBytes(remoteTree.appendingPathComponent("Nested/inside.txt")) == batchBytes)
        func row(named name: String) -> Int {
            (0..<table.numberOfRows).first { row in
                (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == name
            }!
        }
        let treeRow = row(named: "Batch folder")
        let batchRow = row(named: "batch-file.txt")
        table.selectRowIndexes(IndexSet([treeRow, batchRow]), byExtendingSelection: false)
        controller.downloadSelected(nil)
        waitUntil("Multi-download destination picker") { window.attachedSheet is NSOpenPanel }
        let destinationPicker = window.attachedSheet as! NSOpenPanel
        precondition(destinationPicker.canChooseDirectories && !destinationPicker.canChooseFiles)
        destinationPicker.cancel(nil)
        waitUntil("Multi-download picker cancellation") { window.attachedSheet == nil }
        let batchDestination = root.appendingPathComponent("batch-download")
        try FileManager.default.createDirectory(at: batchDestination, withIntermediateDirectories: false)
        controller.retrieveSelections(to: batchDestination)
        waitUntil("Recursive multi-item download") { !controller.busy }
        precondition(window.attachedSheet == nil)
        precondition(tryBytes(batchDestination.appendingPathComponent("Batch folder/Nested/inside.txt")) == batchBytes)
        precondition(FileManager.default.fileExists(atPath: batchDestination.appendingPathComponent("Batch folder/Nested/Empty").path))
        precondition(tryBytes(batchDestination.appendingPathComponent("batch-file.txt")) == batchBytes)
        precondition(downloads.entries.count == 2, "Every completed file, but not a folder, belongs in history")
        let promiseDestination = root.appendingPathComponent("promised-download")
        try FileManager.default.createDirectory(at: promiseDestination, withIntermediateDirectories: false)
        let treePromise = controller.outlineView(outline, pasteboardWriterForItem: outline.item(atRow: treeRow)!) as! RemoteFilePromise
        let filePromise = controller.outlineView(outline, pasteboardWriterForItem: outline.item(atRow: batchRow)!) as! RemoteFilePromise
        var promiseResults: [Error?] = []
        treePromise.filePromiseProvider(treePromise, writePromiseTo: promiseDestination.appendingPathComponent("Batch folder")) { error in
            Task { @MainActor in promiseResults.append(error) }
        }
        waitUntil("First delayed promise finishes") { promiseResults.count == 1 && !controller.busy }
        precondition(window.attachedSheet == nil, "A drag group must not present results before remaining promises arrive")
        filePromise.filePromiseProvider(filePromise, writePromiseTo: promiseDestination.appendingPathComponent("batch-file.txt")) { error in
            Task { @MainActor in promiseResults.append(error) }
        }
        waitUntil("Sequential folder and file promises") { promiseResults.count == 2 && !controller.busy }
        precondition(promiseResults.allSatisfy { $0 == nil }, "Every promise must finish without errors")
        precondition(tryBytes(promiseDestination.appendingPathComponent("Batch folder/Nested/inside.txt")) == batchBytes)
        precondition(tryBytes(promiseDestination.appendingPathComponent("batch-file.txt")) == batchBytes)
        precondition(FileManager.default.fileExists(atPath: promiseDestination.appendingPathComponent("Batch folder/Nested/Empty").path))
        precondition(downloads.entries.count == 4)
        controller.finishFileDrag(operation: .copy)
        // Finder may request the next item only after the first completion returns.
        // Remember "Skip remaining" across that idle gap and delay the results sheet.
        let uploadRow = row(named: "upload-test.txt")
        table.selectRowIndexes(IndexSet([batchRow, uploadRow]), byExtendingSelection: false)
        let skipFirst = controller.outlineView(outline, pasteboardWriterForItem: outline.item(atRow: batchRow)!) as! RemoteFilePromise
        let skipSecond = controller.outlineView(outline, pasteboardWriterForItem: outline.item(atRow: uploadRow)!) as! RemoteFilePromise
        controller.finishFileDrag(operation: .copy)
        let conflictDestination = root.appendingPathComponent("promise-conflicts")
        try FileManager.default.createDirectory(at: conflictDestination, withIntermediateDirectories: false)
        let originalConflictBytes = Data("Keep these existing bytes".utf8)
        let firstConflict = conflictDestination.appendingPathComponent("batch-file.txt")
        let secondConflict = conflictDestination.appendingPathComponent("upload-test.txt")
        try originalConflictBytes.write(to: firstConflict)
        try originalConflictBytes.write(to: secondConflict)
        var skippedResults: [Error?] = []
        skipFirst.filePromiseProvider(skipFirst, writePromiseTo: firstConflict) { error in
            Task { @MainActor in skippedResults.append(error) }
        }
        waitUntil("First promise conflict") { controller.busy && window.attachedSheet != nil }
        let conflictControls = descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
        conflictControls.first { $0.title == "Apply to remaining file conflicts" }!.state = .on
        conflictControls.first { $0.title == "Skip" }!.performClick(nil)
        waitUntil("First skipped promise returns idle") { skippedResults.count == 1 && !controller.busy }
        precondition(window.attachedSheet == nil, "Skipped first item must not show an early results sheet")
        skipSecond.filePromiseProvider(skipSecond, writePromiseTo: secondConflict) { error in
            Task { @MainActor in skippedResults.append(error) }
        }
        waitUntil("Delayed second promise reuses conflict choice") { skippedResults.count == 2 && !controller.busy }
        precondition(skippedResults.allSatisfy { $0 != nil }, "Skipped promises must report unsuccessful fulfillment")
        precondition(tryBytes(firstConflict) == originalConflictBytes && tryBytes(secondConflict) == originalConflictBytes)
        precondition(downloads.entries.count == 4, "Skipped items must not enter history")
        waitUntil("Drag group final results") { window.attachedSheet != nil }
        let resultControls = descendants(window.attachedSheet!.contentView!)
        precondition(resultControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("2 skipped") },
                     "One final results sheet must summarize both skipped promises")
        resultControls.compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        waitUntil("Dismiss drag results") { window.attachedSheet == nil }
        outline.expandItem(outline.item(atRow: treeRow))
        waitUntil("Show recursive uploaded folder") { !controller.busy && outline.isItemExpanded(outline.item(atRow: treeRow)) }
        let nestedRow = row(named: "Nested")
        outline.expandItem(outline.item(atRow: nestedRow))
        waitUntil("Show recursive upload contents") { !controller.busy && outline.isItemExpanded(outline.item(atRow: nestedRow)) }
        try capture(window)
        try Data(contentsOf: URL(fileURLWithPath: "artifacts/verification/authenticated-browser-content.png")).write(to: URL(fileURLWithPath: "artifacts/verification/recursive-transfers.png"))
        print("PASS: multiple selection, recursive batches, empty folders, delayed file promises and retained conflict decisions")
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

    private static func tryBytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

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
