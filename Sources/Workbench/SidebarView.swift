import AppKit

struct SidebarRow: Equatable, Sendable { let name: String; let path: String; let status: PaneStatus }

enum PaneStatus: Int, Comparable, Sendable {
    case idle = 0, busy = 1, done = 2, attention = 3
    static func < (l: PaneStatus, r: PaneStatus) -> Bool { l.rawValue < r.rawValue }
}

private final class SidebarTable: NSTableView {
    var onPress: ((Int, NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    /// A single click on a row selects it and may become a drag; the table keeps double-clicks (rename).
    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 1, r >= 0, let onPress { onPress(r, event) } else { super.mouseDown(with: event) }
    }
}

private final class SidebarRowView: NSTableRowView {
    var accent = NSColor.clear
    /// The active project. Not `isSelected`: the table owns that and resets it from its own (empty) selection.
    var isCurrent = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard isCurrent else { return }
        accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class SidebarCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(dot)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to (same pick-up, drag and snap as tabs)

    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private var needsReload = false   // rows changed while a name was being edited
    private let table = SidebarTable()
    private let addButton = HandButton()
    private let reorder = Reorder(.y)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        addButton.isBordered = false
        addButton.title = "+"
        addButton.font = .systemFont(ofSize: 14)
        addButton.target = self
        addButton.action = #selector(addTapped)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.onPress = { [unowned self] r, event in
            onSelect?(r)
            let y = event.locationInWindow.y
            trackDrag(from: event, in: window) { [weak self] p, done in self?.drag(r, by: y - p.y, done: done) }
        }
        table.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Remove Project", action: #selector(removeTapped), keyEquivalent: ""))
        menu.items[0].target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        for v in [addButton, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 46),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func addTapped() { onAdd?() }

    /// `dy`: downward pointer movement (the table is flipped).
    private func drag(_ r: Int, by dy: CGFloat, done: Bool) {
        let views = (0..<rows.count).compactMap { table.rowView(atRow: $0, makeIfNecessary: false) }
        guard views.count == rows.count else { return }   // ponytail: needs every row on screen; no autoscroll mid-drag
        reorder.drag(views, r, by: dy, done: done) { [self] from, to in
            rows.insert(rows.remove(at: from), at: to)
            if selected == from { selected = to } else if from < selected, selected <= to { selected -= 1 } else if to <= selected, selected < from { selected += 1 }
            table.reloadData()
            onMove?(from, to)
        }
    }

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

    func update(rows: [SidebarRow], selected: Int, theme: Theme) {
        guard rows != self.rows || selected != self.selected || theme.id != self.theme?.id else { return }
        let changed = rows != self.rows
        self.rows = rows
        self.selected = selected
        self.theme = theme

        layer?.backgroundColor = theme.color("tertiary").cgColor   // a shade off the terminal area
        addButton.attributedTitle = NSAttributedString(string: "+", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .light),
            .foregroundColor: theme.color("mutedForeground"),
        ])

        // Reloading would destroy a name field mid-edit; the rename's end reloads instead.
        if changed { if InlineRename.isEditing { needsReload = true } else { table.reloadData() } }
        for r in 0..<rows.count {
            if let rv = table.rowView(atRow: r, makeIfNecessary: false) as? SidebarRowView {
                style(rv, row: r)
                if let cell = rv.view(atColumn: 0) as? SidebarCell { style(cell, row: r) }
            }
        }
    }

    private func style(_ rv: SidebarRowView, row: Int) {
        guard let theme else { return }
        rv.accent = theme.color("sidebarAccent")
        rv.isCurrent = row == selected
        rv.needsDisplay = true
    }

    private func style(_ cell: SidebarCell, row: Int) {
        guard let theme, row < rows.count else { return }
        let r = rows[row]
        if !cell.label.isEditable { cell.label.stringValue = r.name }
        cell.label.textColor = theme.color(row == selected ? "cardForeground" : "sidebarForeground")
        cell.toolTip = r.path
        styleStatusDot(cell.dot, r.status, theme: theme)
    }

    #if DEBUG
    func rowCenter(_ i: Int) -> NSPoint? {
        rows.indices.contains(i) ? table.convert(NSPoint(x: table.rect(ofRow: i).midX, y: table.rect(ofRow: i).midY), to: nil) : nil
    }
    #endif

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = SidebarRowView()
        style(rv, row: row)
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarCell(frame: .zero)
        style(cell, row: row)
        return cell
    }
}
