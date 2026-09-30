import AppKit
import Quartz
import RetrieverCore

@MainActor
private final class FileNode {
    let entry: RemoteEntry
    let path: Data
    var children: [FileNode]?
    init(_ entry: RemoteEntry, parent: Data) {
        self.entry = entry
        path = SFTPSession.appending(entry.nameBytes, to: parent)
    }
}

@MainActor
private final class FolderDisclosureButton: NSButton {
    weak var outline: NSOutlineView?
    override func draw(_ dirtyRect: NSRect) {
        guard let outline else { return }
        let item = outline.item(atRow: outline.row(for: self))
        let expanded = item.map { outline.isItemExpanded($0) } ?? false
        let symbol = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        if let symbol {
            let scale = min(14 / symbol.size.width, 14 / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

@MainActor
private final class FileOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, window?.attachedSheet == nil else { return nil }
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        return menu
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if identifier == NSOutlineView.disclosureButtonIdentifier {
            let button = FolderDisclosureButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            button.identifier = identifier
            button.outline = self
            button.isBordered = false
            button.target = self
            button.action = #selector(toggleFolder(_:))
            button.setAccessibilityLabel("Expand or collapse folder")
            return button
        }
        return super.makeView(withIdentifier: identifier, owner: owner)
    }
    @objc private func toggleFolder(_ sender: NSButton) {
        guard isEnabled, let item = item(atRow: row(for: sender)) else { return }
        if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
        needsDisplay = true
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        return NSRect(x: frame.midX - 10, y: rect(ofRow: row).midY - 10, width: 20, height: 20)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let browser: SFTPBrowser
    private let history: ConnectionHistory
    private var activeSettings: ConnectionSettings?
    private var connectionSheet: ConnectionSheet?
    private var previewPanel: NSPanel?
    private var previewDirectory: URL?
    private let status = NSTextField(labelWithString: "Not connected")
    private let pathField = NSTextField(labelWithString: "")
    private let table = FileOutlineView()
    private var roots: [FileNode] = []
    private var completingExpansion = false
    private let scroll = NSScrollView()
    private let progress = NSProgressIndicator()
    private let empty = NSTextField(labelWithString: "Open a connection to browse your files.")
    private var directory: RemoteDirectory?
    private var cancellation: SFTPCancellation?
    private(set) var busy = false
    private var afterCleanup: (@MainActor () -> Void)?

    init(browser: SFTPBrowser = SFTPBrowser(askpass: Bundle.main.executableURL), history: ConnectionHistory = ConnectionHistory()) {
        self.browser = browser
        self.history = history
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Retriever"
        window.minSize = NSSize(width: 580, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        let toolbar = NSToolbar(identifier: "Browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        let content = NSView()
        window.contentView = content
        for (id, title, width) in [("name", "Name", 430.0), ("size", "Size", 100.0), ("modified", "Modified", 180.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 180 : 80
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.outlineTableColumn = table.tableColumns.first
        table.indentationPerLevel = 24
        table.rowHeight = 30
        table.controlSize = .large
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel("Remote files")
        let contextMenu = NSMenu()
        for (title, action, symbol) in [
            ("Download", #selector(downloadSelected(_:)), "arrow.down.circle"),
            ("Preview", #selector(previewSelected(_:)), "eye")
        ] {
            let item = contextMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        table.menu = contextMenu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setAccessibilityLabel("Remote directory")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        empty.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        for view in [pathField, scroll, status, empty, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            pathField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -8),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }

    private static let actions: [(String, String, String, Selector)] = [
        ("connect", "Open Connection", "plus.circle", #selector(openConnection(_:))),
        ("up", "Up", "arrow.up", #selector(goUp(_:))),
        ("refresh", "Refresh", "arrow.clockwise", #selector(refresh(_:))),
        ("download", "Download", "arrow.down.circle", #selector(downloadSelected(_:))),
        ("disconnect", "Disconnect", "eject", #selector(disconnect(_:))),
        ("cancel", "Cancel", "xmark.circle", #selector(cancel(_:)))
    ]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.actions.map { .init($0.0) } + [.flexibleSpace]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("connect"), .init("up"), .init("refresh"), .flexibleSpace, .init("download"), .init("disconnect"), .init("cancel")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let definition = Self.actions.first(where: { $0.0 == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = definition.1
        item.toolTip = definition.1
        item.image = NSImage(systemSymbolName: definition.2, accessibilityDescription: definition.1)
        item.target = self
        item.action = definition.3
        item.autovalidates = false
        return item
    }
    private var selectedNode: FileNode? { table.item(atRow: table.selectedRow) as? FileNode }
    private var selected: RemoteEntry? { selectedNode?.entry }
    private func enabled(_ action: Selector?) -> Bool {
        if action == #selector(cancel(_:)) { return busy }
        if busy { return false }
        switch action {
        case #selector(openConnection(_:)): return true
        case #selector(goUp(_:)): return directory != nil && directory?.path != Data("/".utf8)
        case #selector(refresh(_:)), #selector(disconnect(_:)): return directory != nil
        case #selector(downloadSelected(_:)), #selector(previewSelected(_:)): return selected.map { !$0.attributes.isDirectory && !$0.attributes.isSymbolicLink } ?? false
        case #selector(openSelected(_:)): return selected != nil
        default: return false
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled(menuItem.action) }
    private func updateControls() {
        for item in window?.toolbar?.items ?? [] { item.isEnabled = enabled(item.action) }
        table.isEnabled = !busy
        scroll.isHidden = directory == nil
        empty.isHidden = !(directory == nil || directory?.entries.isEmpty == true)
        empty.stringValue = directory == nil ? "Open a connection to browse your files." : "This folder is empty."
        pathField.stringValue = directory.map { String(decoding: $0.path, as: UTF8.self) } ?? ""
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children?.count ?? (item == nil ? roots.count : 0)
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children![index] }
        return roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.entry.attributes.isDirectory && (node.children?.isEmpty != true)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if completingExpansion { return true }
        guard !busy else { return false }
        if node.children != nil { return true }
        runOperation("Loading \(node.entry.name)…") { [self] signal in
            let result = try await browser.directory(node.path, cancellation: signal)
            node.children = result.entries.map { FileNode($0, parent: result.path) }
            table.reloadItem(node, reloadChildren: true)
            completingExpansion = true
            table.expandItem(node)
            completingExpansion = false
            status.stringValue = node.children!.isEmpty ? "\(node.entry.name) is empty." : "\(node.children!.count) items in \(node.entry.name)"
        }
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !busy }
    func outlineViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let entry = node.entry
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "size": value = entry.attributes.isDirectory ? "—" : entry.attributes.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
        case "modified": value = entry.attributes.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        default: value = entry.name.replacingOccurrences(of: "\n", with: "↵")
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        cell.toolTip = entry.name
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: tableColumn?.identifier.rawValue == "name" ? 2 : 0),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    private func runOperation(_ message: String, operation: @escaping @MainActor (SFTPCancellation) async throws -> Void) {
        guard !busy else { return }
        busy = true
        let signal = SFTPCancellation()
        cancellation = signal
        status.stringValue = message
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            do { try await operation(signal) }
            catch {
                activeSettings = nil
                directory = nil
                roots = []
                table.reloadData()
                window?.title = "Retriever"
                if error is CancellationError { status.stringValue = "Cancelled. Disconnected." }
                else {
                    status.stringValue = "Disconnected"
                    if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
                }
            }
            busy = false
            cancellation = nil
            updateControls()
            let completion = afterCleanup
            afterCleanup = nil
            completion?()
        }
    }
    private func show(_ result: RemoteDirectory) {
        directory = result
        roots = result.entries.map { FileNode($0, parent: result.path) }
        if let activeSettings { history.updateLocation(result.path, for: activeSettings) }
        table.deselectAll(nil)
        table.reloadData()
        status.stringValue = "\(result.entries.count) items"
        updateControls()
    }
    private func connect(_ settings: ConnectionSettings, startingAt path: Data?) {
        runOperation("Connecting to \(settings.host)…") { [self] signal in
            let result = try await browser.connect(settings, startingAt: path, cancellation: signal)
            activeSettings = settings
            history.remember(settings, path: result.path)
            show(result)
            if result.usedHomeFallback { status.stringValue = "Previous folder unavailable. Opened your home folder." }
            window?.title = "\(settings.host) — Retriever"
        }
    }
    private func navigate(_ path: Data) {
        runOperation("Loading folder…") { [self] signal in
            show(try await browser.directory(path, cancellation: signal))
        }
    }
    @objc func refresh(_ sender: Any?) { if !busy, let directory { navigate(directory.path) } }
    @objc func goUp(_ sender: Any?) {
        if enabled(#selector(goUp(_:))), let directory { navigate(SFTPSession.appending(Data("..".utf8), to: directory.path)) }
    }
    @objc func openSelected(_ sender: Any?) {
        guard !busy, let node = selectedNode else { return }
        if node.entry.attributes.isDirectory { navigate(node.path) }
        else { downloadSelected(sender) }
    }
    @objc func downloadSelected(_ sender: Any?) {
        guard enabled(#selector(downloadSelected(_:))), let selected, let window else { return }
        let panel = NSSavePanel()
        panel.title = "Download File"
        panel.prompt = "Download"
        panel.nameFieldStringValue = selected.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.retrieveSelection(to: destination)
        }
    }
    func retrieveSelection(to destination: URL) {
        guard enabled(#selector(downloadSelected(_:))), let selected, let node = selectedNode else { return }
        runOperation("Downloading \(selected.name)…") { [self] signal in
            try await browser.download(node.path, to: destination, cancellation: signal) { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, busy, cancellation === signal else { return }
                    let count = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                    status.stringValue = "Downloading \(selected.name) — \(count) received"
                }
            }
            status.stringValue = "Downloaded to \(destination.path)"
        }
    }
    @objc func previewSelected(_ sender: Any?) {
        guard enabled(#selector(previewSelected(_:))), let node = selectedNode else { return }
        runOperation("Preparing preview of \(node.entry.name)…") { [self] signal in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Retriever-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var presented = false
            defer { if !presented { try? FileManager.default.removeItem(at: temporary) } }
            let filename = node.entry.name.replacingOccurrences(of: "/", with: "_")
            let destination = temporary.appendingPathComponent(filename)
            try await browser.download(node.path, to: destination, cancellation: signal) { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, busy, cancellation === signal else { return }
                    let count = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                    status.stringValue = "Preparing preview — \(count) received"
                }
            }
            closePreview()
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = node.entry.name
            panel.minSize = NSSize(width: 360, height: 260)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let preview = QLPreviewView(frame: panel.contentView!.bounds, style: .normal)!
            preview.autoresizingMask = [.width, .height]
            preview.previewItem = destination as NSURL
            panel.contentView = preview
            previewDirectory = temporary
            previewPanel = panel
            presented = true
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            status.stringValue = "Previewing \(node.entry.name)"
        }
    }
    func closePreview() {
        guard let panel = previewPanel else { return }
        previewPanel = nil
        panel.delegate = nil
        (panel.contentView as? QLPreviewView)?.close()
        panel.close()
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
    @objc func cancel(_ sender: Any?) {
        cancellation?.cancel()
        if busy { status.stringValue = "Cancelling…" }
    }
    @objc func disconnect(_ sender: Any?) {
        guard !busy else { return }
        runOperation("Disconnecting…") { [self] _ in
            await browser.disconnect()
            activeSettings = nil
            directory = nil
            roots = []
            table.reloadData()
            window?.title = "Retriever"
            status.stringValue = "Not connected"
        }
    }
    /// Returns true when immediate closing is safe; otherwise resolves the user's
    /// choice and defers the completion until the worker has removed partial files.
    func requestClose(afterCancellation: @escaping @MainActor () -> Void) -> Bool {
        guard busy else { return true }
        guard afterCleanup == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Cancel the current operation and close?"
        alert.informativeText = "The connection will close and any partial download will be removed."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Cancel and Close")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        // A worker completion can arrive while the modal alert runs.
        guard busy else { return true }
        afterCleanup = afterCancellation
        cancel(nil)
        return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === previewPanel { return true }
        return requestClose { [weak sender] in sender?.performClose(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === previewPanel { closePreview(); return }
        closePreview()
        let browser = browser
        Task { await browser.disconnect() }
    }
    @objc func openConnection(_ sender: Any?) {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let sheet = ConnectionSheet(history: history)
        connectionSheet = sheet
        sheet.present(on: window) { [weak self] settings, path in
            guard let self else { return }
            connectionSheet = nil
            if let settings { connect(settings, startingAt: path) }
        }
    }
}
