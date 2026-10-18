import AppKit

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
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .themeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func header(_ title: String, _ caption: String) -> NSStackView {
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
            header("Appearance", "Dark and Light use Apple's colors and follow the Terminal app's default profile."),
            cards,
            header("Custom Themes", "Bundled themes are read-only. Your own live in ~/Library/Application Support/Workbench/themes."),
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
