import AppKit

@main
enum JortApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var editor: EditorViewController!
    var persistence: PersistenceController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let override = ProcessInfo.processInfo.environment["JORT_DATA_DIRECTORY"]
        let directory = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jort", isDirectory: true)
        persistence = PersistenceController(directory: directory)
        editor = EditorViewController(persistence: persistence)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Jort"
        window.subtitle = ""
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
            DispatchQueue.main.async { NSApp.applicationIconImage = icon }
        }
        window.minSize = NSSize(width: 460, height: 300)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 920, height: 680))
        window.delegate = self
        if !window.setFrameUsingName("JortCanvas") { window.center() }
        window.setFrameAutosaveName("JortCanvas")
        editor.saveStatus = { [weak self] message, failure in
            self?.window.subtitle = failure ? "Save needs attention" : ""
        }
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(flush), name: NSApplication.didResignActiveNotification, object: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistence.flush(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor.textView.unmarkText()
        persistence.flush { saved in
            if saved { sender.reply(toApplicationShouldTerminate: true) }
            else {
                self.window.makeKeyAndOrderFront(nil)
                let alert = NSAlert()
                alert.messageText = "Your latest changes haven’t been saved"
                alert.informativeText = "Keep Jort open to preserve your text and retry saving, or quit and lose changes since the last successful save. You can copy your text before quitting."
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Without Saving")
                alert.beginSheetModal(for: self.window) { response in
                    sender.reply(toApplicationShouldTerminate: response == .alertSecondButtonReturn)
                }
            }
        }
        return .terminateLater
    }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc func flush() { persistence.flush() }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil) }
    @objc func find() {
        window.makeFirstResponder(editor.textView)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.textView.performFindPanelAction(item)
    }
    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); let menu = NSMenu(title: title)
            item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let app = submenu("Jort")
        add(app, "About Jort", #selector(showAbout), "", self)
        app.addItem(.separator())
        add(app, "Hide Jort", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        add(app, "Quit Jort", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("File")
        add(file, "Save Now", #selector(EditorViewController.save), "s", editor)
        add(file, "Save Recovery Copy…", #selector(EditorViewController.saveRecoveryCopy), "", editor)
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(find), "f", self)
        let windowMenu = submenu("Window")
        add(windowMenu, "Show Jort", #selector(showWindow), "0", self)
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
