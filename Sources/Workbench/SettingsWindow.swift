import AppKit
import UniformTypeIdentifiers

/// ⌘, — a native tabbed settings window (toolbar tab style). Add a pane by adding another NSTabViewItem.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(workspace: WorkspaceController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let themes = ThemesViewController(workspace: workspace)
        let item = NSTabViewItem(viewController: themes)
        item.label = "Themes"
        item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Themes")
        tabs.addTabViewItem(item)
        let backupItem = NSTabViewItem(viewController: BackupViewController(workspace: workspace))
        backupItem.label = "Backup"
        backupItem.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Backup")
        tabs.addTabViewItem(backupItem)
        let linksItem = NSTabViewItem(viewController: LinksViewController(workspace: workspace))
        linksItem.label = "Links"
        linksItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Links")
        tabs.addTabViewItem(linksItem)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A Dark / Light choice: a miniature terminal in the theme's colors with its name underneath. A real NSButton, so
/// keyboard (Space) and VoiceOver work; `state == .on` is the selected one.
private final class ThemeCard: NSButton {
    let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        title = theme.name
        setButtonType(.momentaryPushIn)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 118).isActive = true
        setAccessibilityLabel("\(theme.name) appearance")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var preview: NSRect { NSRect(x: 3, y: 28, width: bounds.width - 6, height: bounds.height - 31) }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: preview, xRadius: 10, yRadius: 10)
        theme.terminalColor("background").setFill()
        box.fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func line(_ parts: [(String, String)], _ row: Int) {
            let s = NSMutableAttributedString()
            for (text, key) in parts { s.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: theme.terminalColor(key)])) }
            s.draw(at: NSPoint(x: preview.minX + 12, y: preview.minY + 14 + CGFloat(row) * 16))   // NSButton is flipped: rows run down
        }
        line([("~ % ", "foreground"), ("ls", "foreground")], 0)
        line([("src  ", "blue"), ("README.md  ", "green"), ("run", "red")], 1)
        line([("~ % ", "foreground"), ("█", "foreground")], 2)
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            box.lineWidth = 3
        } else {
            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
        }
        box.stroke()
        let label = NSAttributedString(string: theme.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: state == .on ? .semibold : .regular), .foregroundColor: NSColor.labelColor])
        label.draw(at: NSPoint(x: (bounds.width - label.size().width) / 2, y: 5))
    }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: preview, xRadius: 10, yRadius: 10).fill() }
    override var focusRingMaskBounds: NSRect { preview }
    override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
}

private final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

@MainActor
private func settingsHeader(_ title: String, _ caption: String) -> NSStackView {
    let t = NSTextField(labelWithString: title)
    t.font = .systemFont(ofSize: 13, weight: .semibold)
    let c = NSTextField(wrappingLabelWithString: caption)
    c.font = .systemFont(ofSize: 11)
    c.textColor = .secondaryLabelColor
    let s = NSStackView(views: [t, c])
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 2
    return s
}

