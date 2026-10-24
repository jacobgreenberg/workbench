import AppKit

/// New Project (⇧⌘O, the toolbar's +): a sheet with Open Folder | Clone Repository. Cloning names a remote and a
/// location; the folder comes from the URL. A destination that already exists offers to open it instead (when its
/// origin is this repository) or to clone under another name.
@MainActor final class NewProjectSheet: NSObject, NSTextFieldDelegate {
    enum Result { case open(URL), clone(GitRemote, into: String) }   // into: the new folder's full path

    let window: NSWindow
    var onDone: (Result?) -> Void = { _ in }

    private let modes = GlassSegments(labels: ["Open Folder", "Clone Repository"])
    private var cloning = true
    // Open Folder
    private let openGroup = NSStackView()
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private var folder: URL?
    // Clone Repository
    private let cloneGroup = NSStackView()
    private let urlField = NSTextField(string: "")
    private let urlNote = NSTextField(labelWithString: "")
    private let clipboardButton = NSButton(title: "", target: nil, action: nil)
    private var clipboardOffered = false
    private let location = NSPopUpButton(frame: .zero, pullsDown: false)
    private var locations: [String]
    private let destination = NSTextField(labelWithString: "")
    private let conflict = NSView()
    private let conflictTitle = NSTextField(wrappingLabelWithString: "")
    private let conflictDetail = NSTextField(wrappingLabelWithString: "")
    private let openExisting = NSButton(title: "Open Existing as Project", target: nil, action: nil)
    private let renameGroup = NSStackView()
    private let nameField = NSTextField(string: "")
    private let nameNote = NSTextField(labelWithString: "")
    private var renamedFor: String?   // the derived folder the name field was filled in for
    // Footer
    private let primary = NSButton(title: "Clone", target: nil, action: nil)

