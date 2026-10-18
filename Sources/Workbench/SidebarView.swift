import AppKit

/// `tabs`/`selectedTab`: the project's tabs, listed under it while it is the active project.
struct SidebarRow: Equatable, Sendable {
    let id: UUID; let name: String; let path: String; let status: PaneStatus
    var tabs: [TabItem] = []; var selectedTab = 0
}

enum PaneStatus: Int, Comparable, Sendable {
    case idle = 0, busy = 1, done = 2, attention = 3
    static func < (l: PaneStatus, r: PaneStatus) -> Bool { l.rawValue < r.rawValue }
}

private final class SidebarTable: NSTableView {
    var onPress: ((Int) -> Void)?   // row under the first mouse-down of a click (rows can shift before a double-click ends)
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onPress?(row(at: convert(event.locationInWindow, from: nil))) }
        super.mouseDown(with: event)
    }
}

@MainActor private func makeDot() -> NSView {
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3.5
    return dot
}

/// A project row: disclosure chevron, name, status dot. The expanded project's row is its group's header: down
/// chevron, semibold, no dot. `contentCenter` is the content's distance from the row's top.
private final class ProjectCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    let dot = makeDot()
    private var centerY: NSLayoutConstraint!
    var contentCenter: CGFloat { get { centerY.constant } set { centerY.constant = newValue } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        textField = label
        for v in [label, chevron, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        centerY = chevron.centerYAnchor.constraint(equalTo: topAnchor, constant: 17)
        NSLayoutConstraint.activate([
            centerY,
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 7),   // text stays aligned without a chevron
            label.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            dot.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A tab under the expanded project: status dot (space kept when idle so titles align) and title.
private final class TabCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let dot = makeDot()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        textField = label
        for v in [label, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 35),
            dot.centerYAnchor.constraint(equalTo: topAnchor, constant: 15),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Selected rows are a Liquid Glass capsule inset from the edges instead of the flat source-list fill; a faint
/// capsule shows under the pointer. The sidebar is not over a terminal, so glass is fine here.
/// `position` makes the active project's rows one rounded group: the header row (`top`), its tab rows (`mid`,
/// the last `bottom`); tab rows' capsules sit 4 pt further in. Heights: see SidebarView.height(of:).
private final class GlassRowView: NSTableRowView {
    enum Position { case plain, top, mid, bottom }
    private let glass = NSGlassEffectView()
    private let hover = NSView()
    private static let inset: CGFloat = 6
    var position = Position.plain {
        didSet { if position != oldValue { hover.isHidden = true; needsLayout = true; needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

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
        switch position {
        case .plain: glass.frame = bounds.insetBy(dx: Self.inset, dy: 1)
        case .top: glass.frame = NSRect(x: Self.inset + 4, y: 5, width: bounds.width - 2 * (Self.inset + 4), height: bounds.height - 5)
        case .mid, .bottom: glass.frame = NSRect(x: Self.inset + 4, y: 1, width: bounds.width - 2 * (Self.inset + 4), height: 28)
        }
        glass.cornerRadius = position == .plain ? 10 : 9
        hover.frame = glass.frame
        hover.layer?.cornerRadius = glass.cornerRadius
    }

    /// The group's rounded container: this row's slice of it.
    override func drawBackground(in dirtyRect: NSRect) {
        guard position != .plain else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let r: CGFloat = 14, w = bounds.width - 2 * Self.inset, x = Self.inset
        switch position {
        case .top:
            let clip = NSRect(x: x, y: 1, width: w, height: bounds.height - 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: w, height: bounds.height + 2 * r), xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .mid:
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
        case .bottom:
            let clip = NSRect(x: x, y: 0, width: w, height: bounds.height - 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            NSBezierPath(roundedRect: NSRect(x: x, y: -2 * r, width: w, height: clip.height + 2 * r), xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .plain: break
        }
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

    override func mouseEntered(with event: NSEvent) { if !isSelected, position != .top { showHover(true) } }
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
/// collapse and the insets). The active project is expanded into a rounded group: its row is the header and
/// each tab is a child row; selection is the active project's selected tab (or, with no tabs, its row).
/// Reordering projects is native table drag and drop.
/// A segmented control above the list switches between active and hidden projects; project indices here are rows
/// of the list being shown (the controller maps them to projects). The table's first row is the non-selectable
/// "Projects" group header; flattened table rows map to projects/tabs through sidebarRowKind (Model.swift).
/// Pinned below the list: a separator, the scratch terminals (not projects), and the Scratch Terminal button.
@MainActor final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Int) -> Void)?
    var onSelectTab: ((Int) -> Void)?      // a tab row of the active project
    var onRenameTab: ((Int, String?) -> Void)?
    var onCloseTab: ((Int) -> Void)?
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
    private var pressed: SidebarRowKind?   // what the current click's first mouse-down hit
    private let table = SidebarTable()
    private let filter = GlassSegments(labels: ["Active", "Hidden"])
    private let scratchList = ScratchList()
    private let toggleItem = NSMenuItem(title: "Hide Project", action: #selector(toggleHiddenTapped), keyEquivalent: "")

    /// The project whose tabs are listed (the active one, if it has any) and how many.
    private var expanded: Int { rows.indices.contains(selected) && !rows[selected].tabs.isEmpty ? selected : -1 }
    private var expandedTabs: Int { expanded >= 0 ? rows[expanded].tabs.count : 0 }
    private func kind(_ row: Int) -> SidebarRowKind? { sidebarRowKind(forTableRow: row, expanded: expanded, tabs: expandedTabs) }
    private func row(of k: SidebarRowKind) -> Int? {
        switch k {
        case .header: 0
        case .project(let p): tableRow(forProjectRow: p, expanded: expanded, tabs: expandedTabs)
        case .tab(let p, let t): tableRow(forTab: t, inProject: p)
        }
    }
    private func position(of k: SidebarRowKind?) -> GlassRowView.Position {
        switch k {
        case .project(let p)? where p == expanded: .top
        case .tab(_, let t)?: t == expandedTabs - 1 ? .bottom : .mid
        default: .plain
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        filter.onSelect = { [unowned self] i in onShowHidden?(i == 1) }
        filter.select(0, animated: false)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.intercellSpacing = .zero   // rows carry their own gaps (the group container is continuous)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.draggingDestinationFeedbackStyle = .gap
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.onPress = { [unowned self] row in pressed = kind(row) }
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

    // MARK: Menu and clicks

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch kind(table.clickedRow) {
        case .project?:
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "Rename", action: #selector(renameTapped), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Remove Project…", action: #selector(removeTapped), keyEquivalent: ""))
        case .tab?:
            menu.addItem(NSMenuItem(title: "Rename Tab", action: #selector(renameTapped), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Close Tab", action: #selector(closeTabTapped), keyEquivalent: ""))
        default: break
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func toggleHiddenTapped() {
        if let r = projectRow(forTableRow: table.clickedRow, expanded: expanded, tabs: expandedTabs) { onToggleHidden?(r) }
    }

    @objc private func renameTapped() { beginRename(kind(table.clickedRow)) }

    @objc private func removeTapped() {
        if let r = projectRow(forTableRow: table.clickedRow, expanded: expanded, tabs: expandedTabs) { onRemove?(r) }
    }

    @objc private func closeTabTapped() {
        if case .tab(_, let t)? = kind(table.clickedRow) { onCloseTab?(t) }
    }

    /// A click on another project makes it the active one (on mouse-up, so a drag that starts on it doesn't see the rows shift).
    @objc private func rowClicked() {
        if case .project(let p)? = kind(table.clickedRow), p != selected { onSelect?(p) }
    }

    /// The row the click began on (rows may have moved since the first click expanded/collapsed a project).
    @objc private func rowDoubleClicked() { beginRename(pressed ?? kind(table.clickedRow)) }

    private func beginRename(_ k: SidebarRowKind?) {
        guard let k, let row = row(of: k), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let label = cell.textField else { return }
        InlineRename(label) { [weak self] name in
            switch k {
            case .project(let p): self?.onRename?(p, name)
            case .tab(_, let t): self?.onRenameTab?(t, name)
            case .header: break
            }
        }
    }

    /// Selects the active project's tab row (its own row when it has no tabs); none when it isn't in this list.
    private func select() {
        syncing = true
        defer { syncing = false }
        guard rows.indices.contains(selected) else { return table.deselectAll(nil) }
        let row = expanded >= 0 ? tableRow(forTab: min(max(rows[selected].selectedTab, 0), expandedTabs - 1), inProject: selected)
                                : tableRow(forProjectRow: selected)
        table.selectRowIndexes([row], byExtendingSelection: false)
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
        let old = (ids: self.rows.map(\.id), expanded: expanded, tabs: expandedTabs)
        self.rows = rows
        self.selected = selected
        self.theme = theme
        syncing = true
        if old.ids != rows.map(\.id) {
            table.reloadData()
        } else if old.expanded != expanded || old.tabs != expandedTabs {
            animateExpansion(from: old.expanded, oldTabs: old.tabs)
        }
        syncing = false
        select()
        restyleVisible()
    }

    /// The active project changed (or its tab count did): the old tab rows slide away and the new ones slide in
    /// as native row insertions/removals, not a reload. Tabs the two states share are left in place.
    private func animateExpansion(from oldExpanded: Int, oldTabs: Int) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let keep = oldExpanded == expanded ? min(oldTabs, expandedTabs) : 0
        table.beginUpdates()
        if oldTabs > keep {
            table.removeRows(at: IndexSet(tableRow(forTab: keep, inProject: oldExpanded)..<tableRow(forTab: oldTabs, inProject: oldExpanded)),
                             withAnimation: reduce ? [] : [.slideUp, .effectFade])
        }
        if expandedTabs > keep {
            table.insertRows(at: IndexSet(tableRow(forTab: keep, inProject: expanded)..<tableRow(forTab: expandedTabs, inProject: expanded)),
                             withAnimation: reduce ? [] : [.slideDown, .effectFade])
        }
        table.endUpdates()
        if keep > 0 { table.noteHeightOfRows(withIndexesChanged: [tableRow(forTab: keep - 1, inProject: expanded)]) }   // last-tab row has the group's bottom pad
    }

    /// Everything on screen is styled in place, so a status dot or title change never rebuilds or flashes a row.
    private func restyleVisible() {
        for row in 0..<table.numberOfRows {
            let k = kind(row)
            (table.rowView(atRow: row, makeIfNecessary: false) as? GlassRowView)?.position = position(of: k)
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) { style(cell, k) }
        }
    }

    private func style(_ view: NSView, _ k: SidebarRowKind?) {
        guard let theme else { return }
        switch (view, k) {
        case (let cell as ProjectCell, .project(let p)?) where rows.indices.contains(p):
            let r = rows[p], header = p == expanded
            if !cell.label.isEditable { cell.label.stringValue = r.name }
            cell.label.font = .systemFont(ofSize: 13, weight: header ? .semibold : .regular)
            cell.label.textColor = r.tabs.isEmpty ? .tertiaryLabelColor : .labelColor
            cell.chevron.isHidden = r.tabs.isEmpty
            cell.chevron.image = NSImage(systemSymbolName: header ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            cell.contentCenter = header ? 19 : 17
            cell.toolTip = r.path
            styleStatusDot(cell.dot, header ? .idle : r.status, theme: theme)   // the header shows its tabs' dots instead
        case (let cell as TabCell, .tab(let p, let t)?) where rows.indices.contains(p) && rows[p].tabs.indices.contains(t):
            let tab = rows[p].tabs[t]
            if !cell.label.isEditable { cell.label.stringValue = tab.title }
            cell.label.textColor = t == rows[p].selectedTab ? .labelColor : .secondaryLabelColor
            cell.toolTip = tab.title
            styleStatusDot(cell.dot, tab.status, theme: theme)
        default: break
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 + expandedTabs }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }

    /// Only tab rows (or, via mouse-up, another project) take clicks; a click never deselects or selects a header.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        if case .tab? = proposed.first.flatMap({ kind($0) }) { return proposed }
        return tableView.selectedRowIndexes
    }

    /// Plain project 34, the group's header 34, tabs 30; the last tab 34 for the group's bottom padding.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch kind(row) {
        case .header?: 24
        case .tab(_, let t)?: t == expandedTabs - 1 ? 34 : 30
        default: 34
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let k = kind(row)
        if k == .header { return nil }
        let view = GlassRowView()
        view.position = position(of: k)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let k = kind(row)
        let view: NSView
        switch k {
        case .project?: view = ProjectCell(frame: .zero)
        case .tab?: view = TabCell(frame: .zero)
        default:
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
        style(view, k)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, case .tab(_, let t)? = kind(table.selectedRow), rows.indices.contains(selected), t != rows[selected].selectedTab else { return }
        onSelectTab?(t)   // the controller's update() confirms
    }

    // MARK: Drag and drop (projects only)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let r = projectRow(forTableRow: row, expanded: expanded, tabs: expandedTabs) else { return nil }   // header and tabs can't be dragged
        let item = NSPasteboardItem()
        item.setString(String(r), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as AnyObject === table else { return [] }
        var r = max(row, 1)   // never above the header
        if expanded >= 0 {   // not between a project's tab rows: the nearer project boundary
            let first = tableRow(forProjectRow: expanded, expanded: expanded, tabs: expandedTabs), n = expandedTabs
            if r > first, r <= first + n { r = (r - first) * 2 <= n ? first : first + n + 1 }
        }
        if op == .on || r != row { tableView.setDropRow(r, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s), rows.indices.contains(from) else { return false }
        let dest = projectInsertion(forTableRow: row, expanded: expanded, tabs: expandedTabs)
        let to = dest > from ? dest - 1 : dest
        guard to != from else { return false }
        let fromRow = tableRow(forProjectRow: from, expanded: expanded, tabs: expandedTabs)
        let wasExpanded = from == expanded
        rows.insert(rows.remove(at: from), at: to)
        if selected == from { selected = to } else if from < selected, selected <= to { selected -= 1 } else if to <= selected, selected < from { selected += 1 }
        syncing = true
        if wasExpanded { table.reloadData() } else { table.moveRow(at: fromRow, to: tableRow(forProjectRow: to, expanded: expanded, tabs: expandedTabs)) }
        syncing = false
        select()
        restyleVisible()
        onMove?(from, to)
        return true
    }
}
