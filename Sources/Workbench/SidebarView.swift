import AppKit

/// `tabCount`: shown at the right of the row (omitted when 0; a project with none is dimmed).
struct SidebarRow: Equatable, Sendable {
    let id: UUID; let name: String; let path: String; let status: PaneStatus; var tabCount = 0
}

enum PaneStatus: Int, Comparable, Sendable {
    case idle = 0, busy = 1, done = 2, attention = 3
    static func < (l: PaneStatus, r: PaneStatus) -> Bool { l.rawValue < r.rawValue }
}

private final class SidebarTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    /// A single left press on a row; return true when handled (the project table's drag-to-reorder). Else normal handling.
    var onPress: ((NSEvent, Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 1, row >= 0, onPress?(event, row) == true { return }
        super.mouseDown(with: event)
    }
}

/// A project row: status dot (a hollow ring when nothing is open), name, and what it is doing underneath.
private final class ProjectRowCell: NSTableCellView {
    let dot = NSView()
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13.5, weight: .semibold)
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11.5)
        let text = NSStackView(views: [label, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [dot, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor func style(_ r: SidebarRow, selected: Bool, theme: Theme) {
        if !label.isEditable { label.stringValue = r.name }
        let empty = r.tabCount == 0
        label.textColor = selected ? .labelColor : empty ? .secondaryLabelColor : .labelColor
        detail.textColor = .secondaryLabelColor
        detail.stringValue = switch r.status {
        case .attention: "Needs you"
        case .busy: "Working…"
        case .done: "Done"
        case .idle: empty ? "Nothing open" : r.tabCount == 1 ? "1 tab" : "\(r.tabCount) tabs"
        }
        toolTip = r.path
        styleStatusDot(dot, r.status, theme: theme)
        dot.isHidden = false
        if r.status == .idle {   // idle: grey dot with tabs open, hollow ring without
            let grey = selected ? NSColor.secondaryLabelColor : .tertiaryLabelColor
            dot.layer?.backgroundColor = empty ? .clear : grey.cgColor
            dot.layer?.borderColor = grey.cgColor
            dot.layer?.borderWidth = empty ? 1.5 : 0
        } else {
            dot.layer?.borderWidth = 0
        }
    }
}

/// A sidebar row's bar: the same horizontal extent as the Active/Hidden switch above (4 pt in from the rail, 12 pt from
/// the edge).
private func rowBar(_ bounds: NSRect, dy: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: 4, y: bounds.minY + dy, width: bounds.width - 16, height: bounds.height - 2 * dy), xRadius: 10, yRadius: 10)
}

