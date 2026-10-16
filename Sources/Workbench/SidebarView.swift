import AppKit

struct SidebarRow: Equatable, Sendable { let name: String; let path: String; let status: PaneStatus }

enum PaneStatus: Int, Comparable, Sendable {
    case idle = 0, busy = 1, done = 2, attention = 3
    static func < (l: PaneStatus, r: PaneStatus) -> Bool { l.rawValue < r.rawValue }
}

private final class SidebarTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

private final class SidebarRowView: NSTableRowView {
    var accent = NSColor.clear

    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
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

    private var rows: [SidebarRow] = []
    private var selected = -1
    private var theme: Theme?
    private let table = SidebarTable()
    private let addButton = HandButton()

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
        table.action = #selector(rowClicked)
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

    @objc private func rowClicked() {
        let r = table.clickedRow
        if r >= 0 { onSelect?(r) }
    }

    @objc private func removeTapped() {
        let r = table.clickedRow
        if r >= 0 { onRemove?(r) }
    }

    func update(rows: [SidebarRow], selected: Int, theme: Theme) {
        let changed = rows != self.rows
        self.rows = rows
        self.selected = selected
        self.theme = theme

        layer?.backgroundColor = theme.color("tertiary").cgColor   // a shade off the terminal area
        addButton.attributedTitle = NSAttributedString(string: "+", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .light),
            .foregroundColor: theme.color("mutedForeground"),
        ])

        if changed { table.reloadData() }
        for r in 0..<rows.count {
            if let rv = table.rowView(atRow: r, makeIfNecessary: false) as? SidebarRowView {
                style(rv, row: r)
                if let cell = rv.view(atColumn: 0) as? SidebarCell { style(cell, row: r) }
            }
        }
    }

    private func style(_ rv: SidebarRowView, row: Int) {
        guard let theme else { return }
        rv.accent = theme.color("tertiaryActive")
        rv.isSelected = row == selected
        rv.needsDisplay = true
    }

    private func style(_ cell: SidebarCell, row: Int) {
        guard let theme, row < rows.count else { return }
        let r = rows[row]
        cell.label.stringValue = r.name
        cell.label.textColor = theme.color(row == selected ? "cardForeground" : "sidebarForeground")
        cell.toolTip = r.path
        styleStatusDot(cell.dot, r.status, theme: theme)
    }

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
