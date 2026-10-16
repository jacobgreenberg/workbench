import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var store: Store!
    private var runtime: Runtime!
    private var workspace: WorkspaceController!
    private var control: ControlServer?
    private var reserved: [String: NSMenuItem] = [:]   // "key|mods" → item; looked up on every ⌘/⌃ keyDown in a terminal

    func applicationDidFinishLaunching(_ notification: Notification) {
        Agents.discoverLaunchers()
        store = Store()
        runtime = Runtime(overrides: WorkspaceController.overrides(Theme.named(store.layout.theme)))
        NSApp.mainMenu = buildMenu()
        workspace = WorkspaceController(store: store, runtime: runtime)
        workspace.showWindow(nil)

        SurfaceView.isReservedShortcut = { [unowned self] event in performReserved(event) }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let server = ControlServer(path: Store.directory.appendingPathComponent("pane.sock").path) { [unowned self] msg in
            workspace.handleControl(msg)
        }
        server.start()
        control = server

        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Workbench?"
        alert.informativeText = "Running processes will be closed. Claude and Codex sessions resume on next launch."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // ponytail: on quit we only retire surfaces (SIGHUP children) and flush; process exit reclaims the rest,
    // so ghostty_app_free is skipped to avoid racing the background surface frees.
    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        workspace.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["pane"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if let id { self.workspace.focusPane(id) } }
        }
        completionHandler()
    }

    // MARK: - Menu

    private func performReserved(_ event: NSEvent) -> Bool {
        guard let chars = event.characters(byApplyingModifiers: [])?.lowercased() else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let match = reserved["\(chars)|\(mods.rawValue)"] else { return false }
        NSApp.sendAction(match.action!, to: match.target, from: match)
        return true
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      tag: Int = 0, reserved isReserved: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        if isReserved, !key.isEmpty, reserved["\(key.lowercased())|\(mods.rawValue)"] == nil {
            reserved["\(key.lowercased())|\(mods.rawValue)"] = item
        }
        return item
    }

    /// Alternate shortcut: stays in the reserved set (so it works from a terminal) but not shown in the menu.
    private func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private func arrow(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let w = WorkspaceController.self
        main.addItem(menu("Workbench", [
            NSMenuItem(title: "About Workbench", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            item("Hide Workbench", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Workbench", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Tab", #selector(w.newTab(_:)), "t"),
            item("Split Right", #selector(w.splitRight(_:)), "d"),
            item("Split Down", #selector(w.splitDown(_:)), "d", [.command, .shift]),
            .separator(),
            item("Add Project…", #selector(w.addProject(_:)), "o", [.command, .shift]),
            item("Open Markdown…", #selector(w.openMarkdownFile(_:)), "o", [.command, .option]),
            .separator(),
            item("Close Pane", #selector(w.closePane(_:)), "w"),
            item("Close Tab", #selector(w.closeTab(_:)), "w", [.command, .shift]),
        ]))
        main.addItem(menu("Edit", [
            item("Copy", #selector(SurfaceView.copy(_:)), "c", reserved: false),
            item("Paste", #selector(SurfaceView.paste(_:)), "v"),
            item("Select All", #selector(SurfaceView.selectAll(_:)), "a", reserved: false),
            .separator(),
            item("Find…", #selector(w.find(_:)), "f"),
            item("Clear", #selector(w.clearScreen(_:)), "k"),
        ]))
        var themeItems: [NSMenuItem] = []
        for theme in Theme.all() {
            let t = NSMenuItem(title: theme.name, action: #selector(w.selectTheme(_:)), keyEquivalent: "")
            t.representedObject = theme.id
            themeItems.append(t)
        }
        main.addItem(menu("View", [
            item("Toggle Sidebar", #selector(w.toggleProjectSidebar(_:)), "b"),
            item("Equalize Splits", #selector(w.equalizeSplits(_:)), "0", [.command, .shift]),
            .separator(),
            item("Bigger", #selector(w.increaseFontSize(_:)), "="),
            item("Smaller", #selector(w.decreaseFontSize(_:)), "-"),
            item("Actual Size", #selector(w.resetFontSize(_:)), "0"),
            .separator(),
            menu("Theme", themeItems),
        ]))
        var presetItems: [NSMenuItem] = []
        for p in store.layout.presets where (1...9).contains(p.key) {
            presetItems.append(item(p.name, #selector(w.launchPreset(_:)), "\(p.key)", [.control], tag: p.key))
        }
        var projectItems: [NSMenuItem] = (1...9).map { item("Project \($0)", #selector(w.selectProjectByTag(_:)), "\($0)", tag: $0) }
        projectItems += [
            .separator(),
            item("Previous Project", #selector(w.previousProject(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Next Project", #selector(w.nextProject(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
        ]
        main.addItem(menu("Go", projectItems + [
            .separator(),
            item("Previous Tab", #selector(w.previousTab(_:)), "[", [.command, .shift]),
            item("Next Tab", #selector(w.nextTab(_:)), "]", [.command, .shift]),
            hidden(item("Previous Tab", #selector(w.previousTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])),
            hidden(item("Next Tab", #selector(w.nextTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])),
            .separator(),
            item("Previous Pane", #selector(w.focusPreviousPane(_:)), "["),
            item("Next Pane", #selector(w.focusNextPane(_:)), "]"),
            item("Focus Left", #selector(w.focusLeft(_:)), "h", [.command, .option]),
            item("Focus Down", #selector(w.focusDown(_:)), "j", [.command, .option]),
            item("Focus Up", #selector(w.focusUp(_:)), "k", [.command, .option]),
            item("Focus Right", #selector(w.focusRight(_:)), "l", [.command, .option]),
        ]))
        main.addItem(menu("Agents", presetItems))
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}
