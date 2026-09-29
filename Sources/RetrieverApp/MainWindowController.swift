import AppKit
import RetrieverCore

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let status = NSTextField(labelWithString: "Not connected")
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Retriever"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        let toolbar = NSToolbar(identifier: "Browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        let content = NSView()
        window.contentView = content
        let symbol = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "Remote server")!)
        symbol.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "Your files, within reach")
        title.font = .systemFont(ofSize: 20, weight: .medium)
        let detail = NSTextField(labelWithString: "Connect to an SFTP server to browse and retrieve files.")
        detail.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open Connection…", target: self, action: #selector(openConnection(_:)))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [symbol, title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 14
        for view in [stack, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            symbol.heightAnchor.constraint(equalToConstant: 48), symbol.widthAnchor.constraint(equalToConstant: 64),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -20),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("connect"), .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("connect"), .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "connect" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Open Connection"
        item.toolTip = "Connect to an SFTP server (⌘O)"
        item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Open Connection")
        item.target = self
        item.action = #selector(openConnection(_:))
        return item
    }
    @objc func openConnection(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Open SFTP Connection"
        alert.informativeText = "Enter your server details."
        let host = NSTextField(string: "")
        host.placeholderString = "Server hostname"
        let user = NSTextField(string: NSUserName())
        let port = NSTextField(string: "22")
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        for (label, field) in [("Server", host), ("Username", user), ("Port", port)] {
            field.setAccessibilityLabel(label)
            fields.addArrangedSubview(NSTextField(labelWithString: label))
            fields.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 170)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                _ = try ConnectionSettings(host: host.stringValue, username: user.stringValue, port: port.stringValue)
                self?.status.stringValue = "Connection details validated. SFTP transport is the next implementation milestone."
            } catch {
                let failure = NSAlert(error: error)
                failure.beginSheetModal(for: window)
            }
        }
        alert.window.initialFirstResponder = host
    }
}
