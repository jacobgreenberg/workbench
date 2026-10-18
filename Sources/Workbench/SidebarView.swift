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
}

/// One line for a project or scratch terminal: name, then status dot (hidden when idle) and tab count on the right.
private final class ProjectCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textField = label
        let trailing = NSStackView(views: [dot, count])   // hidden members drop out of the stack
        trailing.spacing = 8
        for v in [label, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor func style(_ r: SidebarRow, selected: Bool, theme: Theme) {
        if !label.isEditable { label.stringValue = r.name }
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = r.tabCount == 0 && !selected ? .tertiaryLabelColor : .labelColor
        count.stringValue = String(r.tabCount)
        count.isHidden = r.tabCount == 0
        count.textColor = selected ? .secondaryLabelColor : .tertiaryLabelColor
        toolTip = r.path
        styleStatusDot(dot, r.status, theme: theme)
    }
}

/// Selected rows are a Liquid Glass capsule inset from the edges instead of the flat source-list fill; a faint
/// capsule shows under the pointer. The sidebar is not over a terminal, so glass is fine here.
private final class GlassRowView: NSTableRowView {
    private let glass = NSGlassEffectView()
    private let hover = NSView()
    private static let inset: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 10
        glass.alphaValue = 0
        hover.wantsLayer = true
        hover.layer?.cornerRadius = 10
        hover.isHidden = true
        addSubview(hover)
        addSubview(glass)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: Self.inset, dy: 1)
        hover.frame = glass.frame
    }

    /// A quiet resting card, so rows read as separate items without any glass; selection is the glass over it.
    override func drawBackground(in dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        card.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        card.lineWidth = 0.5
        card.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {}   // the glass is the selection
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }   // keep label colors on glass

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            hover.isHidden = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                glass.animator().alphaValue = isSelected ? 1 : 0
            }
        }
    }

    override func mouseEntered(with event: NSEvent) { if !isSelected { showHover(true) } }
    override func mouseExited(with event: NSEvent) { showHover(false) }

    private func showHover(_ on: Bool) {
        hover.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        hover.isHidden = !on
    }
}

/// The scratch terminals under the project list: a small source-list table (native selection look) that hugs its rows.
@MainActor private final class ScratchList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    let scroll = NSScrollView()
    private let table = SidebarTable()
    private let height: NSLayoutConstraint
    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var syncing = false
    private static let rowHeight: CGFloat = 34, spacing: CGFloat = 2, maxRows = 4

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
        height.constant = CGFloat(min(rows.count, Self.maxRows)) * (Self.rowHeight + Self.spacing)
        if changed { table.reloadData() }
        syncing = true
        if selected >= 0, selected < rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
        syncing = false
        for r in 0..<rows.count {
            if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ProjectCell { style(cell, row: r) }
        }
    }

    private func style(_ cell: ProjectCell, row: Int) {
        if let theme, rows.indices.contains(row) { cell.style(rows[row], selected: row == selected, theme: theme) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ProjectCell(frame: .zero)
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard !syncing, r >= 0, r != selected else { return }
        onSelect?(r)
    }
}

/// The project list: a native source list inside the split view's sidebar item (AppKit supplies the glass, the
/// collapse and the insets). One line per project; selection is the active project. Reordering is native table
/// drag and drop.
/// A large "Projects" title, then a segmented control that switches between active and hidden projects; project
/// indices here are rows of the list being shown (the controller maps them to projects).
/// Pinned below the list: a separator, the scratch terminals (not projects), and the Scratch Terminal button.
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

    private static let dragType = NSPasteboard.PasteboardType("dev.workbench.sidebar-row")
    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var hiddenCount = 0
    private var showingHidden = false
    private var syncing = false       // programmatic selection/updates: don't report them as clicks
    private let table = SidebarTable()
    private let filter = GlassSegments(labels: ["Active", "Hidden"])
    private let scratchList = ScratchList()
    private let toggleItem = NSMenuItem(title: "Hide Project", action: #selector(toggleHiddenTapped), keyEquivalent: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        filter.onSelect = { [unowned self] i in onShowHidden?(i == 1) }
        filter.select(0, animated: false)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.draggingDestinationFeedbackStyle = .gap
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        let separator = NSBox()
        separator.boxType = .separator
        let newScratch = NSButton(title: "Scratch Terminal", image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Scratch Terminal")!,
                                  target: self, action: #selector(newScratchTapped))
        newScratch.isBordered = false   // plain secondary text: the sidebar's only glass is the selection
        newScratch.imagePosition = .imageLeading
        newScratch.imageHugsTitle = true
        newScratch.contentTintColor = .secondaryLabelColor
        newScratch.font = .systemFont(ofSize: 12, weight: .medium)
        newScratch.refusesFirstResponder = true
        newScratch.toolTip = "New Scratch Terminal (⇧⌘N)"
        scratchList.onSelect = { [unowned self] i in onSelectScratch?(i) }
        scratchList.onClose = { [unowned self] i in onCloseScratch?(i) }

        let title = NSTextField(labelWithString: "Projects")   // a large title, like Mail's or Notes' sidebar
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .labelColor
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("Projects")

        for v in [title, scroll, filter, separator, scratchList.scroll, newScratch] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),   // below the toolbar
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            filter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: scratchList.scroll.topAnchor, constant: -6),
            scratchList.scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scratchList.scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scratchList.scroll.bottomAnchor.constraint(equalTo: newScratch.topAnchor, constant: -6),
            newScratch.centerXAnchor.constraint(equalTo: centerXAnchor),
            newScratch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }


    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func newScratchTapped() { onNewScratch?() }

    // MARK: Menu and clicks

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if rows.indices.contains(table.clickedRow) {
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameTapped), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Remove Project…", action: #selector(removeTapped), keyEquivalent: ""))
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func toggleHiddenTapped() { if rows.indices.contains(table.clickedRow) { onToggleHidden?(table.clickedRow) } }

    @objc private func removeTapped() { if rows.indices.contains(table.clickedRow) { onRemove?(table.clickedRow) } }

    @objc private func renameTapped() { beginRename(table.clickedRow) }

    @objc private func rowDoubleClicked() { beginRename(table.clickedRow) }

    private func beginRename(_ row: Int) {
        guard rows.indices.contains(row), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCell else { return }
        InlineRename(cell.label) { [weak self] name in self?.onRename?(row, name) }
    }

    private func select() {
        syncing = true
        defer { syncing = false }
        if rows.indices.contains(selected) { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    /// The scratch terminals pinned under the list (`selected` -1 = none).
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
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCell { style(cell, row: row) }
        }
    }

    private func style(_ cell: ProjectCell, row: Int) {
        if let theme, rows.indices.contains(row) { cell.style(rows[row], selected: row == selected, theme: theme) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ProjectCell(frame: .zero)
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        if !syncing, r >= 0, r != selected { onSelect?(r) }   // the controller's update() confirms
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as AnyObject === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s), rows.indices.contains(from) else { return false }
        let to = row > from ? row - 1 : row
        guard to != from else { return false }
        rows.insert(rows.remove(at: from), at: to)
        if selected == from { selected = to } else if from < selected, selected <= to { selected -= 1 } else if to <= selected, selected < from { selected += 1 }
        syncing = true
        table.moveRow(at: from, to: to)
        syncing = false
        select()
        restyleVisible()
        onMove?(from, to)
        return true
    }
}
