import AppKit
import RetrieverCore

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let browser: SFTPBrowser
    private let history: ConnectionHistory
    private var activeSettings: ConnectionSettings?
    private var connectionSheet: ConnectionSheet?
    private let status = NSTextField(labelWithString: "Not connected")
    private let pathField = NSTextField(labelWithString: "")
    private let table = NSTableView()
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
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel("Remote files")
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
    private var selected: RemoteEntry? {
        guard let directory, directory.entries.indices.contains(table.selectedRow) else { return nil }
        return directory.entries[table.selectedRow]
    }
    private func enabled(_ action: Selector?) -> Bool {
        if action == #selector(cancel(_:)) { return busy }
        if busy { return false }
        switch action {
        case #selector(openConnection(_:)): return true
        case #selector(goUp(_:)): return directory != nil && directory?.path != Data("/".utf8)
        case #selector(refresh(_:)), #selector(disconnect(_:)): return directory != nil
        case #selector(downloadSelected(_:)): return selected.map { !$0.attributes.isDirectory && !$0.attributes.isSymbolicLink } ?? false
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
    func numberOfRows(in tableView: NSTableView) -> Int { directory?.entries.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = directory?.entries[row] else { return nil }
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "size": value = entry.attributes.isDirectory ? "—" : entry.attributes.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
        case "modified": value = entry.attributes.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        default: value = (entry.attributes.isDirectory ? "▸  " : "") + entry.name.replacingOccurrences(of: "\n", with: "↵")
        }
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = entry.name
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
        guard !busy, let selected, let directory else { return }
        if selected.attributes.isDirectory { navigate(SFTPSession.appending(selected.nameBytes, to: directory.path)) }
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
        guard enabled(#selector(downloadSelected(_:))), let selected, let directory else { return }
        runOperation("Downloading \(selected.name)…") { [self] signal in
            try await browser.download(SFTPSession.appending(selected.nameBytes, to: directory.path), to: destination, cancellation: signal) { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, busy, cancellation === signal else { return }
                    let count = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                    status.stringValue = "Downloading \(selected.name) — \(count) received"
                }
            }
            status.stringValue = "Downloaded to \(destination.path)"
        }
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
        requestClose { [weak sender] in sender?.performClose(nil) }
    }
    func windowWillClose(_ notification: Notification) {
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