/// The selected project row: the app's one selection look (label color at 15%, as the tab bar and switches) instead of
/// the source list's own highlight.
private final class SelectionRowView: NSTableRowView {
    override var isSelected: Bool { didSet { if isSelected != oldValue { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        rowBar(bounds, dy: 1).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

let vsCodeBundle = "com.microsoft.VSCode"

/// Context menus offer an app only when this Mac has it.
@MainActor func hasApp(_ bundle: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }

/// Opens `url` with the app, if this Mac has it.
@MainActor func openWith(_ bundle: String, _ url: URL) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}

/// The sidebar: the workspace rail at the leading edge, and beside it the active workspace's projects, a native
/// source list inside the split view's sidebar item (AppKit supplies the glass, the collapse and the insets).
/// The workspace's name as a large title, then a segmented control that switches between active and hidden
/// projects; project indices here are rows of the list being shown (the controller maps them to projects).
/// Two lines per project; selection is the active project. Reordering is a press-and-drag on a row (Reorder, as with tabs): the row lifts, the others slide aside.
@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Int) -> Void)?
    var onShowHidden: ((Bool) -> Void)?   // segment picked: true = Hidden
    var onToggleHidden: ((Int) -> Void)?   // context menu Hide/Show Project
    var onRemove: ((Int) -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to (final index after removal)
    var onMoveToWorkspace: ((Int, Int) -> Void)?   // project row, workspace index
    let rail = WorkspaceRail()

    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var hiddenCount = 0
    private var showingHidden = false
    private var syncing = false       // programmatic selection/updates: don't report them as clicks
    private let table = SidebarTable()
    private let filter = GlassSegments(labels: ["Active", "Hidden"])
    private let title = NSTextField(labelWithString: "")
    private var workspaces: [WorkspaceItem] = []
    private var workspace = -1
    private let toggleItem = NSMenuItem(title: "Hide Project", action: #selector(toggleHiddenTapped), keyEquivalent: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        filter.onSelect = { [unowned self] i in onShowHidden?(i == 1) }
        filter.select(0, animated: false)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.rowHeight = 46
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none   // SelectionRowView draws it
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.onPress = { [unowned self] e, row in press(e, row: row) }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        title.font = .systemFont(ofSize: 26, weight: .bold)   // a large title, like Mail's or Notes' sidebar
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let content = NSLayoutGuide()   // everything right of the rail
        addLayoutGuide(content)
        for v in [rail, title, scroll, filter] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),   // below the toolbar
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            filter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            filter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }


    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Menu and clicks

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if rows.indices.contains(table.clickedRow) {
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameTapped), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Copy Path", action: #selector(copyPathTapped), keyEquivalent: ""))
            if workspaces.count > 1 {
                let move = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
                move.submenu = NSMenu()
                for (i, w) in workspaces.enumerated() where i != workspace {
                    let item = NSMenuItem(title: w.name, action: #selector(moveTapped), keyEquivalent: "")
                    item.tag = i
                    item.target = self
                    move.submenu?.addItem(item)
                }
                menu.addItem(move)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealTapped), keyEquivalent: ""))
            if hasApp(vsCodeBundle) { menu.addItem(NSMenuItem(title: "Open in VS Code", action: #selector(openInVSCodeTapped), keyEquivalent: "")) }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Remove Project…", action: #selector(removeTapped), keyEquivalent: ""))
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func toggleHiddenTapped() { if rows.indices.contains(table.clickedRow) { onToggleHidden?(table.clickedRow) } }

    @objc private func copyPathTapped() {
        guard rows.indices.contains(table.clickedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows[table.clickedRow].path, forType: .string)
    }

    @objc private func revealTapped() {
        guard rows.indices.contains(table.clickedRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rows[table.clickedRow].path)])
    }

    @objc private func openInVSCodeTapped() {
        guard rows.indices.contains(table.clickedRow) else { return }
        openWith(vsCodeBundle, URL(fileURLWithPath: rows[table.clickedRow].path))
    }

    @objc private func removeTapped() { if rows.indices.contains(table.clickedRow) { onRemove?(table.clickedRow) } }

    @objc private func moveTapped(_ sender: NSMenuItem) {
        if rows.indices.contains(table.clickedRow) { onMoveToWorkspace?(table.clickedRow, sender.tag) }
    }

    @objc private func renameTapped() { beginRename(table.clickedRow) }

    @objc private func rowDoubleClicked() { beginRename(table.clickedRow) }

    private func beginRename(_ row: Int) {
        guard rows.indices.contains(row), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectRowCell else { return }
        // The label hugs its text; stretch it to the row edge while editing so there is room to type.
        let fill = cell.label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16)
        fill.isActive = true
        InlineRename(cell.label) { [weak self] name in
            fill.isActive = false
            self?.onRename?(row, name)
        }
    }

    private func select() {
        syncing = true
        defer { syncing = false }
        if rows.indices.contains(selected) { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    /// The rail, and the title naming the selected workspace.
    func updateWorkspaces(_ items: [WorkspaceItem], selected: Int, theme: Theme) {
        workspaces = items
        workspace = selected
        title.stringValue = items.indices.contains(selected) ? items[selected].name : ""
        rail.update(items, selected: selected, theme: theme)
    }

    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme) {
        filter.tint = theme.color("foreground")
        if hiddenCount != self.hiddenCount || showingHidden != self.showingHidden {
            self.hiddenCount = hiddenCount
            self.showingHidden = showingHidden
            filter.setLabel(hiddenCount > 0 ? "Hidden · \(hiddenCount)" : "Hidden", at: 1)
            filter.select(showingHidden ? 1 : 0, animated: true)
            toggleItem.title = showingHidden ? "Show Project" : "Hide Project"
        }
        guard rows != self.rows || selected != self.selected || theme.id != self.theme?.id else { return }
        guard !InlineRename.isEditing else { return }   // a name field is live; the rename's end re-renders
        let reload = rows.map(\.id) != self.rows.map(\.id)
        self.rows = rows
        self.selected = selected
        self.theme = theme
        if reload { syncing = true; table.reloadData(); syncing = false }
        select()
        restyleVisible()
    }

    /// Everything on screen is styled in place, so a status dot, count or name change never rebuilds or flashes a row.
    private func restyleVisible() {
        for row in rows.indices {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectRowCell { style(cell, row: row) }
        }
    }

    private func style(_ cell: ProjectRowCell, row: Int) {
        if let theme, rows.indices.contains(row) { cell.style(rows[row], selected: row == selected, theme: theme) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ProjectRowCell()
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        if !syncing, r >= 0, r != selected { onSelect?(r) }   // the controller's update() confirms
    }

    // MARK: Reorder

    private let reorder = Reorder(vertical: true)

    /// Press on a row: a drag lifts it and slides the others (rows are layer-backed views moved by transforms); a press
    /// released before the 4 pt threshold is a click and selects the row, which reports once via the selection change.
    private func press(_ event: NSEvent, row: Int) -> Bool {
        let views = rows.indices.compactMap { table.rowView(atRow: $0, makeIfNecessary: false) }
        guard views.count == rows.count, !InlineRename.isEditing else { return false }
        views.forEach { $0.wantsLayer = true }
        let y0 = table.convert(event.locationInWindow, from: nil).y
        var dragged = false
        trackDrag(from: event, in: table.window) { [self] p, done in
            dragged = true
            reorder.drag(views, row, by: table.convert(p, from: nil).y - y0, done: done) { [self] from, to in
                rows.insert(rows.remove(at: from), at: to)
                if selected == from { selected = to } else if from < selected, selected <= to { selected -= 1 } else if to <= selected, selected < from { selected += 1 }
                syncing = true
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0   // the transforms already show the result; don't slide again
                table.moveRow(at: from, to: to)
                NSAnimationContext.endGrouping()
                syncing = false
                select()
                restyleVisible()
                onMove?(from, to)
            }
        }
        if !dragged { table.selectRowIndexes([row], byExtendingSelection: false) }
        return true
    }
}
