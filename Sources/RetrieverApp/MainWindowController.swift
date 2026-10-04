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
    var preview: (() -> Void)?
    var canOpenMenu: (() -> Bool)?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !event.isARepeat { preview?() }
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, canOpenMenu?() != false, window?.attachedSheet == nil else { return nil }
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else { return nil }
        if !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
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
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        return NSRect(x: frame.midX - 10, y: rect(ofRow: row).midY - 10, width: 20, height: 20)
    }
}

@MainActor
private final class PreviewPanel: NSPanel {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil { escape?(); return }
        super.sendEvent(event)
    }
}

@MainActor
private final class BrowserWindow: NSWindow {
    var cancelPreview: (() -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, cancelPreview?() == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let browser: SFTPBrowser
    private let history: ConnectionHistory
    private let downloads: DownloadHistory
    private let sshTerminal: SSHTerminalViewController
    private var downloadsWindow: DownloadsWindowController?
    private var connected = false
    private var preparingPreview = false
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
    private var showingTerminal = false
    private let paneSwitch = NSSegmentedControl(labels: ["Files", "Terminal"], trackingMode: .selectOne, target: nil, action: nil)
    private let closeTerminal = NSButton(title: "Close Terminal", target: nil, action: nil)
    private let syncLabel = NSTextField(labelWithString: "")
    private var pendingShellDirectory: (Data, ConnectionSettings)?
    private var connectionGeneration = UUID()
    private var pendingPromises: [PendingPromise] = []
    private var activePromiseGroup: PromiseGroup?
    private var preparedPromiseGroup: PromiseGroup?
    private var applyFileConflict: TransferDecision?
    private var conflictAlert: NSAlert?

    private final class PromiseGroup {
        let generation: UUID
        let settings: ConnectionSettings
        var cancelled = false
        var fileConflict: TransferDecision?
        var expectedPaths = Set<Data>()
        var completedPaths = Set<Data>()
        var items: [TransferItem] = []
        var summary = TransferSummary()
        var resultsShown = false
        init(generation: UUID, settings: ConnectionSettings) { self.generation = generation; self.settings = settings }
    }
    private struct PendingPromise {
        let item: TransferItem
        let group: PromiseGroup
        let completion: @Sendable (Error?) -> Void
    }
    private let progress = NSProgressIndicator()
    private let empty = NSTextField(labelWithString: "Open a connection to browse your files.")
    private var directory: RemoteDirectory?
    private var cancellation: SFTPCancellation?
    private(set) var busy = false
    private var afterCleanup: (@MainActor () -> Void)?

    init(browser: SFTPBrowser = SFTPBrowser(askpass: Bundle.main.executableURL), history: ConnectionHistory = ConnectionHistory(), downloads: DownloadHistory = DownloadHistory(), sshTerminal: SSHTerminalViewController = SSHTerminalViewController()) {
        self.sshTerminal = sshTerminal
        self.browser = browser
        self.history = history
        self.downloads = downloads
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Retriever"
        window.minSize = NSSize(width: 580, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.cancelPreview = { [weak self] in
            guard let self, preparingPreview, busy else { return false }
            cancel(nil)
            return true
        }
        table.preview = { [weak self] in self?.previewSelected(nil) }
        table.canOpenMenu = { [weak self] in self?.busy == false }
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
        table.allowsMultipleSelection = true
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
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
        contextMenu.addItem(.separator())
        let sshItem = contextMenu.addItem(withTitle: "SSH into Folder", action: #selector(sshIntoFolder(_:)), keyEquivalent: "")
        sshItem.target = self
        sshItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
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
        paneSwitch.target = self
        paneSwitch.action = #selector(switchPane(_:))
        paneSwitch.selectedSegment = 0
        closeTerminal.target = self
        closeTerminal.action = #selector(endTerminal(_:))
        closeTerminal.bezelStyle = .rounded
        syncLabel.font = .systemFont(ofSize: 11)
        syncLabel.textColor = .secondaryLabelColor
        syncLabel.lineBreakMode = .byTruncatingTail
        syncLabel.isHidden = true
        let header = NSStackView(views: [pathField, paneSwitch, closeTerminal])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [header, scroll, status, empty, progress, sshTerminal.view, syncLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            sshTerminal.view.topAnchor.constraint(equalTo: scroll.topAnchor),
            sshTerminal.view.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            sshTerminal.view.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            sshTerminal.view.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -8),
            syncLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            syncLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            syncLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        sshTerminal.onSessionClosed = { [weak self] in
            guard let self else { return }
            pendingShellDirectory = nil
            let wasVisible = showingTerminal
            showingTerminal = false
            updateControls()
            if wasVisible { self.window?.makeFirstResponder(table) }
        }
        sshTerminal.onDirectoryChange = { [weak self] path, settings in
            guard let self, UserDefaults.standard.bool(forKey: "syncFolders.v1"), connected, activeSettings == settings else { return }
            pendingShellDirectory = (path, settings)
            applyPendingShellDirectory()
        }
        sshTerminal.onSyncStatus = { [weak self] message in
            self?.syncLabel.stringValue = message ?? ""
            self?.updateControls()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(syncPreferenceChanged), name: .retrieverSyncPreferenceChanged, object: nil)
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }

    @objc private func syncPreferenceChanged() {
        pendingShellDirectory = nil
        sshTerminal.setSyncEnabled(UserDefaults.standard.bool(forKey: "syncFolders.v1"))
    }
    private static let actions: [(String, String, String, Selector)] = [
        ("connect", "Open Connection", "plus.circle", #selector(openConnection(_:))),
        ("reconnect", "Reconnect", "arrow.triangle.2.circlepath", #selector(reconnect(_:))),
        ("history", "Downloads", "clock.arrow.circlepath", #selector(showDownloads(_:))),
        ("up", "Up", "arrow.up", #selector(goUp(_:))),
        ("refresh", "Refresh", "arrow.clockwise", #selector(refresh(_:))),
        ("upload", "Upload", "arrow.up.circle", #selector(uploadSelected(_:))),
        ("download", "Download", "arrow.down.circle", #selector(downloadSelected(_:))),
        ("disconnect", "Disconnect", "eject", #selector(disconnect(_:))),
        ("cancel", "Cancel", "xmark.circle", #selector(cancel(_:)))
    ]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.actions.map { .init($0.0) } + [.flexibleSpace]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("connect"), .init("reconnect"), .init("up"), .init("refresh"), .flexibleSpace, .init("upload"), .init("download"), .init("history"), .init("disconnect"), .init("cancel")]
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
    private var selectedNodes: [FileNode] { table.selectedRowIndexes.compactMap { table.item(atRow: $0) as? FileNode } }
    private var selectedNode: FileNode? { table.item(atRow: table.selectedRow) as? FileNode }
    private var selected: RemoteEntry? { selectedNode?.entry }
    private func enabled(_ action: Selector?) -> Bool {
        if action == #selector(cancel(_:)) { return busy }
        if action == #selector(endTerminal(_:)) { return sshTerminal.terminal != nil }
        if action == #selector(showDownloads(_:)) { return true }
        if showingTerminal && action != #selector(openConnection(_:)) && action != #selector(disconnect(_:)) { return false }
        if busy { return false }
        if action == #selector(disconnect(_:)) { return connected || sshTerminal.terminal != nil }
        if action == #selector(reconnect(_:)) { return !connected && activeSettings != nil }
        if action != #selector(openConnection(_:)) && !connected { return false }
        switch action {
        case #selector(openConnection(_:)): return true
        case #selector(goUp(_:)): return directory != nil && directory?.path != Data("/".utf8)
        case #selector(refresh(_:)), #selector(disconnect(_:)), #selector(uploadSelected(_:)): return directory != nil
        case #selector(downloadSelected(_:)): return !selectedNodes.isEmpty && selectedNodes.contains { !$0.entry.attributes.isSymbolicLink }
        case #selector(previewSelected(_:)): return selectedNodes.count == 1 && (selected.map { !$0.attributes.isDirectory && !$0.attributes.isSymbolicLink } ?? false)
        case #selector(sshIntoFolder(_:)): return selectedNodes.count == 1 && (selected.map { !$0.attributes.isSymbolicLink && ($0.attributes.isDirectory || $0.attributes.permissions.map { $0 & 0xF000 == 0x8000 } == true) } ?? false)
        case #selector(openSelected(_:)): return selectedNodes.count == 1
        default: return false
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { window?.attachedSheet == nil && enabled(menuItem.action) }
    private func updateControls() {
        for item in window?.toolbar?.items ?? [] { item.isEnabled = enabled(item.action) }
        table.isEnabled = true
        scroll.isHidden = showingTerminal || directory == nil
        empty.isHidden = showingTerminal || !(directory == nil || directory?.entries.isEmpty == true)
        empty.stringValue = directory == nil ? "Open a connection to browse your files." : "This folder is empty."
        pathField.stringValue = directory.map { String(decoding: $0.path, as: UTF8.self) } ?? ""
        sshTerminal.view.isHidden = !showingTerminal
        paneSwitch.isHidden = sshTerminal.terminal == nil
        closeTerminal.isHidden = sshTerminal.terminal == nil || sshTerminal.active
        syncLabel.isHidden = !showingTerminal || syncLabel.stringValue.isEmpty || busy
        status.isHidden = !syncLabel.isHidden
        paneSwitch.selectedSegment = showingTerminal ? 1 : 0
        if showingTerminal { pathField.stringValue = sshTerminal.sessionTitle }
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
        if node.children != nil { return true }
        guard !busy, connected else { return false }
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
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { true }
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
            do { try await operation(signal); cancellation = nil }
            catch {
                cancellation = nil
                connected = await browser.isConnected
                let suffix = connected ? "" : (activeSettings == nil ? " Open Connection to try again." : " Disconnected — use Reconnect to continue.")
                if error is CancellationError { status.stringValue = "Cancelled." + suffix }
                else {
                    status.stringValue = "Operation failed." + suffix
                    if let window {
                        // A failed remote cleanup must remain visible even when
                        // the user requested cancellation as part of quitting.
                        let closeAfterAcknowledgement = afterCleanup
                        afterCleanup = nil
                        NSAlert(error: error).beginSheetModal(for: window) { [weak self] _ in
                            self?.updateControls()
                            closeAfterAcknowledgement?()
                        }
                    }
                }
            }
            connected = await browser.isConnected
            sshTerminal.setBrowserConnection(connected ? activeSettings : nil)
            if !connected, directory != nil {
                window?.title = "\(activeSettings?.host ?? "Server") — Disconnected — Retriever"
            }
            preparingPreview = false
            busy = false
            activePromiseGroup = nil
            cancellation = nil
            updateControls()
            let completion = afterCleanup
            afterCleanup = nil
            completion?()
            if completion == nil {
                startPendingPromises()
                applyPendingShellDirectory()
            }
        }
    }
    private func show(_ result: RemoteDirectory) {
        let selectedPaths = Set(selectedNodes.map(\.path))
        let sameFolder = directory?.path == result.path
        directory = result
        roots = result.entries.map { FileNode($0, parent: result.path) }
        if let activeSettings { history.updateLocation(result.path, for: activeSettings) }
        table.deselectAll(nil)
        table.reloadData()
        if sameFolder {
            let rows = IndexSet((0..<table.numberOfRows).filter { row in
                (table.item(atRow: row) as? FileNode).map { selectedPaths.contains($0.path) } ?? false
            })
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }
        if window?.isKeyWindow == true, window?.attachedSheet == nil, window?.firstResponder === window || window?.firstResponder == nil { window?.makeFirstResponder(showingTerminal ? sshTerminal.terminal : table) }
        status.stringValue = "\(result.entries.count) items"
        updateControls()
    }
    private func connect(_ settings: ConnectionSettings, startingAt path: Data?) {
        let expanded = settings == activeSettings && path == directory?.path ? expandedPaths : []
        let selection = selectedNode?.path
        pendingShellDirectory = nil
        connectionGeneration = UUID()
        sshTerminal.setBrowserConnection(nil)
        runOperation("Connecting to \(settings.host)…") { [self] signal in
            let result = try await browser.connect(settings, startingAt: path, cancellation: signal)
            connected = true
            activeSettings = settings
            sshTerminal.setBrowserConnection(settings)
            history.remember(settings, path: result.path)
            show(result)
            window?.title = "\(settings.host) — Retriever"
            try await restoreExpanded(expanded, selection: selection, signal: signal)
            if result.usedHomeFallback { status.stringValue = "Previous folder unavailable. Opened your home folder." }
        }
    }
    private var expandedPaths: [Data] {
        (0..<table.numberOfRows).compactMap { row in
            guard let node = table.item(atRow: row) as? FileNode, table.isItemExpanded(node) else { return nil }
            return node.path
        }
    }
    private func restoreExpanded(_ paths: [Data], selection: Data?, signal: SFTPCancellation) async throws {
        for path in paths {
            guard let node = (0..<table.numberOfRows).compactMap({ table.item(atRow: $0) as? FileNode }).first(where: { $0.path == path && $0.entry.attributes.isDirectory }) else { continue }
            do {
                let result = try await browser.directory(path, cancellation: signal)
                node.children = result.entries.map { FileNode($0, parent: result.path) }
                table.reloadItem(node, reloadChildren: true)
                completingExpansion = true
                table.expandItem(node)
                completingExpansion = false
            } catch SFTPError.server(let code, _) where code != 6 && code != 7 {
                // A removed or inaccessible child must not discard a refreshed root.
                continue
            }
        }
        if let selection, let row = (0..<table.numberOfRows).first(where: { (table.item(atRow: $0) as? FileNode)?.path == selection }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    private func navigate(_ path: Data, fromTerminal: Bool = false) {
        let expanded = path == directory?.path ? expandedPaths : []
        let selection = selectedNode?.path
        runOperation("Loading folder…") { [self] signal in
            show(try await browser.directory(path, cancellation: signal))
            try await restoreExpanded(expanded, selection: selection, signal: signal)
            if !fromTerminal, let actual = directory?.path, let settings = activeSettings {
                pendingShellDirectory = nil
                sshTerminal.synchronizeDirectory(actual, settings: settings)
            }
        }
    }
    private func applyPendingShellDirectory() {
        guard !busy, window?.attachedSheet == nil, let (path, settings) = pendingShellDirectory else { return }
        pendingShellDirectory = nil
        guard connected, activeSettings == settings, UserDefaults.standard.bool(forKey: "syncFolders.v1"), path != directory?.path else { return }
        navigate(path, fromTerminal: true)
    }
    @objc func refresh(_ sender: Any?) { if enabled(#selector(refresh(_:))), let directory { navigate(directory.path) } }
    @objc func goUp(_ sender: Any?) {
        if enabled(#selector(goUp(_:))), let directory { navigate(SFTPSession.appending(Data("..".utf8), to: directory.path)) }
    }
    @objc func openSelected(_ sender: Any?) {
        guard enabled(#selector(openSelected(_:))), let node = selectedNode else { return }
        if node.entry.attributes.isDirectory { navigate(node.path) }
        else { downloadSelected(sender) }
    }
    @objc func sshIntoFolder(_ sender: Any?) {
        guard window?.attachedSheet == nil, enabled(#selector(sshIntoFolder(_:))), let node = selectedNode, let settings = activeSettings else { return }
        do {
            let request = try SSHLaunchRequest(settings: settings, path: node.path, isDirectory: node.entry.attributes.isDirectory, syncEnabled: UserDefaults.standard.bool(forKey: "syncFolders.v1"))
            if sshTerminal.open(request) { showTerminalPane(true) }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
        }
    }
    func showTerminalPane(_ show: Bool) {
        showingTerminal = show
        updateControls()
        window?.makeFirstResponder(show ? sshTerminal.terminal : table)
    }
    @objc private func switchPane(_ sender: NSSegmentedControl) {
        showTerminalPane(sender.selectedSegment == 1)
    }
    @objc func endTerminal(_ sender: Any?) {
        guard sshTerminal.confirmEndingSession() else { return }
        pendingShellDirectory = nil
        sshTerminal.closeSession()
        showTerminalPane(false)
    }
    func confirmTerminalQuit() -> Bool { sshTerminal.confirmEndingSession("End the SSH session and quit Retriever?") }
    func stopTerminal() { sshTerminal.stop() }

    @objc func uploadSelected(_ sender: Any?) {
        guard window?.attachedSheet == nil, enabled(#selector(uploadSelected(_:))), let directory, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload Files and Folders"
        panel.prompt = "Upload"
        panel.message = "Upload to \(String(decoding: directory.path, as: UTF8.self))"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { applyPendingShellDirectory() }
            guard response == .OK else { return }
            uploadFiles(panel.urls, to: directory.path)
        }
    }
    // Pickers, drag-and-drop and integration checks share one transfer path.
    func uploadFile(_ source: URL) { uploadFiles([source]) }
    func uploadFiles(_ sources: [URL], to folder: Data? = nil) {
        guard !busy, connected, !sources.isEmpty, let destination = folder ?? directory?.path else { return }
        let items = sources.map { source in
            TransferItem(remotePath: SFTPSession.appending(Data(source.lastPathComponent.utf8), to: destination), localURL: source,
                         isDirectory: (try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false)
        }
        startTransfer(items, direction: .upload)
    }
    @objc func downloadSelected(_ sender: Any?) {
        guard window?.attachedSheet == nil, enabled(#selector(downloadSelected(_:))), let window else { return }
        let nodes = selectedNodes
        if nodes.count == 1, let node = nodes.first, !node.entry.attributes.isDirectory {
            let panel = NSSavePanel()
            panel.title = "Download File"
            panel.prompt = "Download"
            panel.nameFieldStringValue = node.entry.name
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                defer { applyPendingShellDirectory() }
                guard response == .OK, let destination = panel.url else { return }
                let approved = FileManager.default.fileExists(atPath: destination.path)
                startTransfer([transferItem(node, to: destination)], direction: .download, approvedDestination: approved ? destination : nil)
            }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Download Files and Folders"
            panel.prompt = "Download Here"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                defer { applyPendingShellDirectory() }
                guard response == .OK, let destination = panel.url else { return }
                startTransfer(nodes.map { transferItem($0, to: destination.appendingPathComponent($0.entry.name), automaticName: true) }, direction: .download)
            }
        }
    }
    private func transferItem(_ node: FileNode, to destination: URL, automaticName: Bool = false) -> TransferItem {
        let invalidName = automaticName && String(data: node.entry.nameBytes, encoding: .utf8) == nil
        return TransferItem(remotePath: node.path, localURL: destination, isDirectory: node.entry.attributes.isDirectory,
                            validationError: invalidName ? .invalidName : nil)
    }
    func retrieveSelection(to destination: URL, policy: DownloadDestinationPolicy = .exclusive) {
        guard enabled(#selector(downloadSelected(_:))), let node = selectedNode else { return }
        startTransfer([transferItem(node, to: destination)], direction: .download, approvedDestination: policy == .replaceApproved ? destination : nil)
    }
    func retrieveSelections(to folder: URL) {
        guard enabled(#selector(downloadSelected(_:))) else { return }
        startTransfer(selectedNodes.map { transferItem($0, to: folder.appendingPathComponent($0.entry.name), automaticName: true) }, direction: .download)
    }
    private func decideConflict(_ conflict: TransferConflict, approvedDestination: URL? = nil) async -> TransferDecision {
        if conflict.kind == .file {
            if conflict.item.localURL == approvedDestination { return .replace }
            if let applyFileConflict { return applyFileConflict }
        }
        guard let window, afterCleanup == nil else { return .cancel }
        do { try cancellation?.check() } catch { return .cancel }
        let folder = conflict.kind == .folder
        let name = conflict.item.localURL.lastPathComponent
        let alert = NSAlert()
        alert.messageText = folder ? "Merge “\(name)”?" : "Replace “\(name)”?"
        alert.informativeText = folder
            ? "This destination folder already exists. Merge adds its contents and preserves unrelated files. Conflicting files need separate replacement approval."
            : "A file with this name already exists at the destination. Replace it, skip this file, or cancel the remaining transfers."
        alert.addButton(withTitle: "Cancel Remaining")
        alert.addButton(withTitle: folder ? "Merge" : "Replace")
        alert.addButton(withTitle: folder ? "Skip Folder" : "Skip")
        alert.showsSuppressionButton = !folder
        alert.suppressionButton?.title = "Apply to remaining file conflicts"
        conflictAlert = alert
        let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        conflictAlert = nil
        let decision: TransferDecision = result == .alertSecondButtonReturn ? (folder ? .merge : .replace) : result == .alertThirdButtonReturn ? .skip : .cancel
        if !folder, alert.suppressionButton?.state == .on, decision != .cancel {
            applyFileConflict = decision
            activePromiseGroup?.fileConflict = decision
        }
        return decision
    }
    private func performTransfer(_ items: [TransferItem], direction: TransferDirection, settings: ConnectionSettings, signal: SFTPCancellation, approvedDestination: URL? = nil) async -> TransferSummary {
        let action = direction == .upload ? "Uploading" : "Downloading"
        return await TransferCoordinator(browser: browser).run(items, direction: direction, cancellation: signal,
            conflict: { [weak self] in await self?.decideConflict($0, approvedDestination: approvedDestination) ?? .cancel },
            progress: { [weak self] value in
                guard let self, cancellation === signal else { return }
                let count = ByteCountFormatter.string(fromByteCount: Int64(clamping: value.bytes), countStyle: .file)
                status.stringValue = "\(action) file \(value.completedFiles + 1) — \(value.item.localURL.lastPathComponent) — \(count)"
            }, didDownload: { [weak self] item, bytes in
                self?.downloads.record(filename: item.localURL.lastPathComponent, settings: settings, remotePath: item.remotePath, destination: item.localURL, byteCount: bytes)
            })
    }
    private func startTransfer(_ items: [TransferItem], direction: TransferDirection, approvedDestination: URL? = nil) {
        guard !busy, connected, !items.isEmpty, let settings = activeSettings else { return }
        applyFileConflict = nil
        let visibleFolder = directory?.path
        let expanded = expandedPaths
        runOperation(direction == .upload ? "Preparing upload…" : "Preparing download…") { [self] signal in
            let summary = await performTransfer(items, direction: direction, settings: settings, signal: signal, approvedDestination: approvedDestination)
            if direction == .upload, !summary.cancelled, !summary.connectionLost, afterCleanup == nil, await browser.isConnected, let visibleFolder {
                // Refresh errors must not turn successful publications into failures.
                if let result = try? await browser.directory(visibleFolder, cancellation: signal) {
                    show(result)
                    try? await restoreExpanded(expanded, selection: items.last?.remotePath, signal: signal)
                }
            }
            showTransferSummary(summary, direction: direction, items: items)
            if window?.attachedSheet == nil { window?.makeFirstResponder(showingTerminal ? sshTerminal.terminal : table) }
        }
    }
    private func showTransferSummary(_ summary: TransferSummary, direction: TransferDirection, items: [TransferItem]) {
        let completed = direction == .upload ? "Uploaded" : "Downloaded"
        if !summary.cancelled, summary.failures.isEmpty, summary.skippedItems == 0, items.count == 1, items.first?.isDirectory == false {
            status.stringValue = "\(completed) \(items[0].localURL.lastPathComponent)"
        } else {
            status.stringValue = "\(completed) \(summary.completedFiles) files; \(summary.skippedItems) skipped; \(summary.failures.count) failed." + (summary.cancelled ? " Remaining transfers cancelled." : "")
        }
        guard !summary.failures.isEmpty || summary.skippedItems > 0 || summary.cancelled else { return }
        guard let window, afterCleanup == nil else { return }
        let alert = NSAlert()
        alert.messageText = summary.cancelled ? "Transfer cancelled" : "Transfer results"
        var details = [status.stringValue, "Completed files and created folders remain at the destination."]
        details += summary.failures.prefix(10).map { "\($0.item.localURL.lastPathComponent): \($0.error.localizedDescription)" }
        if summary.connectionLost { details.append("The connection was lost. Reconnect before starting another transfer.") }
        alert.informativeText = details.joined(separator: "\n")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.updateControls()
            self?.applyPendingShellDirectory()
        }
    }
    // Native file promises defer remote downloads until Finder accepts the drop.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !busy, connected, !showingTerminal, let settings = activeSettings, let node = item as? FileNode,
              !node.entry.attributes.isSymbolicLink, let name = String(data: node.entry.nameBytes, encoding: .utf8),
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        // A folder promise already includes selected descendants.
        if selectedNodes.contains(where: { parent in
            parent !== node && parent.entry.attributes.isDirectory && node.path.starts(with: parent.path + Data("/".utf8))
        }) { return nil }
        let group: PromiseGroup
        if let preparedPromiseGroup { group = preparedPromiseGroup }
        else {
            group = PromiseGroup(generation: connectionGeneration, settings: settings)
            preparedPromiseGroup = group
        }
        group.expectedPaths.insert(node.path)
        let remotePath = node.path
        let isDirectory = node.entry.attributes.isDirectory
        return RemoteFilePromise(filename: name, directory: isDirectory) { [weak self, group] url, completion in
            guard let self else { completion(SFTPError.disconnected); return }
            enqueuePromise(TransferItem(remotePath: remotePath, localURL: url, isDirectory: isDirectory), group: group, completion: completion)
        }
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishFileDrag(operation: operation)
    }
    func finishFileDrag(operation: NSDragOperation) {
        if operation.isEmpty { preparedPromiseGroup?.cancelled = true }
        preparedPromiseGroup = nil
    }
    private func localDropURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func dropFolder(_ item: Any?) -> Data? {
        if let node = item as? FileNode, node.entry.attributes.isDirectory, !node.entry.attributes.isSymbolicLink { return node.path }
        return directory?.path
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !busy, connected, !showingTerminal, window?.attachedSheet == nil,
              info.draggingSource as? NSOutlineView !== table, !localDropURLs(info).isEmpty, dropFolder(item) != nil else { return [] }
        let target = (item as? FileNode).flatMap { $0.entry.attributes.isDirectory && !$0.entry.attributes.isSymbolicLink ? $0 : nil }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard !busy, connected, !showingTerminal, window?.attachedSheet == nil, info.draggingSource as? NSOutlineView !== table,
              let folder = dropFolder(item) else { return false }
        let urls = localDropURLs(info)
        guard !urls.isEmpty else { return false }
        uploadFiles(urls, to: folder)
        return true
    }
    private func enqueuePromise(_ item: TransferItem, group: PromiseGroup, completion: @escaping @Sendable (Error?) -> Void) {
        guard !group.cancelled else { completion(CancellationError()); return }
        guard group.generation == connectionGeneration, group.settings == activeSettings, connected, window?.isVisible == true else {
            completion(SFTPError.disconnected); return
        }
        guard window?.attachedSheet == nil || activePromiseGroup === group else { completion(CancellationError()); return }
        guard !busy || activePromiseGroup === group else { completion(CancellationError()); return }
        if activePromiseGroup !== group { applyFileConflict = group.fileConflict }
        activePromiseGroup = group
        pendingPromises.append(PendingPromise(item: item, group: group, completion: completion))
        startPendingPromises()
    }
    private func startPendingPromises() {
        guard !busy, window?.attachedSheet == nil, !pendingPromises.isEmpty else { return }
        activePromiseGroup = pendingPromises.first?.group
        applyFileConflict = activePromiseGroup?.fileConflict
        runOperation("Preparing dropped downloads…") { [self] signal in
            while !pendingPromises.isEmpty {
                let promise = pendingPromises.removeFirst()
                let group = promise.group
                group.items.append(promise.item)
                group.completedPaths.insert(promise.item.remotePath)
                guard !group.cancelled else { promise.completion(CancellationError()); continue }
                guard group.generation == connectionGeneration, group.settings == activeSettings, await browser.isConnected else {
                    group.cancelled = true
                    group.summary.connectionLost = true
                    group.summary.failures.append(TransferFailure(item: promise.item, error: SFTPError.disconnected))
                    promise.completion(SFTPError.disconnected); continue
                }
                let summary = await performTransfer([promise.item], direction: .download, settings: group.settings, signal: signal)
                group.summary.completedFiles += summary.completedFiles
                group.summary.skippedItems += summary.skippedItems
                group.summary.failures += summary.failures
                group.summary.cancelled = group.summary.cancelled || summary.cancelled
                group.summary.connectionLost = group.summary.connectionLost || summary.connectionLost
                let outcome = summary.outcomes.first
                if summary.cancelled || summary.connectionLost { group.cancelled = true }
                promise.completion(outcome?.succeeded == true ? nil : outcome?.error ?? CancellationError())
                status.stringValue = "Downloaded \(group.summary.completedFiles) files; \(group.summary.failures.count) failed."
            }
            if let group = activePromiseGroup, !group.resultsShown,
               group.cancelled || group.completedPaths.isSuperset(of: group.expectedPaths) {
                group.resultsShown = true
                showTransferSummary(group.summary, direction: .download, items: group.items)
            }
            // Keep ownership until runOperation clears busy: Finder may request
            // another promised file while the operation finishes on the actor.
        }
    }
    @objc func previewSelected(_ sender: Any?) {
        guard window?.attachedSheet == nil, enabled(#selector(previewSelected(_:))), let node = selectedNode else { return }
        if node.entry.attributes.size.map({ $0 > 1_000_000 }) ?? true { confirmPreview(node) }
        else { preparePreview(node, approved: false) }
    }
    private func confirmPreview(_ node: FileNode) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Download this file for preview?"
        let size = node.entry.attributes.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "unknown size"
        alert.informativeText = "\(node.entry.name) must be downloaded before it can be previewed. Its size exceeds the 1 MB preview limit or needs confirmation. Listed size: \(size)."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Download and Preview")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            updateControls()
            if result == .alertSecondButtonReturn { preparePreview(node, approved: true) }
        }
        updateControls()
    }
    private func preparePreview(_ node: FileNode, approved: Bool) {
        guard !busy, connected else { return }
        preparingPreview = true
        runOperation("Preparing preview of \(node.entry.name)…") { [self] signal in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Retriever-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var presented = false
            defer { if !presented { try? FileManager.default.removeItem(at: temporary) } }
            let filename = node.entry.name.replacingOccurrences(of: "/", with: "_")
            let destination = temporary.appendingPathComponent(filename)
            do {
                try await browser.download(node.path, to: destination, maximumBytes: approved ? nil : 1_000_000, cancellation: signal) { [weak self] bytes in
                    Task { @MainActor [weak self] in
                        guard let self, busy, cancellation === signal else { return }
                        let count = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                        status.stringValue = "Preparing preview — \(count) received"
                    }
                }
            } catch SFTPError.previewLimitExceeded {
                try signal.check()
                guard await browser.isConnected else { throw SFTPError.disconnected }
                if afterCleanup == nil { afterCleanup = { [weak self] in self?.confirmPreview(node) } }
                return
            }
            try signal.check()
            closePreview()
            let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.escape = { [weak self] in
                guard let self else { return }
                if preparingPreview && busy { cancel(nil) } else { closePreview() }
            }
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
        if window?.isVisible == true { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(showingTerminal ? sshTerminal.terminal : table) }
    }
    @objc func showDownloads(_ sender: Any?) {
        if downloadsWindow == nil { downloadsWindow = DownloadsWindowController(history: downloads) }
        downloadsWindow?.showWindow(nil)
        downloadsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func reconnect(_ sender: Any?) {
        guard enabled(#selector(reconnect(_:))), let activeSettings else { return }
        connect(activeSettings, startingAt: directory?.path)
    }
    @objc func cancel(_ sender: Any?) {
        activePromiseGroup?.cancelled = true
        if let sheet = conflictAlert?.window, let window { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        cancellation?.cancel()
        if busy { status.stringValue = "Cancelling…" }
    }
    @objc func disconnect(_ sender: Any?) {
        guard !busy, window?.attachedSheet == nil else { return }
        guard sshTerminal.confirmEndingSession("Disconnect Files and end the SSH session?") else { return }
        // Confirmation can run the event loop; do not interrupt work started there.
        guard !busy else { return }
        pendingShellDirectory = nil
        connectionGeneration = UUID()
        sshTerminal.setBrowserConnection(nil)
        runOperation("Disconnecting…") { [self] _ in
            sshTerminal.closeSession()
            showingTerminal = false
            await browser.disconnect()
            connected = false
            activeSettings = nil
            directory = nil
            roots = []
            table.reloadData()
            window?.title = "Retriever"
            status.stringValue = "Not connected"
            window?.makeFirstResponder(table)
        }
    }
    /// Returns true when immediate closing is safe; otherwise resolves the user's
    /// choice and defers the completion until the worker finishes transfer cleanup.
    func requestClose(afterCancellation: @escaping @MainActor () -> Void) -> Bool {
        guard busy else {
            guard confirmTerminalQuit() else { return false }
            sshTerminal.stop()
            return true
        }
        guard afterCleanup == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Cancel the current operation and close?"
        alert.informativeText = "The connection will close after the current transfer stops."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Cancel and Close")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        guard confirmTerminalQuit() else { return false }
        sshTerminal.stop()
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
        sshTerminal.stop()
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
            else { applyPendingShellDirectory() }
        }
    }
}
