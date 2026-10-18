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
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The project list: a native source list inside the split view's sidebar item (AppKit supplies the glass, the
/// collapse and the insets). Selection is the active project; reordering is native table drag and drop.
@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to (final index after removal)

    private static let dragType = NSPasteboard.PasteboardType("dev.workbench.sidebar-row")
    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var needsReload = false   // rows changed while a name was being edited
    private var syncing = false       // programmatic selection: don't report it as a click
    private let table = SidebarTable()
    private let addButton = HandButton.glass("plus", "Add Project", .large)

    override init(frame: NSRect) {
        super.init(frame: frame)

        addButton.target = self
        addButton.action = #selector(addTapped)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 46
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
        menu.addItem(NSMenuItem(title: "Remove Project", action: #selector(removeTapped), keyEquivalent: ""))
        menu.items[0].target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: 48, right: 0)   // room for the add button
        scroll.documentView = table

        for v in [scroll, addButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func addTapped() { onAdd?() }

    @objc private func rowDoubleClicked() {
        let r = table.clickedRow
        guard r >= 0, let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? SidebarCell else { return }
        InlineRename(cell.label) { [weak self] name in
            guard let self else { return }
            if needsReload { needsReload = false; table.reloadData() }
            onRename?(r, name)
        }
    }

    @objc private func removeTapped() {
        let r = table.clickedRow
        if r >= 0 { onRemove?(r) }
    }

    private func select(_ r: Int) {
        syncing = true
        if r >= 0, r < rows.count { table.selectRowIndexes([r], byExtendingSelection: false) } else { table.deselectAll(nil) }
        syncing = false
    }

    func update(rows: [SidebarRow], selected: Int, theme: Theme) {
        guard rows != self.rows || selected != self.selected || theme.id != self.theme?.id else { return }
        let changed = rows != self.rows
        self.rows = rows
        self.selected = selected
        self.theme = theme

        // Reloading would destroy a name field mid-edit; the rename's end reloads instead.
        if changed { if InlineRename.isEditing { needsReload = true } else { table.reloadData() } }
        select(selected)
        for r in 0..<rows.count {
            if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? SidebarCell { style(cell, row: r) }
        }
    }

    private func style(_ cell: SidebarCell, row: Int) {
        guard let theme, row < rows.count else { return }
        let r = rows[row]
        if !cell.label.isEditable { cell.label.stringValue = r.name }
        cell.detail.attributedStringValue = Self.detail(r)
        cell.toolTip = r.path
        styleStatusDot(cell.dot, r.status, theme: theme)
    }


    /// "􀩼 3  􀆿 2": open terminals, then running agents (Claude/Codex); the agent count only when there is one.
    private static func detail(_ r: SidebarRow) -> NSAttributedString {
        let s = NSMutableAttributedString()
        func add(_ symbol: String, _ n: Int, _ label: String) {
            let a = NSTextAttachment()
            a.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            if s.length > 0 { s.append(NSAttributedString(string: "   ")) }
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " \(n)"))
        }
        add("terminal", r.terminals, "terminals")
        if r.agents > 0 { add("sparkle", r.agents, "agents") }
        s.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarCell(frame: .zero)
        style(cell, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard !syncing, r >= 0, r != selected else { return }
        selected = r   // optimistic; the controller's update() confirms
        onSelect?(r)
    }

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
        table.moveRow(at: from, to: to)
        select(selected)
        onMove?(from, to)
        return true
    }
}
