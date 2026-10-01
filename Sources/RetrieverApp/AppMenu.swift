import AppKit

@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Retriever")
        app.addItem(withTitle: "About Retriever", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Retriever", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Retriever", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        file.addItem(withTitle: "Open Connection…", action: #selector(MainWindowController.openConnection(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Download Selected File…", action: #selector(MainWindowController.downloadSelected(_:)), keyEquivalent: "d")
        file.addItem(withTitle: "Preview Selected File", action: #selector(MainWindowController.previewSelected(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Reconnect", action: #selector(MainWindowController.reconnect(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Refresh", action: #selector(MainWindowController.refresh(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Enclosing Folder", action: #selector(MainWindowController.goUp(_:)), keyEquivalent: "[")
        file.addItem(withTitle: "Disconnect", action: #selector(MainWindowController.disconnect(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Cancel Operation", action: #selector(MainWindowController.cancel(_:)), keyEquivalent: ".")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let downloads = window.addItem(withTitle: "Downloads", action: #selector(AppDelegate.showDownloads(_:)), keyEquivalent: "j")
        downloads.keyEquivalentModifierMask = [.command, .shift]
        NSApp.windowsMenu = window
        let help = submenu("Help")
        help.addItem(withTitle: "Retriever Help", action: #selector(AppDelegate.showRetrieverHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}
