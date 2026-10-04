import AppKit

extension Notification.Name {
    static let retrieverSyncPreferenceChanged = Notification.Name("RetrieverSyncPreferenceChanged")
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let syncDefaultsKey = "syncFolders.v1"
    private let defaults: UserDefaults
    private let checkbox = NSButton(checkboxWithTitle: "Keep Files and Terminal folders in sync", target: nil, action: nil)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 175), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        checkbox.target = self
        checkbox.action = #selector(changeSync(_:))
        checkbox.state = defaults.bool(forKey: Self.syncDefaultsKey) ? .on : .off
        let help = NSTextField(wrappingLabelWithString: "For new Bash and Zsh SSH sessions. Folder changes wait while you type or run a command. Press Return at an empty shell prompt to resume paused sync.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [checkbox, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window") }
    @objc private func changeSync(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: Self.syncDefaultsKey)
        NotificationCenter.default.post(name: .retrieverSyncPreferenceChanged, object: nil)
    }
}
