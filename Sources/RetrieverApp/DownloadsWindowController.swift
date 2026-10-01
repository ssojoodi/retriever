import AppKit
import RetrieverCore

@MainActor
private final class DownloadsTable: NSTableView {
    var reveal: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.intersection([.command, .control, .option]).isEmpty { reveal?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class DownloadsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let history: DownloadHistory
    private let table = DownloadsTable()
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let clear = NSButton(title: "Clear History…", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")

    init(history: DownloadHistory) {
        self.history = history
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Downloads — Retriever"
        window.minSize = NSSize(width: 600, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        for (id, title, width) in [("name", "File", 240.0), ("source", "Source", 230.0), ("date", "Downloaded", 170.0), ("size", "Size", 100.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Completed downloads")
        table.target = self
        table.doubleAction = #selector(revealSelected(_:))
        table.reveal = { [weak self] in self?.revealSelected(nil) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        reveal.target = self
        reveal.action = #selector(revealSelected(_:))
        clear.target = self
        clear.action = #selector(clearHistory(_:))
        summary.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [summary, NSView(), clear, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let content = window.contentView!
        for view in [scroll, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        history.didChange = { [weak self] in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }
    func numberOfRows(in tableView: NSTableView) -> Int { history.entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = history.entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "source": text = "\(entry.settings.username)@\(entry.settings.host):\(entry.settings.port)"
        case "date": text = DateFormatter.localizedString(from: entry.completedAt, dateStyle: .short, timeStyle: .short)
        case "size": text = ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.byteCount), countStyle: .file)
        default: text = entry.filename + (history.location(for: entry.id) == nil ? " (Unavailable)" : "")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = "\(entry.destination.path)\n\(String(decoding: entry.remotePath, as: UTF8.self))"
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
    private var selectedLocation: URL? {
        guard history.entries.indices.contains(table.selectedRow) else { return nil }
        return history.location(for: history.entries[table.selectedRow].id)
    }
    private func updateControls() {
        reveal.isEnabled = selectedLocation != nil
        clear.isEnabled = !history.entries.isEmpty
        summary.stringValue = history.entries.isEmpty ? "No completed downloads" : "\(history.entries.count) downloads"
    }
    private func reload() { table.reloadData(); updateControls() }
    @objc func revealSelected(_ sender: Any?) {
        guard let url = selectedLocation else { reload(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func clearHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear download history?"
        alert.informativeText = "Downloaded files will stay on your Mac."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear History")
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.history.clear() }
        }
    }
}
