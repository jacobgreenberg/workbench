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

/// One line for a scratch terminal: SF Symbol, name, then status dot (hidden when idle) and tab count on the
/// right. The symbol is what makes rows read as separate items, as in Finder's and Mail's sidebars.
private final class ProjectCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    let count = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")   // optional shortcut hint, trailing (empty = hidden)

    init(symbol: String) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.isHidden = true
        textField = label
        let trailing = NSStackView(views: [dot, count, hint])   // hidden members drop out of the stack
        trailing.spacing = 8
        for v in [icon, label, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    override init(frame: NSRect) { fatalError("use init(symbol:)") }
    required init?(coder: NSCoder) { fatalError() }

    @MainActor func style(_ r: SidebarRow, selected: Bool, theme: Theme) {
        if !label.isEditable { label.stringValue = r.name }
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = r.tabCount == 0 && !selected ? .tertiaryLabelColor : .labelColor
        icon.contentTintColor = r.tabCount == 0 && !selected ? .tertiaryLabelColor : .secondaryLabelColor
        count.stringValue = String(r.tabCount)
        count.isHidden = r.tabCount == 0
        count.textColor = selected ? .secondaryLabelColor : .tertiaryLabelColor
        toolTip = r.path
        styleStatusDot(dot, r.status, theme: theme)
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

/// Scratch rows: a soft rounded bar (5% label fill, 9% on hover), soft grey fill when selected; no glass, no border. The
/// spacing between rows is drawn inside the row.
private final class FlatRowView: NSTableRowView {
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var bar: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 3), xRadius: 10, yRadius: 10) }
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(hovered ? 0.09 : 0.055).setFill()
        bar.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        bar.fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The scratch terminals under the project list: one "Scratch Terminal" row that is also the button. With none open,
/// clicking it makes one; otherwise it selects it. A flat table (no glass) that hugs its rows.
@MainActor private final class ScratchList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    let scroll = NSScrollView()
    private let table = SidebarTable()
    private let height: NSLayoutConstraint
    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var syncing = false
    private static let rowHeight: CGFloat = 46, spacing: CGFloat = 0, maxRows = 4

    override init() {
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        super.init()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: Self.spacing)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        let close = NSMenuItem(title: "Close", action: #selector(closeTapped), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        table.menu = menu
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        height.isActive = true
    }

    @objc private func closeTapped() {
        let r = table.clickedRow
        if r >= 0 { onClose?(r) }
    }

    func update(rows: [SidebarRow], selected: Int, theme: Theme) {
        guard rows != self.rows || selected != self.selected || theme.id != self.theme?.id else { return }
        let changed = rows.map(\.id) != self.rows.map(\.id)
        self.rows = rows
        self.selected = selected
        self.theme = theme
        height.constant = CGFloat(min(max(rows.count, 1), Self.maxRows)) * (Self.rowHeight + Self.spacing)
        if changed { table.reloadData() }
        syncing = true
        if selected >= 0, selected < rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
        syncing = false
        for r in 0..<max(rows.count, 1) {
            if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ProjectCell { style(cell, row: r) }
        }
    }

    private static let placeholder = SidebarRow(id: UUID(), name: "Scratch Terminal", path: "New scratch terminal (⇧⌘N)", status: .idle)

    private func style(_ cell: ProjectCell, row: Int) {
        guard let theme else { return }
        defer {
            cell.label.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.label.textColor = NSColor.labelColor.withAlphaComponent(0.85)
            cell.hint.stringValue = "⇧⌘N"
            cell.hint.isHidden = row != 0
            cell.hint.textColor = .tertiaryLabelColor
        }
        if rows.indices.contains(row) { cell.style(rows[row], selected: row == selected, theme: theme); return }
        cell.style(Self.placeholder, selected: false, theme: theme)   // none open: the same row, not dimmed
        cell.icon.contentTintColor = .secondaryLabelColor
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(rows.count, 1) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ProjectCell(symbol: "terminal")
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard !syncing, r >= 0, r != selected else { return }
        if rows.isEmpty { table.deselectAll(nil); onNew?() } else { onSelect?(r) }
    }
}

/// The sidebar: the workspace rail at the leading edge, and beside it the active workspace's projects, a native
/// source list inside the split view's sidebar item (AppKit supplies the glass, the collapse and the insets).
/// The workspace's name as a large title, then a segmented control that switches between active and hidden
/// projects; project indices here are rows of the list being shown (the controller maps them to projects).
/// Two lines per project; selection is the active project. Reordering is a press-and-drag on a row (Reorder, as with tabs): the row lifts, the others slide aside.
/// Pinned below the list: the scratch terminals (not projects; the first row is also the button).
@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Int) -> Void)?
    var onShowHidden: ((Bool) -> Void)?   // segment picked: true = Hidden
    var onToggleHidden: ((Int) -> Void)?   // context menu Hide/Show Project
    var onRemove: ((Int) -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to (final index after removal)
    var onSelectScratch: ((Int) -> Void)?   // indices are rows of the scratch list
    var onCloseScratch: ((Int) -> Void)?
    var onNewScratch: (() -> Void)?
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
    private let scratchList = ScratchList()
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
        table.selectionHighlightStyle = .regular
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

        scratchList.onSelect = { [unowned self] i in onSelectScratch?(i) }
        scratchList.onNew = { [unowned self] in onNewScratch?() }
        scratchList.onClose = { [unowned self] i in onCloseScratch?(i) }

        title.font = .systemFont(ofSize: 26, weight: .bold)   // a large title, like Mail's or Notes' sidebar
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let content = NSLayoutGuide()   // everything right of the rail
        addLayoutGuide(content)
        for v in [rail, title, scroll, filter, scratchList.scroll] as [NSView] {
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
            scroll.bottomAnchor.constraint(equalTo: scratchList.scroll.topAnchor, constant: -8),
            scratchList.scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scratchList.scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scratchList.scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }


    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Menu and clicks

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if rows.indices.contains(table.clickedRow) {
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameTapped), keyEquivalent: ""))
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
            menu.addItem(NSMenuItem(title: "Remove Project…", action: #selector(removeTapped), keyEquivalent: ""))
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func toggleHiddenTapped() { if rows.indices.contains(table.clickedRow) { onToggleHidden?(table.clickedRow) } }

    @objc private func removeTapped() { if rows.indices.contains(table.clickedRow) { onRemove?(table.clickedRow) } }

    @objc private func moveTapped(_ sender: NSMenuItem) {
        if rows.indices.contains(table.clickedRow) { onMoveToWorkspace?(table.clickedRow, sender.tag) }
    }

    @objc private func renameTapped() { beginRename(table.clickedRow) }

    @objc private func rowDoubleClicked() { beginRename(table.clickedRow) }

    private func beginRename(_ row: Int) {
        guard rows.indices.contains(row), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectRowCell else { return }
        InlineRename(cell.label) { [weak self] name in self?.onRename?(row, name) }
    }

    private func select() {
        syncing = true
        defer { syncing = false }
        if rows.indices.contains(selected) { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    /// The scratch terminals pinned under the list (`selected` -1 = none).
    /// The rail, and the title naming the selected workspace.
    func updateWorkspaces(_ items: [WorkspaceItem], selected: Int, theme: Theme) {
        workspaces = items
        workspace = selected
        title.stringValue = items.indices.contains(selected) ? items[selected].name : ""
        rail.update(items, selected: selected, theme: theme)
    }

    func updateScratch(rows: [SidebarRow], selected: Int, theme: Theme) {
        scratchList.update(rows: rows, selected: selected, theme: theme)
    }

    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme) {
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