    /// `locations`: absolute folders, the default first. `url`/`cloning` prefill it (Edit URL… on a failed clone).
    init(workspace: String, locations: [String], url: String = "", cloning: Bool = true) {
        self.locations = locations.isEmpty ? [NSHomeDirectory()] : locations
        self.cloning = cloning
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()

        let title = NSTextField(labelWithString: "New Project")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        let shortcut = NSTextField(labelWithString: "⇧⌘O")
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), shortcut])
        modes.tint = .labelColor
        modes.onSelect = { [unowned self] i in setMode(i == 1) }
        modes.setAccessibilityLabel("Kind of project")

        // Open Folder
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderButton.imagePosition = .imageLeading
        folderButton.alignment = .left
        folderButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        folderButton.lineBreakMode = .byTruncatingMiddle
        let chooseFolder = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = row(folderButton, chooseFolder)
        openGroup.setViews([caption("Folder"), folderRow], in: .leading)
        openGroup.orientation = .vertical
        openGroup.alignment = .leading
        openGroup.spacing = 6

        // Clone Repository
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.placeholderString = "https://github.com/org/repo.git  or  git@host:org/repo.git"
        urlField.stringValue = url
        urlField.delegate = self
        urlField.setAccessibilityLabel("Repository URL")
        urlNote.font = .systemFont(ofSize: 12)
        clipboardButton.bezelStyle = .inline
        clipboardButton.controlSize = .small
        clipboardButton.target = self
        clipboardButton.action = #selector(useClipboard)
        clipboardButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        clipboardButton.imagePosition = .imageLeading
        clipboardButton.lineBreakMode = .byTruncatingMiddle
        clipboardButton.isHidden = true
        location.target = self
        location.action = #selector(locationPicked)
        location.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        location.setAccessibilityLabel("Location")
        let chooseLocation = NSButton(title: "Choose…", target: self, action: #selector(chooseLocation))
        destination.font = .systemFont(ofSize: 12)
        destination.textColor = .secondaryLabelColor
        destination.lineBreakMode = .byTruncatingMiddle

        conflict.wantsLayer = true
        conflict.layer?.cornerRadius = 12
        conflict.layer?.borderWidth = 1
        let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")!)
        warn.contentTintColor = .systemYellow
        conflictTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        conflictDetail.font = .systemFont(ofSize: 12)
        conflictDetail.textColor = .secondaryLabelColor
        openExisting.target = self
        openExisting.action = #selector(openExistingTapped)
        openExisting.controlSize = .small
        let conflictText = NSStackView(views: [conflictTitle, conflictDetail, openExisting])
        conflictText.orientation = .vertical
        conflictText.alignment = .leading
        conflictText.spacing = 4
        conflictText.setCustomSpacing(10, after: conflictDetail)
        let conflictRow = NSStackView(views: [warn, conflictText])
        conflictRow.alignment = .top
        conflictRow.spacing = 10
        conflictRow.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        conflictRow.translatesAutoresizingMaskIntoConstraints = false
        conflict.addSubview(conflictRow)
        conflict.setAccessibilityElement(true)
        conflict.setAccessibilityRole(.group)
        NSLayoutConstraint.activate([
            conflictRow.leadingAnchor.constraint(equalTo: conflict.leadingAnchor),
            conflictRow.trailingAnchor.constraint(equalTo: conflict.trailingAnchor),
            conflictRow.topAnchor.constraint(equalTo: conflict.topAnchor),
            conflictRow.bottomAnchor.constraint(equalTo: conflict.bottomAnchor),
        ])

        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.setAccessibilityLabel("Clone as")
        nameNote.font = .systemFont(ofSize: 12)
        nameNote.lineBreakMode = .byTruncatingMiddle
        renameGroup.setViews([caption("Or clone as"), nameField, nameNote], in: .leading)
        renameGroup.orientation = .vertical
        renameGroup.alignment = .leading
        renameGroup.spacing = 6

        let urlGroup = NSStackView(views: [caption("Repository URL"), urlField, urlNote, clipboardButton])
        let locationRow = row(location, chooseLocation)
        let locationGroup = NSStackView(views: [caption("Location"), locationRow, destination])
        for g in [urlGroup, locationGroup] { g.orientation = .vertical; g.alignment = .leading; g.spacing = 6 }
        cloneGroup.setViews([urlGroup, locationGroup, conflict, renameGroup], in: .leading)
        cloneGroup.orientation = .vertical
        cloneGroup.alignment = .leading
        cloneGroup.spacing = 16

        // Footer
        let adds = NSTextField(labelWithString: "Adds to \(workspace)")
        adds.font = .systemFont(ofSize: 12)
        adds.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1B}"
        primary.target = self
        primary.action = #selector(primaryTapped)
        primary.keyEquivalent = "\r"
        let footer = NSStackView(views: [adds, NSView(), cancel, primary])

        let stack = NSStackView(views: [header, modes, openGroup, cloneGroup, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        for v in [header, modes, openGroup, cloneGroup, footer] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -52).isActive = true
        }
        folderRow.widthAnchor.constraint(equalTo: openGroup.widthAnchor).isActive = true
        for v in [urlGroup, locationGroup, conflict, renameGroup, urlField, urlNote, locationRow, destination, nameField, nameNote] as [NSView] {
            v.widthAnchor.constraint(equalTo: cloneGroup.widthAnchor).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        window.contentView = stack

        reloadLocations()
        readClipboard()
        modes.select(cloning ? 1 : 0, animated: false)
        setMode(cloning)
    }

    func begin(on parent: NSWindow) {
        window.appearance = parent.appearance
        parent.beginSheet(window)
        window.makeFirstResponder(cloning ? urlField : nil)
    }

    // MARK: Pieces

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// A control filling the row and a fixed button after it.
    private func row(_ fill: NSView, _ button: NSButton) -> NSStackView {
        let r = NSStackView(views: [fill, button])
        r.spacing = 8
        fill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return r
    }

    private func reloadLocations() {
        location.removeAllItems()
        for path in locations {
            location.addItem(withTitle: (path as NSString).abbreviatingWithTildeInPath)
            location.lastItem?.representedObject = path
        }
        location.menu?.addItem(.separator())
        location.addItem(withTitle: "Choose Other…")
        location.selectItem(at: 0)
    }

    private var parent: String { locations.first ?? NSHomeDirectory() }

    /// A git remote on the clipboard is offered under the empty field. The clipboard is read only when the user has
    /// let this app paste without asking; otherwise a URL is detected without reading it, and read on click.
    private func readClipboard() {
        let pb = NSPasteboard.general
        if pb.accessBehavior == .alwaysAllow {
            if let remote = pb.string(forType: .string).flatMap(GitRemote.init) {
                clipboardButton.title = "Use clipboard: \(remote.url)"
                clipboardOffered = true
            }
            return
        }
        Task { [weak self] in
            guard await Self.clipboardHasURL(), let self else { return }
            clipboardButton.title = "Paste URL from Clipboard"
            clipboardOffered = true
            update()
        }
    }

    private nonisolated static func clipboardHasURL() async -> Bool {
        (try? await NSPasteboard.general.detectedPatterns(for: [\.probableWebURL]))?.contains(\.probableWebURL) ?? false
    }

    // MARK: State

    private func setMode(_ clone: Bool) {
        cloning = clone
        modes.select(clone ? 1 : 0, animated: true)
        openGroup.isHidden = clone
        cloneGroup.isHidden = !clone
        if clone { window.makeFirstResponder(urlField) }
        update()
    }

    private var remote: GitRemote? { GitRemote(urlField.stringValue) }

    /// The folder the clone would make, and whether it is free.
    private var target: (name: String, path: String, free: Bool)? {
        guard let remote else { return nil }
        let derived = (parent as NSString).appendingPathComponent(remote.folder)
        let name = FileManager.default.fileExists(atPath: derived) ? nameField.stringValue.trimmingCharacters(in: .whitespaces) : remote.folder
        let path = (parent as NSString).appendingPathComponent(name)
        let ok = !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        return (name, path, ok && !FileManager.default.fileExists(atPath: path))
    }

    private func update() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let remote = remote
        urlNote.isHidden = text.isEmpty
        if let remote {
            urlNote.stringValue = "✓ \(remote.host) · \(remote.path)"
            urlNote.textColor = .systemGreen
        } else {
            urlNote.stringValue = "Not a Git URL. Use https://…, ssh://… or git@host:org/repo."
            urlNote.textColor = .systemRed
        }
        clipboardButton.isHidden = !text.isEmpty || !clipboardOffered

        var taken = false
        if let remote {
            let derived = (parent as NSString).appendingPathComponent(remote.folder)
            taken = FileManager.default.fileExists(atPath: derived)
            if taken { describeConflict(derived, remote) }
        }
        conflict.isHidden = !taken
        renameGroup.isHidden = !taken
        conflict.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.1).cgColor
        conflict.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor

        let t = target
        destination.isHidden = t == nil || taken
        if let t { destination.stringValue = "Clones into \((t.path as NSString).abbreviatingWithTildeInPath)" }
        if taken, let t {
            nameNote.stringValue = t.free ? "Clones into \((t.path as NSString).abbreviatingWithTildeInPath)" : t.name.isEmpty ? "Enter a folder name" : "\(t.name) exists too"
            nameNote.textColor = t.free ? .secondaryLabelColor : .systemRed
        }

        primary.title = cloning ? "Clone" : "Add Project"
        primary.isEnabled = cloning ? t?.free == true : folder != nil
        folderButton.title = folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen"
        fit()
    }

    private func describeConflict(_ path: String, _ remote: GitRemote) {
        let short = (path as NSString).abbreviatingWithTildeInPath
        conflictTitle.stringValue = "\(short) already exists"
        let checkout = GitRemote.checkout(at: path)
        let same = checkout?.origin.flatMap(GitRemote.init).map { $0.sameRepository(as: remote) } ?? false
        if same {
            conflictDetail.stringValue = "It’s a clone of this repository (origin matches" + (checkout?.branch.map { ", branch \($0))." } ?? ").")
        } else if let origin = checkout?.origin {
            conflictDetail.stringValue = "It’s a clone of another repository: \(origin)."
        } else {
            conflictDetail.stringValue = checkout == nil ? "It isn’t a Git clone." : "It’s a Git repository with no origin."
        }
        openExisting.isHidden = !same
        // Suggest the first free name, once per derived folder, so a name being typed is left alone.
        if renamedFor != path {
            renamedFor = path
            var n = 2
            while FileManager.default.fileExists(atPath: path + "-\(n)") { n += 1 }
            nameField.stringValue = "\(remote.folder)-\(n)"
        }
    }

    private func fit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if window.frame.size.height != size.height || window.contentLayoutRect.width != size.width {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    // MARK: Actions

    @objc private func useClipboard() {
        let read = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        urlField.stringValue = GitRemote(read)?.url ?? read
        window.makeFirstResponder(urlField)
        update()
    }

    @objc private func locationPicked() {
        guard let path = location.selectedItem?.representedObject as? String else { return chooseLocation() }
        locations.removeAll { $0 == path }
        locations.insert(path, at: 0)
        reloadLocations()
        renamedFor = nil
        update()
    }

    @objc private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: parent)
        panel.beginSheetModal(for: window) { [self] r in
            if r == .OK, let url = panel.url {
                locations.removeAll { $0 == url.path }
                locations.insert(url.path, at: 0)
                renamedFor = nil
            }
            reloadLocations()
            update()
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [self] r in
            if r == .OK, let url = panel.url { folder = url }
            update()
        }
    }

    @objc private func openExistingTapped() {
        guard let remote else { return }
        finish(.open(URL(fileURLWithPath: (parent as NSString).appendingPathComponent(remote.folder))))
    }

    @objc private func primaryTapped() {
        if cloning {
            guard let remote, let t = target, t.free else { return }
            finish(.clone(remote, into: t.path))
        } else if let folder {
            finish(.open(folder))
        }
    }

    @objc private func cancelTapped() { finish(nil) }

    private func finish(_ result: Result?) {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        onDone(result)
    }
}
