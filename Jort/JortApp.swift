import AppKit
import JortDocument
import JortPersistence
import JortAppKit

@main
enum JortApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var duplicate = false
    var window: NSWindow!
    var editor: EditorViewController!
    var persistence: PersistenceController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let override = ProcessInfo.processInfo.environment["JORT_DATA_DIRECTORY"]
        let installed = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
        let storeName = installed ? "Jort" : "Jort Development"
        let directory = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(storeName, isDirectory: true)
        persistence = PersistenceController(directory: directory)
        editor = EditorViewController(persistence: persistence)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Jort"
        window.titleVisibility = .hidden
        window.subtitle = ""
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
            DispatchQueue.main.async { NSApp.applicationIconImage = icon }
        }
        window.minSize = NSSize(width: 460, height: 300)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
        window.contentViewController = editor
        let paletteAccessory = NSTitlebarAccessoryViewController()
        let paletteButton = NSButton(image: commandPaletteIcon(), target: editor, action: #selector(EditorViewController.showCommandPalette))
        paletteButton.isBordered = false
        paletteButton.setAccessibilityLabel("Open Pocket")
        paletteButton.toolTip = "Pocket (⌘K)"
        paletteButton.imageScaling = .scaleProportionallyDown
        paletteButton.frame = NSRect(x: 0, y: 0, width: 38, height: 28)
        let paletteContainer = NSView(frame: NSRect(x: 0, y: 0, width: 46, height: 28))
        paletteContainer.addSubview(paletteButton)
        paletteAccessory.view = paletteContainer; paletteAccessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(paletteAccessory)
        window.setContentSize(NSSize(width: 920, height: 680))
        window.delegate = self
        if !window.setFrameUsingName("JortCanvas") { window.center() }
        window.setFrameAutosaveName("JortCanvas")
        editor.saveStatus = { [weak self] status in
            if status == .ownershipConflict {
                let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.jort.editor").first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                owner?.activate(options: [])
                // The duplicate never offers recovery and exits without touching the store.
                self?.duplicate = true
                NSApp.terminate(nil)
            }
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
        persistence.flushLifecycle(reason: .windowClosed); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if duplicate { return .terminateNow }
        editor.textView.unmarkText()
        persistence.flushLifecycle(reason: .shutdown) { saved in
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
    @objc func flush() { persistence.flushLifecycle(reason: .deactivation) }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil) }
    @objc func find() {
        editor.showDocumentSearch()
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
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = submenu("Edit")
        add(edit, "Undo", #selector(JortTextView.undo(_:)), "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(JortTextView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(find), "f", self)
        let navigation = submenu("Navigate")
        add(navigation, "Pocket…", #selector(EditorViewController.showCommandPalette), "k", editor)
        add(navigation, "Add or Change Landmark…", #selector(EditorViewController.addOrChangeLandmark), "", editor)
        add(navigation, "Clear Landmark", #selector(EditorViewController.clearCurrentLandmark), "", editor)
        add(navigation, "Scroll to Next Landmark", #selector(EditorViewController.nextLandmark), "", editor)
        add(navigation, "Scroll to Last Landmark", #selector(EditorViewController.previousLandmark), "", editor)
        let windowMenu = submenu("Window")
        add(windowMenu, "Show Jort", #selector(showWindow), "0", self)
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    private func commandPaletteIcon() -> NSImage {
        guard let url = Bundle.main.url(forResource: "jort-white", withExtension: "svg"), let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "command", accessibilityDescription: "Open Pocket")!
        }
        image.size = NSSize(width: 20, height: 21)
        return image
    }
}
