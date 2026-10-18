import AppKit

struct SidebarRow: Equatable, Sendable { let name: String; let path: String; let status: PaneStatus; let terminals: Int; let agents: Int }

enum PaneStatus: Int, Comparable, Sendable {
    case idle = 0, busy = 1, done = 2, attention = 3
    static func < (l: PaneStatus, r: PaneStatus) -> Bool { l.rawValue < r.rawValue }
}

private final class SidebarTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Two lines: the project name, and what is open in it (terminals, running agents).
private final class SidebarCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        textField = label
        for v in [label, detail, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
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
        glass.frame = bounds.insetBy(dx: Self.inset, dy: 0)
        hover.frame = glass.frame
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

/// One compact line per scratch terminal: title and status dot (no glyph).
private final class ScratchCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        textField = label
        for v in [label, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
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
    private static let rowHeight: CGFloat = 28, spacing: CGFloat = 2, maxRows = 4

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
        let changed = rows != self.rows
        self.rows = rows
        self.selected = selected
        self.theme = theme
        height.constant = CGFloat(min(rows.count, Self.maxRows)) * (Self.rowHeight + Self.spacing)
        if changed { table.reloadData() }
        syncing = true
        if selected >= 0, selected < rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) } else { table.deselectAll(nil) }
        syncing = false
        for r in 0..<rows.count {
            if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ScratchCell { style(cell, row: r) }
        }
    }

    private func style(_ cell: ScratchCell, row: Int) {
        guard let theme, row < rows.count else { return }
        cell.label.stringValue = rows[row].name
        cell.toolTip = rows[row].path
        styleStatusDot(cell.dot, rows[row].status, theme: theme)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ScratchCell(frame: .zero)
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard !syncing, r >= 0, r != selected else { return }
        selected = r   // optimistic; the controller's update confirms
        onSelect?(r)
    }
}

/// The project list: a native source list inside the split view's sidebar item (AppKit supplies the glass, the
/// collapse and the insets). Selection is the active project; reordering is native table drag and drop.
/// A segmented control above the list switches between active and hidden projects; every index here is a row of
/// the list being shown (the controller maps rows to projects). The table's first row is the non-selectable
/// "Projects" group header; the public indices exclude it (see projectRow(forTableRow:)). Pinned below the list:
/// a separator, the scratch terminals (not projects), and the Scratch Terminal button.
@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
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
    private var needsReload = false   // rows changed while a name was being edited
    private var syncing = false       // programmatic selection: don't report it as a click
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
        table.rowHeight = 46
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 0, height: 4)
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
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameTapped), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove Project…", action: #selector(removeTapped), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
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
        newScratch.bezelStyle = .glass   // a full-width glass capsule, like the toggle at the top
        newScratch.borderShape = .capsule
        newScratch.controlSize = .large
        newScratch.imagePosition = .imageLeading
        newScratch.imageHugsTitle = true
        newScratch.font = .systemFont(ofSize: 13, weight: .medium)
        newScratch.refusesFirstResponder = true
        newScratch.toolTip = "New Scratch Terminal (⇧⌘N)"
        scratchList.onSelect = { [unowned self] i in onSelectScratch?(i) }
        scratchList.onClose = { [unowned self] i in onCloseScratch?(i) }

        for v in [scroll, filter, separator, scratchList.scroll, newScratch] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),   // below the toolbar
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: scratchList.scroll.topAnchor, constant: -6),
            scratchList.scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scratchList.scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scratchList.scroll.bottomAnchor.constraint(equalTo: newScratch.topAnchor, constant: -6),
            newScratch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            newScratch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newScratch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func newScratchTapped() { onNewScratch?() }

    @objc private func toggleHiddenTapped() {
        if let r = projectRow(forTableRow: table.clickedRow) { onToggleHidden?(r) }
    }

    @objc private func renameTapped() { beginRename(table.clickedRow) }

    @objc private func rowDoubleClicked() { beginRename(table.clickedRow) }

    private func beginRename(_ tableRow: Int) {
        guard let r = projectRow(forTableRow: tableRow),
              let cell = table.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? SidebarCell else { return }
        InlineRename(cell.label) { [weak self] name in
            guard let self else { return }
            if needsReload { needsReload = false; table.reloadData() }
            onRename?(r, name)
        }
    }

    @objc private func removeTapped() {
        if let r = projectRow(forTableRow: table.clickedRow) { onRemove?(r) }
    }

    private func select(_ r: Int) {
        syncing = true
        if r >= 0, r < rows.count { table.selectRowIndexes([tableRow(forProjectRow: r)], byExtendingSelection: false) } else { table.deselectAll(nil) }
        syncing = false
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
        let changed = rows != self.rows
        self.rows = rows
        self.selected = selected
        self.theme = theme

        // Reloading would destroy a name field mid-edit; the rename's end reloads instead.
        if changed { if InlineRename.isEditing { needsReload = true } else { table.reloadData() } }
        select(selected)
        for r in 0..<rows.count {
            if let cell = table.view(atColumn: 0, row: tableRow(forProjectRow: r), makeIfNecessary: false) as? SidebarCell { style(cell, row: r) }
        }
    }

    private func style(_ cell: SidebarCell, row: Int) {
        guard let theme, row < rows.count else { return }
        let r = rows[row]
        if !cell.label.isEditable { cell.label.stringValue = r.name }
        cell.detail.stringValue = sidebarDetail(terminals: r.terminals, agents: r.agents)
        cell.toolTip = r.path
        styleStatusDot(cell.dot, r.status, theme: theme)
    }


    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row != 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { row == 0 ? 24 : 46 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { row == 0 ? nil : GlassRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let r = projectRow(forTableRow: row) else {
            let header = NSTextField(labelWithString: "Projects")
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(header)
            NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                                         header.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let cell = SidebarCell(frame: .zero)
        style(cell, row: r)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let r = projectRow(forTableRow: table.selectedRow) else { return }
        guard !syncing, r != selected else { return }
        selected = r   // optimistic; the controller's update() confirms
        onSelect?(r)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let r = projectRow(forTableRow: row) else { return nil }   // the header can't be dragged
        let item = NSPasteboardItem()
        item.setString(String(r), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as AnyObject === table else { return [] }
        if op == .on || row < 1 { tableView.setDropRow(max(row, 1), dropOperation: .above) }   // never above the header
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s), rows.indices.contains(from) else { return false }
        let dest = max(row - 1, 0)   // insertion point as a project row
        let to = dest > from ? dest - 1 : dest
        guard to != from else { return false }
        rows.insert(rows.remove(at: from), at: to)
        if selected == from { selected = to } else if from < selected, selected <= to { selected -= 1 } else if to <= selected, selected < from { selected += 1 }
        table.moveRow(at: tableRow(forProjectRow: from), to: tableRow(forProjectRow: to))
        select(selected)
        onMove?(from, to)
        return true
    }
}
