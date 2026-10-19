import AppKit
import CoreServices

private final class Node {
    let url: URL
    let isDirectory: Bool
    var children: [Node]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

private let clutterNames: Set<String> = ["node_modules", "build", "dist", "DerivedData", "target", "__pycache__", "venv", "Pods", "coverage", ".build"]

@MainActor final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: ((String) -> Void)?   // a file row was selected (click or arrow keys)
    var onOpen: ((String) -> Void)?     // a file row was double-clicked
    var onToggleClutter: ((Bool) -> Void)?
    var hideClutter = true {
        didSet {
            guard hideClutter != oldValue else { return }
            updateFilterButton()
            reloadAll()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "No project")
    private let filterButton = NSButton()
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var root: Node?
    private var stream: FSEventStreamRef?

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        filterButton.isBordered = false
        filterButton.title = ""
        filterButton.imagePosition = .imageOnly
        filterButton.toolTip = "Hide hidden and build files"
        filterButton.setAccessibilityLabel("Filter")
        filterButton.target = self
        filterButton.action = #selector(toggleClutter)
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        updateFilterButton()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = false
        outline.focusRingType = .none
        outline.usesAutomaticRowHeights = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(filterButton)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: filterButton.leadingAnchor, constant: -8),
            filterButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            filterButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var isFlipped: Bool { true }

    private func updateFilterButton() {
        let name = hideClutter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        filterButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Filter")
    }

    @objc private func toggleClutter() {
        hideClutter.toggle()
        onToggleClutter?(hideClutter)
    }

    func show(root path: String?) {
        guard let path else {
            stopStream()
            root = nil
            titleLabel.stringValue = "No project"
            outline.reloadData()
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let root, root.url.path == url.path { return }
        stopStream()
        root = Node(url: url, isDirectory: true)
        titleLabel.stringValue = url.lastPathComponent
        outline.reloadData()
        startStream(path: url.path)
    }

    func close() { stopStream() }

    private func list(_ dir: URL, reusing old: [Node]?) -> [Node] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let existing = Dictionary((old ?? []).map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes: [Node] = urls.compactMap { url in
            let name = url.lastPathComponent
            if hideClutter && (name.hasPrefix(".") || clutterNames.contains(name)) { return nil }
            if let node = existing[url.path] { return node }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Node(url: url, isDirectory: isDir)
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private func loaded(_ node: Node) -> [Node] {
        if let c = node.children { return c }
        let c = list(node.url, reusing: nil)
        node.children = c
        return c
    }

    private func expandedPaths() -> Set<String> {
        var out = Set<String>()
        func walk(_ nodes: [Node]) {
            for n in nodes where n.isDirectory {
                guard let c = n.children, outline.isItemExpanded(n) else { continue }
                out.insert(n.url.path)
                walk(c)
            }
        }
        if let c = root?.children { walk(c) }
        return out
    }

    private func reexpand(_ nodes: [Node], _ paths: Set<String>) {
        for n in nodes where n.isDirectory && paths.contains(n.url.path) {
            guard FileManager.default.fileExists(atPath: n.url.path) else { continue }
            outline.expandItem(n)
            reexpand(loaded(n), paths)
        }
    }

    private func reloadAll() {
        guard let root else { return }
        let paths = expandedPaths()
        root.children = nil
        outline.reloadData()
        reexpand(loaded(root), paths)
    }

    private func refresh(_ node: Node) {
        guard let root, node.children != nil else { return }
        let paths = expandedPaths()
        node.children = list(node.url, reusing: node.children)
        if node === root { outline.reloadData() } else { outline.reloadItem(node, reloadChildren: true) }
        reexpand(node.children ?? [], paths)
    }

    private func find(_ path: String) -> Node? {
        guard let root else { return nil }
        func walk(_ node: Node) -> Node? {
            if node.url.path == path { return node }
            guard let c = node.children else { return nil }
            for n in c where n.isDirectory && (path == n.url.path || path.hasPrefix(n.url.path + "/")) {
                if let f = walk(n) { return f }
            }
            return nil
        }
        return walk(root)
    }

    private func handle(_ paths: [String]) {
        for p in paths {
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            if let node = find(std) { refresh(node) }
        }
    }

    private func startStream(path: String) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let view = Unmanaged<FileTreeView>.fromOpaque(info)
            MainActor.assumeIsolated { view.takeUnretainedValue().handle(paths) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func node(_ item: Any?) -> Node? { (item as? Node) ?? root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = node(item) else { return 0 }
        return loaded(n).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        loaded(node(item)!)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        let image = NSWorkspace.shared.icon(forFile: n.url.path)
        image.size = NSSize(width: 16, height: 16)
        icon.image = image
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: n.url.lastPathComponent)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        guard n.isDirectory else { return }
        if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    /// Selecting a file (click or arrow keys) previews it.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = outline.item(atRow: outline.selectedRow) as? Node, !n.isDirectory else { return }
        onSelect?(n.url.path)
    }

    @objc private func doubleClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? Node, !n.isDirectory else { return }
        onOpen?(n.url.path)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        for (title, action) in [("Reveal in Finder", #selector(reveal(_:))), ("Copy Path", #selector(copyPath(_:))), ("Open with Default App", #selector(openDefault(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = n.url
            menu.addItem(item)
        }
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func openDefault(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
