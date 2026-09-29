import AppKit
import RetrieverCore

@MainActor
final class ConnectionSheet: NSObject, NSTextFieldDelegate {
    private let history: ConnectionHistory
    private let alert = NSAlert()
    private let picker = NSPopUpButton()
    private let forget = NSButton(title: "Forget", target: nil, action: nil)
    private let host = NSTextField(string: "")
    private let user = NSTextField(string: NSUserName())
    private let port = NSTextField(string: "22")
    private let folder = NSTextField(string: "")
    private var savedHosts: [SavedHost] = []
    private var selectedHost: SavedHost?

    init(history: ConnectionHistory) {
        self.history = history
        super.init()
        alert.messageText = "Open SFTP Connection"
        alert.informativeText = "Successful connections are saved on this Mac. Passwords are never saved."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        picker.setAccessibilityLabel("Saved hosts")
        picker.target = self
        picker.action = #selector(selectHost(_:))
        forget.target = self
        forget.action = #selector(forgetHost(_:))
        forget.setAccessibilityLabel("Forget selected host")
        let savedRow = NSStackView(views: [picker, forget])
        savedRow.orientation = .horizontal
        savedRow.spacing = 8
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.addArrangedSubview(NSTextField(labelWithString: "Saved hosts"))
        fields.addArrangedSubview(savedRow)
        savedRow.widthAnchor.constraint(equalToConstant: 340).isActive = true
        host.placeholderString = "Server hostname"
        folder.placeholderString = "Server home folder"
        folder.lineBreakMode = .byTruncatingMiddle
        for (label, field) in [("Server", host), ("Username", user), ("Port", port), ("Remote folder", folder)] {
            field.setAccessibilityLabel(label)
            field.delegate = self
            fields.addArrangedSubview(NSTextField(labelWithString: label))
            fields.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString: "Reconnect where you left off, or leave Remote folder empty to start at home.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 340).isActive = true
        fields.addArrangedSubview(note)
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 320)
        alert.accessoryView = fields
        reload()
    }

    private func reload() {
        savedHosts = history.hosts
        picker.removeAllItems()
        picker.addItem(withTitle: "New connection…")
        for record in savedHosts {
            let settings = record.settings
            let name = settings.host.contains(":") ? "[\(settings.host)]" : settings.host
            picker.addItem(withTitle: "\(settings.username)@\(name)" + (settings.port == 22 ? "" : ":\(settings.port)"))
        }
        picker.selectItem(at: savedHosts.isEmpty ? 0 : 1)
        selectHost(nil)
    }

    @objc private func selectHost(_ sender: Any?) {
        let index = picker.indexOfSelectedItem - 1
        selectedHost = savedHosts.indices.contains(index) ? savedHosts[index] : nil
        host.stringValue = selectedHost?.settings.host ?? ""
        user.stringValue = selectedHost?.settings.username ?? NSUserName()
        port.stringValue = selectedHost.map { String($0.settings.port) } ?? "22"
        folder.stringValue = selectedHost.map { String(decoding: $0.lastPath, as: UTF8.self) } ?? ""
        forget.isEnabled = selectedHost != nil
    }

    @objc private func forgetHost(_ sender: Any?) {
        guard let selectedHost else { return }
        history.forget(selectedHost.settings)
        reload()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== folder else { return }
        // A changed identity must not inherit another server/account's folder.
        selectedHost = nil
        picker.selectItem(at: 0)
        forget.isEnabled = false
        folder.stringValue = ""
    }

    func present(on window: NSWindow, completion: @escaping (ConnectionSettings?, Data?) -> Void) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { completion(nil, nil); return }
            do {
                let settings = try ConnectionSettings(host: host.stringValue, username: user.stringValue, port: port.stringValue)
                let path: Data?
                if let selectedHost, settings == selectedHost.settings,
                   folder.stringValue == String(decoding: selectedHost.lastPath, as: UTF8.self) {
                    path = selectedHost.lastPath // Preserve filenames that aren't UTF-8.
                } else {
                    path = folder.stringValue.isEmpty ? nil : Data(folder.stringValue.utf8)
                }
                completion(settings, path)
            } catch {
                let failure = NSAlert(error: error)
                failure.beginSheetModal(for: window) { [weak self] _ in
                    self?.present(on: window, completion: completion)
                }
            }
        }
        alert.window.initialFirstResponder = selectedHost == nil ? host : picker
    }
}