/// Settings > Themes: Dark / Light cards, then the bundled and user themes (user ones can be edited and deleted).
@MainActor
private final class ThemesViewController: NSViewController {
    private unowned let workspace: WorkspaceController
    private let cards = NSStackView()
    private let list = FlippedStack()
    private var editor: ThemeEditorSheet?

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        title = "Themes"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 14

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = list
        list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor).isActive = true
        list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 196).isActive = true

        let add = NSButton(title: "Add Custom Theme…", target: self, action: #selector(addTheme(_:)))
        let stack = NSStackView(views: [
            settingsHeader("Appearance", "Dark and Light use Apple's colors and follow the Terminal app's default profile."),
            cards,
            settingsHeader("Custom Themes", "Bundled themes are read-only. Your own live in ~/Library/Application Support/Workbench/themes."),
            scroll,
            add,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: cards)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        for v in [cards, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        view = stack
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        refresh()
        // Observed only once the view exists: a tab never opened has no controls for refresh to fill.
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .themeChanged, object: nil)
    }

    @objc private func refresh() {
        let current = workspace.theme.id
        let all = Theme.all()

        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for t in all.filter(\.isSystem).sorted(by: { $0.type > $1.type }) {   // Dark, Light
            let card = ThemeCard(theme: t)
            card.identifier = NSUserInterfaceItemIdentifier(t.id)
            card.target = self
            card.action = #selector(choose(_:))
            card.state = t.id == current ? .on : .off
            cards.addArrangedSubview(card)
        }

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for t in all where !t.isSystem {
            let id = NSUserInterfaceItemIdentifier(t.id)
            let radio = NSButton(radioButtonWithTitle: t.name, target: self, action: #selector(choose(_:)))
            radio.identifier = id
            radio.state = t.id == current ? .on : .off
            var views: [NSView] = [radio, NSView()]
            if Theme.userFiles[t.id] != nil {
                for (title, action) in [("Edit…", #selector(edit(_:))), ("Delete", #selector(remove(_:)))] {
                    let b = NSButton(title: title, target: self, action: action)
                    b.controlSize = .small
                    b.bezelStyle = .rounded
                    b.identifier = id
                    b.setAccessibilityLabel("\(title.replacingOccurrences(of: "…", with: "")) \(t.name)")
                    views.append(b)
                }
            } else {
                let l = NSTextField(labelWithString: "Bundled")
                l.font = .systemFont(ofSize: 11)
                l.textColor = .tertiaryLabelColor
                views.append(l)
            }
            let row = NSStackView(views: views)
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func choose(_ sender: NSControl) {
        if let id = sender.identifier?.rawValue { workspace.applyTheme(id) }
    }

    @objc private func addTheme(_ sender: Any?) {
        var id = "my-theme", n = 2
        while FileManager.default.fileExists(atPath: Theme.userDirectory.appendingPathComponent("\(id).json").path) {
            id = "my-theme-\(n)"; n += 1
        }
        present(ThemeEditorSheet(text: workspace.theme.template(id: id, name: id == "my-theme" ? "My Theme" : "My Theme \(n - 1)"), editing: nil))
    }

    @objc private func edit(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue, let file = Theme.userFiles[id] else { return }
        let text = (readFile(file, cap: 1 << 20).flatMap { String(data: $0, encoding: .utf8) }) ?? Theme.named(id).template(id: id, name: Theme.named(id).name)
        present(ThemeEditorSheet(text: text, editing: file))
    }

    @objc private func remove(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue, let file = Theme.userFiles[id], let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(Theme.named(id).name)\"?"
        alert.informativeText = "This removes \(file.lastPathComponent) from your themes folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            try? FileManager.default.removeItem(at: file)
            Theme.reload()
            workspace.applyTheme(workspace.theme.id)   // falls back to the default if the active theme is gone
        }
    }

    private func present(_ sheet: ThemeEditorSheet) {
        guard let window = view.window else { return }
        sheet.onSaved = { [unowned self] id in
            Theme.reload()
            workspace.applyTheme(id)
            editor = nil
        }
        sheet.onCancel = { [unowned self] in editor = nil }
        editor = sheet
        window.beginSheet(sheet.window)
    }
}

/// Accepts a dropped .json file (a backup).
private final class DropStack: NSStackView {
    var onDrop: (URL) -> Void = { _ in }

    private func jsonURL(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "json" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        jsonURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = jsonURL(sender) else { return false }
        onDrop(url)
        return true
    }
}

/// Settings > Links: the Jira browse URL and project keys that ⌘-click in a terminal.
@MainActor
private final class LinksViewController: NSViewController {
    private unowned let workspace: WorkspaceController
    private let browseField = NSTextField(string: "")
    private let projectsField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        title = "Links"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let jira = workspace.store.layout.jira
        browseField.stringValue = jira?.browse ?? ""
        browseField.placeholderString = "https://yourcompany.atlassian.net/browse/"
        projectsField.stringValue = jira?.projects.joined(separator: ", ") ?? ""
        projectsField.placeholderString = "MER, OPS, PLAT"
        func row(_ label: String, _ field: NSTextField) -> NSStackView {
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
            let r = NSStackView(views: [NSTextField(labelWithString: label), field])
            r.spacing = 8
            return r
        }
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let saveRow = NSStackView(views: [save, statusLabel])
        saveRow.spacing = 8
        let stack = NSStackView(views: [
            settingsHeader("Jira Links", "⌘-click a ticket key like MER-123 in a terminal to open it. Only these project keys link, so UTF-8 or SHA-256 never do."),
            row("Browse URL", browseField),
            row("Project keys", projectsField),
            saveRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        view = stack
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
    }

    @objc private func save(_ sender: Any?) {
        let browse = browseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !browse.isEmpty && !browse.hasPrefix("https://") && !browse.hasPrefix("http://") {
            statusLabel.stringValue = "The URL must start with https://"
            return
        }
        let projects = JiraLinks.parseProjects(projectsField.stringValue)
        workspace.applyJira(JiraLinks(browse: browse, projects: projects))
        projectsField.stringValue = projects.joined(separator: ", ")
        statusLabel.stringValue = projects.isEmpty || browse.isEmpty ? "Saved. Ticket links are off." : "Saved. \(projects.count) project keys."
    }
}

/// Settings > Backup: export / import the whole setup as JSON, and optional git sync of it.
@MainActor
private final class BackupViewController: NSViewController {
    private unowned let workspace: WorkspaceController
    private var store: Store { workspace.store }
    private let repoLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var stopButton: NSButton!
    private var syncButton: NSButton!
    private var restoreButton: NSButton!

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        title = "Backup"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let buttons = NSStackView(views: [
            NSButton(title: "Export…", target: self, action: #selector(export(_:))),
            NSButton(title: "Import…", target: self, action: #selector(importDialog(_:))),
            NSButton(title: "Copy JSON", target: self, action: #selector(copyJSON(_:))),
            NSButton(title: "Paste JSON", target: self, action: #selector(pasteJSON(_:))),
        ])
        buttons.spacing = 8

        repoLabel.font = .systemFont(ofSize: 12)
        repoLabel.lineBreakMode = .byTruncatingMiddle
        repoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton = NSButton(title: "Stop Syncing", target: self, action: #selector(stopSync(_:)))
        let repoRow = NSStackView(views: [
            repoLabel, NSView(),
            NSButton(title: "Connect…", target: self, action: #selector(connect(_:))),
            stopButton,
        ])
        repoRow.spacing = 8

        syncButton = NSButton(title: "Sync Now", target: self, action: #selector(syncNow(_:)))
        restoreButton = NSButton(title: "Restore from Repository…", target: self, action: #selector(restoreFromRepo(_:)))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let syncRow = NSStackView(views: [syncButton, restoreButton, statusLabel])
        syncRow.spacing = 8

        let stack = DropStack(views: [
            settingsHeader("Backup", "Everything that makes Workbench yours, in one JSON file: projects and their order, tabs and splits, workspaces, themes and your Ghostty config. To restore one, import it, paste it, or drop the file on this window."),
            buttons,
            settingsHeader("Git Sync", "Keeps a copy in a git repository that only Workbench uses. Make it private: it holds your project names, folders and commands. Each Mac writes its own file, committed and pushed at most every 10 minutes and at quit. Agent sessions aren't synced; panes restore as shells."),
            repoRow,
            syncRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(24, after: buttons)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        repoRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.registerForDraggedTypes([.fileURL])
        stack.onDrop = { [unowned self] url in importFile(url) }
        view = stack
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        refresh()
        // Observed only once the view exists: a tab never opened has no controls for refresh to fill.
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .backupStatusChanged, object: nil)
    }

    @objc private func refresh() {
        let repo = store.layout.backupRemote
        repoLabel.stringValue = repo ?? "Not connected"
        repoLabel.textColor = repo == nil ? .secondaryLabelColor : .labelColor
        stopButton.isHidden = repo == nil
        syncButton.isEnabled = repo != nil
        restoreButton.isEnabled = repo != nil
        statusLabel.stringValue = BackupSync.shared.status
    }

    @objc private func export(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Workbench Backup.json"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [self] r in
            guard r == .OK, let url = panel.url else { return }
            workspace.captureAgents()
            do { try Backup.current(store.layout).encoded().write(to: url, options: .atomic) } catch { fail("Couldn't export the backup", message(error)) }
        }
    }

    @objc private func importDialog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [self] r in
            guard r == .OK, let url = panel.url else { return }
            importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        guard let data = readFile(url, cap: 64 << 20) else { return fail("Couldn't read the backup", "\(url.lastPathComponent) is missing, not a file, or too large.") }
        importData(data)
    }

    @objc private func copyJSON(_ sender: Any?) {
        workspace.captureAgents()
        do {
            let data = try Backup.current(store.layout).encoded()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        } catch { fail("Couldn't copy the backup", message(error)) }
    }

    private func message(_ error: Error) -> String { (error as? BackupError)?.message ?? error.localizedDescription }

    @objc private func pasteJSON(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("Nothing to paste", "Copy a Workbench backup's JSON first.")
        }
        guard text.utf8.count <= Backup.maxSize else { return fail("Couldn't read the backup", "The pasted text is over 64 MB.") }
        importData(Data(text.utf8))
    }

    @objc private func connect(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect a git repository"
        alert.informativeText = "Paste the URL of an empty private repository, e.g. git@github.com:you/workbench-backup.git. Workbench clones it and syncs your setup there."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "git@github.com:you/workbench-backup.git"
        field.stringValue = store.layout.backupRemote ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = "Connecting…"
        BackupSync.shared.connect(remote: url) { [weak self] err in
            guard let self else { return }
            if let err { refresh(); return fail("Couldn't connect", err.message) }
            store.layout.backupRemote = url
            store.changed()
            BackupSync.shared.syncNow(store)
            refresh()
        }
    }

    @objc private func stopSync(_ sender: Any?) {
        BackupSync.shared.stop()
        store.layout.backupRemote = nil
        store.changed()
        refresh()
    }

    @objc private func syncNow(_ sender: Any?) { BackupSync.shared.syncNow(store) }

    @objc private func restoreFromRepo(_ sender: Any?) {
        guard store.layout.backupRemote != nil else { return }
        statusLabel.stringValue = "Fetching…"
        BackupSync.shared.fetchBackups { [weak self] result in
            guard let self else { return }
            refresh()
            switch result {
            case .failure(let e):
                fail("Couldn't restore from the repository", e.message)
            case .success(let list):
                if list.isEmpty { fail("Nothing to restore yet", "The repository has no Workbench backups.") }
                else if list.count == 1 { begin(list[0]) }
                else { pickMachine(list) }
            }
        }
    }

    private func pickMachine(_ list: [Backup]) {
        let alert = NSAlert()
        alert.messageText = "Restore which Mac's setup?"
        alert.informativeText = "Each Mac that syncs to this repository has its own backup."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for b in list {
            popup.addItem(withTitle: b.machine.map { $0 == Backup.thisMachine ? "\($0) (this Mac)" : $0 } ?? "Unknown Mac")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        begin(list[popup.indexOfSelectedItem])
    }

    private func importData(_ data: Data) {
        do { begin(try Backup.decode(data)) } catch { fail("Couldn't read the backup", message(error)) }
    }

    private func begin(_ backup: Backup) {
        var b = backup
        for p in backup.missingProjects {
            while true {
                let alert = NSAlert()
                alert.messageText = "Folder for “\(p.name)” not found"
                alert.informativeText = "\(p.path) doesn't exist on this Mac. Locate the folder, or leave the project out of the restore."
                alert.addButton(withTitle: "Locate…")
                alert.addButton(withTitle: "Remove Project")
                alert.addButton(withTitle: "Cancel Import")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Choose"
                    panel.message = "Choose the folder for \(p.name)."
                    if panel.runModal() == .OK, let url = panel.url { b.relocate(project: p.id, to: url.path) } else { continue }
                case .alertSecondButtonReturn:
                    b.remove(project: p.id)
                default:
                    return
                }
                break
            }
        }
        let backupsPath = (Store.directory.appendingPathComponent("backups").path as NSString).abbreviatingWithTildeInPath
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Replace your current setup?"
        confirm.informativeText = "Workbench quits and reopens with the \(b.layout.projects.count) projects in this backup. Terminals the backup also has keep running; the rest close, and new tabs run their saved commands, so only restore backups you made. Your current setup is saved to \(backupsPath) first."
            + (b.ghosttyConfig != nil ? " It also replaces ~/.config/ghostty/config." : "")
            + (workspace.needsConfirmQuit ? " Running commands, and agents in the middle of a turn, are stopped." : "")
        confirm.addButton(withTitle: "Replace and Relaunch").hasDestructiveAction = true
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        workspace.captureAgents()
        let rollback: URL
        do { rollback = try Backup.saveCurrent(store.layout) } catch { return fail("Couldn't save your current setup, so nothing was replaced", message(error)) }
        (NSApp.delegate as? AppDelegate)?.restore(b, rollback: rollback)
    }

    private func fail(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Add / Edit Custom Theme: the theme's JSON in a monospace editor; Save validates and shows what's wrong inline.
@MainActor
private final class ThemeEditorSheet: NSObject {
    let window: NSWindow
    var onSaved: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private let textView: NSTextView
    private let error = NSTextField(wrappingLabelWithString: "")
    private let editing: URL?

    init(text: String, editing: URL?) {
        self.editing = editing
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        textView = scroll.documentView as! NSTextView
        super.init()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.setAccessibilityLabel("Theme JSON")

        let help = NSTextField(wrappingLabelWithString: """
            Provide the theme as JSON, then Save. Required: "id" (becomes the file name: letters, digits, - _ .), "name", \
            "type" ("dark" or "light", sets the window appearance), "ui" (\(Theme.requiredUI.joined(separator: ", "))) and \
            "terminal" (\(Theme.requiredTerminal.prefix(5).joined(separator: ", ")), and the 16 ANSI colors black to brightWhite). \
            Colors are #RRGGBB or rgba(r, g, b, a). Extra keys are ignored.
            """)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 12)
        error.isHidden = true
        error.setAccessibilityRole(.staticText)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 10

        let stack = NSStackView(views: [help, scroll, error, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = stack
        for v in [help, scroll, error, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        window.initialFirstResponder = textView
    }

    private func show(_ message: String) {
        error.stringValue = message
        error.isHidden = false
        NSAccessibility.post(element: error, notification: .announcementRequested, userInfo: [.announcement: message])
    }

    private func end() { window.sheetParent?.endSheet(window) }

    @objc private func cancel(_ sender: Any?) { end(); onCancel() }

    @objc private func save(_ sender: Any?) {
        let text = textView.string
        switch Theme.validate(text) {
        case .failure(let e):
            show(e.message)
        case .success(let t):
            let dest = Theme.userDirectory.appendingPathComponent("\(t.id).json")
            if dest != editing, FileManager.default.fileExists(atPath: dest.path) {
                return show("A custom theme with id \"\(t.id)\" already exists. Change \"id\", or Edit that theme instead.")
            }
            do { _ = try Theme.save(t, text: text) } catch { return show("Couldn't save: \(error.localizedDescription)") }
            if let old = editing, old != dest { try? FileManager.default.removeItem(at: old) }   // id changed while editing
            end()
            onSaved(t.id)
        }
    }
}
