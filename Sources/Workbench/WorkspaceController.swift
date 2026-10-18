import AppKit
@preconcurrency import GhosttyKit
import UserNotifications

/// Jira tickets of the kwimpos projects active in the last 30 days (not a generic KEY-123 shape, which would hit UTF-8, SHA-256, ISO-8601).
/// The one list: libghostty highlights the pattern on ⌘-hover (`link` override) and `openURL` maps a click to `browse`.
enum Jira {
    static let browse = "https://kwimpos.atlassian.net/browse/"
    static let projects = ["IN", "OPS", "MER", "ECOM", "MPOS", "PLAT", "BOP", "WS", "STOR", "MOD", "TES", "OMS", "CS", "CRISIS", "MS",
        "HELPDESK", "AIR", "PMI", "DS", "KIT", "BOSS", "MFA", "BIJA", "SHOP"]
    static let pattern = "\\b(?:\(projects.joined(separator: "|")))-[0-9]+\\b"
    /// The browse URL if `text` is exactly one ticket key, else nil.
    static func url(_ text: String) -> URL? {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex ? URL(string: browse + text) : nil
    }
}

@MainActor
final class WorkspaceController: NSWindowController, NSWindowDelegate, RuntimeDelegate {
    /// Idle cost: blink's 600 ms timer, and vsync's CVDisplayLink, which ticks at the display rate per visible
    /// surface even with nothing to draw (~300 → ~40 wakeups/s idle with it off; same CPU under heavy output).
    static func overrides(_ theme: Theme) -> String {
        """
        cursor-style-blink = false
        window-vsync = false
        scrollback-limit = 10000000
        unfocused-split-opacity = 1
        window-padding-x = 8
        window-padding-y = 4
        window-padding-balance = true
        link = regex:\(Jira.pattern),action:open,highlight:hover_mods

        """ + theme.ghosttyConfig
    }

    let store: Store
    let runtime: Runtime
    private(set) var theme: Theme

    private var views: [PaneID: NSView] = [:]
    private var status: [PaneID: PaneStatus] = [:]
    private var titles: [PaneID: String] = [:]
    private var searchCounts: (total: Int, selected: Int) = (-1, -1)
    private var findPane: PaneID?
    private var activity: NSObjectProtocol?

    private let sidebar = SidebarView(frame: .zero)
    private let tabBar = TabBarView(frame: .zero)
    private let content = NSView()
    private let findBar = FindBar(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")
    private lazy var tree = SplitTreeView { [unowned self] spec in self.view(for: spec) }
    private var sidebarWidth: NSLayoutConstraint!
    /// Right sidebar: the file ⌘-clicked last, beside every tab until closed (⌥⌘B hides and shows it).
    private let preview = NSView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewEdge = ResizeEdge()
    private var previewFile: FilePaneView?
    private var previewWidth: NSLayoutConstraint!
    private var previewGap: NSLayoutConstraint!   // content's trailing edge to the panel's leading edge

    init(store: Store, runtime: Runtime) {
        self.store = store
        self.runtime = runtime
        self.theme = Theme.named(store.layout.theme)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("Main")
        super.init(window: window)
        window.delegate = self
        runtime.delegate = self
        buildLayout()
        wireCallbacks()
        paintTheme()
        restore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func buildLayout() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        for v in [sidebar, tabBar, content, preview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        content.wantsLayer = true
        tree.frame = content.bounds
        tree.autoresizingMask = [.width, .height]
        content.addSubview(tree)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        content.addSubview(emptyLabel)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        content.addSubview(findBar)
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 16   // a floating glass panel, like the project sidebar
        preview.layer?.masksToBounds = true
        preview.isHidden = true
        let glass = NSGlassEffectView(frame: preview.bounds)
        glass.cornerRadius = 16
        glass.autoresizingMask = [.width, .height]
        preview.addSubview(glass)
        previewTitle.font = .systemFont(ofSize: 12, weight: .medium)
        previewTitle.lineBreakMode = .byTruncatingMiddle
        let close = HandButton.glass("xmark", "Close Preview")
        close.target = self
        close.action = #selector(closePreview(_:))
        for v in [previewTitle, close, previewEdge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            preview.addSubview(v)
        }
        previewEdge.onDrag = { [unowned self] dx in
            previewWidth.constant = min(max(previewWidth.constant - dx, 240), root.bounds.width - 300)
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: store.layout.sidebarVisible ? 220 : 0)
        previewWidth = preview.widthAnchor.constraint(equalToConstant: 0)
        previewGap = content.trailingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 8)   // hidden: past the 8 pt inset
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,
            tabBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.titleStrip + TabBarView.tabHeight),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            previewGap,
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            previewWidth,
            previewEdge.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewEdge.topAnchor.constraint(equalTo: preview.topAnchor),
            previewEdge.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            previewEdge.widthAnchor.constraint(equalToConstant: 5),
            previewTitle.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 14),
            previewTitle.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            previewTitle.centerYAnchor.constraint(equalTo: preview.topAnchor, constant: 18),
            close.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: previewTitle.centerYAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
        sidebar.isHidden = !store.layout.sidebarVisible
    }

    private func wireCallbacks() {
        sidebar.onSelect = { [unowned self] i in selectProject(i) }
        sidebar.onAdd = { [unowned self] in addProject(nil) }
        sidebar.onRemove = { [unowned self] i in removeProject(i) }
        tabBar.onSelect = { [unowned self] i in selectTab(i) }
        tabBar.onClose = { [unowned self] i in closeTab(at: i) }
        tabBar.onNew = { [unowned self] in newTab(nil) }
        sidebar.onRename = { [unowned self] i, name in renameProject(i, name) }
        sidebar.onMove = { [unowned self] from, to in moveProject(from, to) }
        tabBar.onRename = { [unowned self] i, name in renameTab(i, name) }
        tabBar.onMove = { [unowned self] from, to in moveTab(from, to) }
        tree.onRatiosChanged = { [unowned self] newRoot in
            mutateActiveTab { $0.root = $0.root.withRatios(from: newRoot) }
        }
        tree.onMove = { [unowned self] id, target, edge in
            mutateActiveTab { $0.root = $0.root.moving(id, to: target, edge); $0.focused = id }
            render()
        }
        tree.onHeaderClick = { [unowned self] id in focus(id) }
        findBar.onChange = { [unowned self] text in findSurface?.perform("search:\(text)") }
        findBar.onNext = { [unowned self] in findSurface?.perform("navigate_search:next") }
        findBar.onPrevious = { [unowned self] in findSurface?.perform("navigate_search:previous") }
        findBar.onClose = { [unowned self] in findSurface?.perform("end_search"); hideFind() }
    }

    // MARK: - Model access

    private var activeProjectIndex: Int? {
        store.layout.projects.indices.contains(store.layout.activeProject) ? store.layout.activeProject : nil
    }

    private var activeTab: Tab? {
        guard let p = activeProjectIndex else { return nil }
        let project = store.layout.projects[p]
        return project.tabs.indices.contains(project.activeTab) ? project.tabs[project.activeTab] : nil
    }

    private var focusedPane: PaneID? { activeTab.flatMap { $0.focused ?? $0.root.leaves.first?.id } }

    private func mutateActiveTab(_ f: (inout Tab) -> Void) {
        guard let p = activeProjectIndex else { return }
        let t = store.layout.projects[p].activeTab
        guard store.layout.projects[p].tabs.indices.contains(t) else { return }
        f(&store.layout.projects[p].tabs[t])
        store.changed()
    }

    private func locate(_ id: PaneID) -> (project: Int, tab: Int)? {
        for (p, project) in store.layout.projects.enumerated() {
            if let t = project.tabs.firstIndex(where: { $0.root.contains(id) }) { return (p, t) }
        }
        return nil
    }

    private func spec(_ id: PaneID) -> PaneSpec? {
        guard let (p, t) = locate(id) else { return nil }
        return store.layout.projects[p].tabs[t].root.leaves.first { $0.id == id }
    }

    private func mutatePane(_ id: PaneID, _ f: (inout PaneSpec) -> Void) {
        guard let (p, t) = locate(id) else { return }
        let root = store.layout.projects[p].tabs[t].root.updating(id, f)
        guard root != store.layout.projects[p].tabs[t].root else { return }
        store.layout.projects[p].tabs[t].root = root
        store.changed()
    }

    // MARK: - Views

    func surfaceView(for id: PaneID) -> SurfaceView? { views[id] as? SurfaceView }

    private func view(for spec: PaneSpec) -> NSView {
        if let v = views[spec.id] { return v }
        let v: NSView
        switch spec.kind {
        case let .terminal(cwd, launch):
            let s = SurfaceView(app: runtime.app, id: spec.id, cwd: cwd,
                                initialInput: launch.map { $0.command + "\n" },
                                env: env(for: spec.id), scrollbackLimit: launch?.scrollbackLimit)
            s.onFocus = { [unowned self] id in paneFocused(id) }
            s.contextMenu = { [unowned self] id in paneMenu(id) }
            v = s
        case let .file(path):
            let m = FilePaneView(id: spec.id, path: path, theme: theme)
            m.onOpenLink = { [unowned self] url in open(url) }
            v = m
        }
        views[spec.id] = v
        return v
    }

    private func env(for id: PaneID) -> [String: String] {
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pane").path
        return [
            "PANE_ID": id.uuidString,
            "PANE_SOCK": Store.directory.appendingPathComponent("pane.sock").path,
            "PANE_BIN": bin,
            "PANE_CLAUDE_SETTINGS": Bundle.main.resourceURL?.appendingPathComponent("claude-hooks.json").path ?? "",
        ]
    }

    /// Only panes with an agent to resume start at launch (unrealized, 2 per runloop turn: each forks a login
    /// shell). Plain shells and markdown panes are created when first shown, by render().
    private func restore() {
        render()
        let active = Set(activeTab?.root.leaves.map(\.id) ?? [])
        var pending = store.layout.projects.flatMap { $0.tabs.flatMap { $0.root.leaves } }.filter {
            if case .terminal(_, .some) = $0.kind { return !active.contains($0.id) }
            return false
        }.map(\.id)
        func step() {
            // Re-resolve each batch: a pane may have been closed, or shown and created by render(), since launch.
            for id in pending.prefix(2) { createHidden(id) }
            pending.removeFirst(min(2, pending.count))
            if !pending.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { step() } } }
        }
        if !pending.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { step() } } }
    }

    /// A pane outside the visible tab, started without a renderer; no-op if it already exists or is gone.
    private func createHidden(_ id: PaneID) {
        guard views[id] == nil, let spec = spec(id) else { return }
        (view(for: spec) as? SurfaceView)?.setVisible(false)
    }

    private func render() {
        if let f = findPane, !(activeTab?.root.contains(f) ?? false) {
            findSurface?.perform("end_search")
            findBar.isHidden = true
            findPane = nil
        }
        var rebuilt = false
        if let tab = activeTab {
            tree.isHidden = false
            emptyLabel.isHidden = true
            rebuilt = tree.render(tab.root, dividerColor: theme.color("border"))
        } else {
            tree.isHidden = true
            tree.clear()
            emptyLabel.isHidden = false
            emptyLabel.stringValue = activeProjectIndex == nil ? "⇧⌘O  Add Project" : "⌘T  New Terminal"
        }
        syncVisibility(refresh: rebuilt)
        updateChrome()
        if !InlineRename.isEditing, let id = focusedPane, let v = views[id] { window?.makeFirstResponder(v) }
    }

    /// `refresh`: the split hierarchy was rebuilt, so re-parented surfaces must redraw (else they show blank).
    /// Surfaces that just became visible already refreshed in setVisible.
    private func syncVisibility(refresh: Bool = false) {
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        let shown = windowVisible ? Set(activeTab?.root.leaves.map(\.id) ?? []) : []
        for (id, v) in views {
            guard let s = v as? SurfaceView else { continue }
            if !s.setVisible(shown.contains(id)), refresh, shown.contains(id) { s.refresh() }
        }
    }

    /// nil = rename cancelled; empty = back to the folder name.
    private func renameProject(_ i: Int, _ name: String?) {
        if let name, store.layout.projects.indices.contains(i) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            store.layout.projects[i].name = n.isEmpty ? URL(fileURLWithPath: store.layout.projects[i].path).lastPathComponent : n
            store.changed()
        }
        render()   // also hands keyboard focus back to the terminal
    }

    /// nil = rename cancelled; empty = back to the terminal's own title.
    private func renameTab(_ i: Int, _ name: String?) {
        if let name, let p = activeProjectIndex, store.layout.projects[p].tabs.indices.contains(i) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            store.layout.projects[p].tabs[i].customTitle = n.isEmpty ? nil : n
            store.changed()
        }
        render()
    }

    private func updateChrome() {
        let projects = store.layout.projects
        sidebar.update(rows: projects.map { p in
            SidebarRow(name: p.name, path: p.path,
                       status: p.tabs.flatMap { $0.root.leaves }.map { status[$0.id] ?? .idle }.max() ?? .idle)
        }, selected: store.layout.activeProject, theme: theme)
        if let p = activeProjectIndex {
            let project = projects[p]
            tabBar.update(items: project.tabs.map { tab in
                TabItem(title: title(of: tab),
                               status: tab.root.leaves.map { status[$0.id] ?? .idle }.max() ?? .idle)
            }, selected: project.activeTab, theme: theme)
            tree.updateHeaders(focused: focusedPane, theme: theme) { [titles] id in
                if let t = titles[id] { return t }
                if case let .file(path)? = spec(id)?.kind { return (path as NSString).lastPathComponent }
                return "Terminal"
            }
        } else {
            tabBar.update(items: [], selected: 0, theme: theme)
        }
        let badge = status.values.filter { $0 == .done || $0 == .attention }.count
        let label = badge > 0 ? "\(badge)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        if status.values.contains(.busy) {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep, reason: "Agents running")
            }
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func title(of tab: Tab) -> String {
        tab.customTitle ?? (tab.focused ?? tab.root.leaves.first?.id).flatMap { titles[$0] } ?? tab.title
    }

    func applyTheme(_ id: String) {
        store.layout.theme = id
        store.changed()
        theme = Theme.named(id)
        runtime.reload(overrides: Self.overrides(theme))
        paintTheme()
        render()
    }

    private func paintTheme() {
        window?.backgroundColor = theme.color("background")
        content.layer?.backgroundColor = theme.color("background").cgColor
        emptyLabel.textColor = theme.color("mutedForeground")
        findBar.apply(theme: theme)
        for v in views.values { (v as? FilePaneView)?.apply(theme: theme) }
        previewFile?.apply(theme: theme)
        previewTitle.textColor = theme.color("mutedForeground")
    }

    // MARK: - Focus & status

    private func paneFocused(_ id: PaneID) {
        if let (p, t) = locate(id), store.layout.projects[p].tabs[t].focused != id {
            store.layout.projects[p].tabs[t].focused = id
            store.changed()
        }
        if let s = status[id], s == .done || s == .attention { status[id] = .idle }
        updateChrome()
    }

    func focusPane(_ id: PaneID) {
        guard let (p, t) = locate(id) else { return }
        store.layout.activeProject = p
        store.layout.projects[p].activeTab = t
        store.layout.projects[p].tabs[t].focused = id
        store.changed()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        render()
    }

    private func isWatched(_ id: PaneID) -> Bool {
        NSApp.isActive && (window?.occlusionState.contains(.visible) ?? false)
            && (activeTab?.root.contains(id) ?? false) && focusedPane == id
    }

    private func setStatus(_ id: PaneID, _ new: PaneStatus, title: String? = nil, body: String? = nil) {
        guard locate(id) != nil else { return }   // late event from a closed pane
        let old = status[id] ?? .idle
        if new == .busy, old != .busy { scheduleCapture() }   // a turn started: record its resume command now, not only at quit
        let watched = isWatched(id)
        status[id] = (watched && (new == .done || new == .attention)) ? .idle : new
        if !watched, new != old, new == .done || new == .attention {
            notify(id, title: title, body: body ?? (new == .done ? "Finished" : "Needs your input"))
        }
        updateChrome()
    }

    private func notify(_ id: PaneID, title: String?, body: String) {
        guard let (p, _) = locate(id) else { return }
        let c = UNMutableNotificationContent()
        c.title = title ?? store.layout.projects[p].name
        c.subtitle = titles[id] ?? ""
        c.body = body
        c.sound = .default
        c.userInfo = ["pane": id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id.uuidString, content: c, trigger: nil))
    }

    // MARK: - RuntimeDelegate

    func runtime(_ runtime: Runtime, pane id: PaneID, event: PaneEvent) {
        guard views[id] != nil else { return }   // queued before the pane closed
        switch event {
        case let .title(raw):
            // Agents animate a spinner glyph at the front of their title (Claude Code: ⠋⠙⠹…, ✳ when idle).
            // The status dot already shows busy/idle, so drop it; that also stops a chrome redraw per frame.
            // A braille spinner means the agent is mid-turn: that drives the status dot for agents started any way,
            // not only through presets with hooks. Spinner gone means the turn ended.
            let spinning = raw.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
            let t = Self.stripStatusGlyphs(raw)
            let titleChanged = titles[id] != t
            titles[id] = t
            // One chrome update per event: setStatus does it when the state flips.
            if spinning, status[id] != .busy { setStatus(id, .busy) }
            else if !spinning, status[id] == .busy { setStatus(id, .done) }
            else if titleChanged { updateChrome() }
        case let .pwd(path):
            mutatePane(id) { spec in
                if case let .terminal(_, launch) = spec.kind { spec.kind = .terminal(cwd: path, launch: launch) }
            }
        case .bell:
            setStatus(id, .attention, body: "Bell")
        case let .notification(title, body):
            setStatus(id, .attention, title: title.isEmpty ? nil : title, body: body)
        case let .commandFinished(_, ns):
            if ns > 5_000_000_000 {
                setStatus(id, .done, body: "Command finished")
            } else if status[id] == .busy {
                setStatus(id, .idle)   // agent exited without a Stop hook
            }
        case let .openURL(url):
            openURL(url, from: id)
        case .closeRequested:
            closePane(id, confirm: false)
        case let .startSearch(needle):
            findPane = id
            searchCounts = (-1, -1)
            findBar.isHidden = false
            findBar.setCounts(total: -1, selected: -1)
            findBar.show(needle: needle)
        case .endSearch:
            hideFind()
        case let .searchTotal(n):
            searchCounts.total = n
            findBar.setCounts(total: searchCounts.total, selected: searchCounts.selected)
        case let .searchSelected(n):
            searchCounts.selected = n
            findBar.setCounts(total: searchCounts.total, selected: searchCounts.selected)
        }
    }

    private var findSurface: SurfaceView? { findPane.flatMap { surfaceView(for: $0) } }

    private func hideFind() {
        findBar.isHidden = true
        if let v = findSurface { window?.makeFirstResponder(v) }
        findPane = nil
    }

    private func openURL(_ url: String, from id: PaneID) {
        if let u = Jira.url(url) { open(u); return }
        if let u = URL(string: url), u.scheme != nil { open(u); return }
        var path = (url as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let spec = spec(id), case let .terminal(cwd, _) = spec.kind {
            path = URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL.path
        }
        open(URL(fileURLWithPath: path))
    }

    /// The one link policy for terminal ⌘-clicks and markdown links. Terminal output and documents are untrusted, so
    /// a click only opens passive files (text/source, images, PDF) and plain folders, and only follows http/https/mailto.
    /// Everything else, including scripts, .command/.terminal/.webloc files and bundles, is revealed in Finder, never run.
    private func open(_ url: URL) {
        if url.isFileURL {
            let file = url.resolvingSymlinksInPath()
            let v = try? file.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
            if v?.isDirectory != true, ["md", "markdown"].contains(file.pathExtension.lowercased()) || Syntax.key(for: file.path) != nil
                || v?.contentType.map({ $0.conforms(to: .text) }) == true {
                openFile(file.path)
                return
            }
            let passive = v?.contentType.map {
                ($0.conforms(to: .text) || $0.conforms(to: .image) || $0.conforms(to: .pdf))
                    && !$0.conforms(to: .script) && !$0.conforms(to: .propertyList)
            } ?? false
            if (v?.isDirectory == true && v?.isPackage != true) || (v?.isDirectory != true && passive) {
                NSWorkspace.shared.open(file)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Structure changes

    private func split(_ axis: Axis, kind: PaneKind, from source: PaneID? = nil) {
        guard let base = source ?? focusedPane, let (p, t) = locate(base), let old = spec(base) else {
            newTab(kind: kind)
            return
        }
        let new = PaneSpec(id: UUID(), kind: kind)
        store.layout.activeProject = p
        store.layout.projects[p].activeTab = t
        var tab = store.layout.projects[p].tabs[t]
        tab.root = tab.root.replacing(base, with: .split(axis: axis, ratio: 0.5, a: .leaf(old), b: .leaf(new)))
        tab.focused = new.id
        store.layout.projects[p].tabs[t] = tab
        store.changed()
        render()
    }

    private func paneMenu(_ id: PaneID) -> NSMenu? {
        guard let (p, t) = locate(id) else { return nil }
        let tabs = store.layout.projects[p].tabs
        let move = NSMenu()
        move.autoenablesItems = false   // "New Tab" is disabled by having no action
        move.addItem(.sectionHeader(title: "Move to Tab"))   // the menu is just the targets: copy/paste are ⌘C/⌘V
        for (i, tab) in tabs.enumerated() where i != t {
            let item = NSMenuItem(title: title(of: tab), action: #selector(movePaneToTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [id, tab.id]
            move.addItem(item)
        }
        if tabs.count > 1 { move.addItem(.separator()) }
        let new = NSMenuItem(title: "New Tab", action: tabs[t].root.leaves.count > 1 ? #selector(movePaneToTab(_:)) : nil,
                             keyEquivalent: "")
        new.target = self
        new.representedObject = [id]
        move.addItem(new)
        return move
    }

    /// Moves a pane into another tab of its project (`target` nil: a new tab), split to the right of what is there.
    /// Its view and process live on in `views`; only the layout changes.
    private func movePane(_ id: PaneID, to target: UUID?) {
        guard let (p, t) = locate(id), let moved = spec(id) else { return }
        guard let rest = store.layout.projects[p].tabs[t].root.removing(id) else {
            // Sole pane: moving it to a new tab changes nothing; into another tab, its own tab goes away.
            guard target != nil else { return }
            removeTab(project: p, at: t)
            return place(moved, in: p, target)
        }
        store.layout.projects[p].tabs[t].root = rest
        if store.layout.projects[p].tabs[t].focused == id { store.layout.projects[p].tabs[t].focused = rest.leaves.first?.id }
        place(moved, in: p, target)
    }

    private func place(_ spec: PaneSpec, in p: Int, _ target: UUID?) {
        if let target, let i = store.layout.projects[p].tabs.firstIndex(where: { $0.id == target }) {
            let root = store.layout.projects[p].tabs[i].root
            store.layout.projects[p].tabs[i].root = .split(axis: .horizontal, ratio: 0.5, a: root, b: .leaf(spec))
            store.layout.projects[p].tabs[i].focused = spec.id
            store.layout.projects[p].activeTab = i
        } else {
            store.layout.projects[p].tabs.append(Tab(id: UUID(), title: "Terminal", root: .leaf(spec), focused: spec.id))
            store.layout.projects[p].activeTab = store.layout.projects[p].tabs.count - 1
        }
        store.layout.activeProject = p
        store.changed()
        render()
    }

    private func cwdForNewPane() -> String {
        if let id = focusedPane, let spec = spec(id), case let .terminal(cwd, _) = spec.kind { return cwd }
        guard let p = activeProjectIndex else { return NSHomeDirectory() }
        return store.layout.projects[p].path
    }

    private func newTab(kind: PaneKind? = nil) {
        guard let p = activeProjectIndex else { addProject(nil); return }
        let spec = PaneSpec(id: UUID(), kind: kind ?? .terminal(cwd: store.layout.projects[p].path, launch: nil))
        store.layout.projects[p].tabs.append(Tab(id: UUID(), title: "Terminal", root: .leaf(spec), focused: spec.id))
        store.layout.projects[p].activeTab = store.layout.projects[p].tabs.count - 1
        store.changed()
        render()
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Running processes will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func needsConfirm(_ ids: [PaneID]) -> Bool {
        ids.contains { surfaceView(for: $0)?.needsConfirmQuit ?? false }
    }

    private func destroy(_ id: PaneID) {
        if let s = views[id] as? SurfaceView { s.close() }
        if let m = views[id] as? FilePaneView { m.close() }
        views[id]?.removeFromSuperview()
        views[id] = nil
        status[id] = nil
        titles[id] = nil
        if findPane == id { hideFind() }
    }

    // Close paths resolve their target by id only after any confirm dialog: the modal run loop keeps
    // processing shell exits and socket commands, so indices captured before it may be stale.
    func closePane(_ id: PaneID, confirm ask: Bool = true) {
        if ask, needsConfirm([id]), !confirm("Close this pane?") { return }
        guard let (p, t) = locate(id) else { destroy(id); return }
        destroy(id)
        if let root = store.layout.projects[p].tabs[t].root.removing(id) {
            store.layout.projects[p].tabs[t].root = root
            if store.layout.projects[p].tabs[t].focused == id {
                store.layout.projects[p].tabs[t].focused = root.leaves.first?.id
            }
        } else {
            removeTab(project: p, at: t)
        }
        store.changed()
        render()
    }

    private func closeTab(at index: Int) {
        guard let p = activeProjectIndex, store.layout.projects[p].tabs.indices.contains(index) else { return }
        let tabID = store.layout.projects[p].tabs[index].id
        if needsConfirm(store.layout.projects[p].tabs[index].root.leaves.map(\.id)), !confirm("Close this tab?") { return }
        guard let (p, t) = store.layout.projects.enumerated().lazy
            .compactMap({ p, project in project.tabs.firstIndex { $0.id == tabID }.map { (p, $0) } }).first else { return }
        store.layout.projects[p].tabs[t].root.leaves.map(\.id).forEach(destroy)
        removeTab(project: p, at: t)
        store.changed()
        render()
    }

    /// Removes a tab and keeps the active tab pointing at the same tab.
    private func removeTab(project p: Int, at t: Int) {
        store.layout.projects[p].tabs.remove(at: t)
        if store.layout.projects[p].scratch == true, store.layout.projects[p].tabs.isEmpty { dropProject(p); return }
        let count = store.layout.projects[p].tabs.count
        var active = store.layout.projects[p].activeTab
        if t < active { active -= 1 }
        store.layout.projects[p].activeTab = max(0, min(active, count - 1))
    }

    private func moveTab(_ from: Int, _ to: Int) {
        guard let p = activeProjectIndex else { return }
        var project = store.layout.projects[p]
        guard project.tabs.indices.contains(from), project.tabs.indices.contains(to) else { return }
        let active = project.tabs[project.activeTab].id
        project.tabs.insert(project.tabs.remove(at: from), at: to)
        project.activeTab = project.tabs.firstIndex { $0.id == active } ?? 0
        store.layout.projects[p] = project
        store.changed()
        render()
    }

    private func moveProject(_ from: Int, _ to: Int) {
        var projects = store.layout.projects
        guard projects.indices.contains(from), projects.indices.contains(to) else { return }
        let active = projects.indices.contains(store.layout.activeProject) ? projects[store.layout.activeProject].id : nil
        projects.insert(projects.remove(at: from), at: to)
        store.layout.projects = projects
        store.layout.activeProject = projects.firstIndex { $0.id == active } ?? 0
        store.changed()
        render()
    }

    private func selectTab(_ index: Int) {
        guard let p = activeProjectIndex, store.layout.projects[p].tabs.indices.contains(index) else { return }
        store.layout.projects[p].activeTab = index
        store.changed()
        render()
    }

    private func selectProject(_ index: Int) {
        guard store.layout.projects.indices.contains(index) else { return }
        store.layout.activeProject = index
        store.changed()
        render()
    }

    private func removeProject(_ index: Int) {
        guard store.layout.projects.indices.contains(index) else { return }
        let project = store.layout.projects[index]
        if needsConfirm(project.tabs.flatMap { $0.root.leaves.map(\.id) }),
           !confirm("Remove project “\(project.name)”?") { return }
        guard let i = store.layout.projects.firstIndex(where: { $0.id == project.id }) else { return }
        store.layout.projects[i].tabs.flatMap { $0.root.leaves.map(\.id) }.forEach(destroy)
        dropProject(i)
        store.changed()
        render()
    }

    /// Removes a project and keeps the active project pointing at the same project.
    private func dropProject(_ i: Int) {
        store.layout.projects.remove(at: i)
        var active = store.layout.activeProject
        if i < active { active -= 1 }
        store.layout.activeProject = max(0, min(active, store.layout.projects.count - 1))
    }

    /// Shows `path` in the right sidebar, replacing the file shown there.
    func openFile(_ path: String) {
        previewFile?.close()
        previewFile?.removeFromSuperview()
        let f = FilePaneView(id: UUID(), path: path, theme: theme)
        f.onOpenLink = { [unowned self] url in open(url) }
        f.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(f, positioned: .below, relativeTo: previewEdge)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            f.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            f.topAnchor.constraint(equalTo: preview.topAnchor, constant: 34),
            f.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        previewFile = f
        previewTitle.stringValue = (path as NSString).abbreviatingWithTildeInPath
        previewTitle.toolTip = path
        if preview.isHidden { showPreview(true) }
    }
    @objc func togglePreview(_ sender: Any?) {
        guard previewFile != nil else { return NSSound.beep() }
        showPreview(preview.isHidden)
    }
    @objc func closePreview(_ sender: Any?) {
        previewFile?.close()
        previewFile?.removeFromSuperview()
        previewFile = nil
        showPreview(false)
    }
    private func showPreview(_ show: Bool) {
        preview.isHidden = !show
        previewWidth.constant = show ? ((window?.contentView?.bounds.width ?? 1000) * 0.4).rounded() : 0
        previewGap.constant = show ? -6 : 8
    }

    /// Something would be lost by quitting: a process other than an idle shell, or an agent mid-turn.
    var needsConfirmQuit: Bool { status.values.contains(.busy) || views.keys.contains { needsConfirm([$0]) } }

    func terminateAll() {
        captureAgents()
        store.flush()
        for id in Array(views.keys) { destroy(id) }
    }

    private var captureScheduled = false

    /// Coalesced background scan (~5 ms for ~1300 processes), applied on main. Keeps resume commands current
    /// if the app crashes instead of quitting.
    private func scheduleCapture() {
        guard !captureScheduled else { return }
        captureScheduled = true
        DispatchQueue.global(qos: .utility).async {
            let running = Agents.running()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.captureScheduled = false
                    self.apply(running)
                }
            }
        }
    }

    /// Record, per terminal pane, the command that resumes the agent running in it (through the launcher it was
    /// started with); a pane with no agent running forgets any earlier one.
    private func captureAgents() { apply(Agents.running()) }

    private func apply(_ running: [PaneID: String?]) {
        var layout = store.layout
        for p in layout.projects.indices {
            for t in layout.projects[p].tabs.indices {
                layout.projects[p].tabs[t].root = layout.projects[p].tabs[t].root.mapLeaves { spec in
                    guard case let .terminal(cwd, launch) = spec.kind else { return }
                    // Not in `running`: no agent, so it restores as a plain shell. Running with an unknown id: keep.
                    guard let entry = running[spec.id] else { spec.kind = .terminal(cwd: cwd, launch: nil); return }
                    if let command = entry { spec.kind = .terminal(cwd: cwd, launch: Launch(command: command, scrollbackLimit: launch?.scrollbackLimit)) }
                }
            }
        }
        guard layout != store.layout else { return }
        store.layout = layout
        store.changed()
    }

    // MARK: - Control socket

    func handleControl(_ msg: [String: String]) -> String {
        let pane = msg["pane"].flatMap(UUID.init(uuidString:))
        switch msg["cmd"] {
        case "hook":
            guard let id = pane else { return #"{"error":"no pane"}"# }
            switch msg["event"] {
            case "busy": setStatus(id, .busy)
            case "done": setStatus(id, .done)
            case "attention": setStatus(id, .attention)
            default: break
            }
            return "{}"
        case "list":
            var rows: [[String: String]] = []
            for project in store.layout.projects {
                for tab in project.tabs {
                    for leaf in tab.root.leaves {
                        var kind = "terminal"
                        if case .file = leaf.kind { kind = "file" }
                        rows.append(["pane": leaf.id.uuidString, "project": project.name, "kind": kind,
                                     "title": tab.customTitle ?? titles[leaf.id] ?? tab.title,
                                     "status": "\(status[leaf.id] ?? .idle)"])
                    }
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case "focus":
            guard let id = pane, locate(id) != nil else { return #"{"error":"unknown pane"}"# }
            focusPane(id)
            return "{}"
        case "split":
            let axis: Axis = msg["axis"] == "vertical" ? .vertical : .horizontal
            let launch = msg["command"].map { Launch(command: $0, scrollbackLimit: nil) }
            split(axis, kind: .terminal(cwd: cwdFor(pane), launch: launch), from: pane.flatMap { locate($0) != nil ? $0 : nil })
            return #"{"pane":"\#(focusedPane?.uuidString ?? "")"}"#
        case "send":
            if let id = pane { createHidden(id) }   // a restored plain shell not shown yet
            guard let id = pane, let s = surfaceView(for: id)?.surface else { return #"{"error":"unknown pane"}"# }
            let text = (msg["text"] ?? "") + "\r"
            text.withCString { ghostty_surface_text(s, $0, UInt(text.utf8.count)) }
            return "{}"
        case "add":
            guard let path = msg["path"] else { return #"{"error":"no path"}"# }
            addProject(at: URL(fileURLWithPath: path))
            return "{}"
        case "open":
            guard let path = msg["path"] else { return #"{"error":"no path"}"# }
            openFile(path)
            return "{}"
        #if DEBUG
        case "action":   // test harness: run a menu action, e.g. "newTab:", without needing keyboard focus
            let sel = NSSelectorFromString(msg["name"] ?? "")
            guard responds(to: sel) else { return #"{"error":"unknown action"}"# }
            perform(sel, with: nil)
            return "{}"
        case "rclick":   // test harness: a real right-click event at the centre of a pane, through window.sendEvent
            guard let id = pane, let v = views[id], let w = v.window else { return #"{"error":"pane not shown"}"# }
            let at = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            DispatchQueue.main.async {
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    w.sendEvent(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1)!)
                }
            }
            return "{}"
        case "drag":     // test harness: drag `pane` by its header to the `edge` (left/right/up/down) side of `target`
            guard let id = pane, let src = views[id]?.superview, let w = src.window,
                  let dst = msg["target"].flatMap(UUID.init(uuidString:)).flatMap({ views[$0] }) else { return #"{"error":"pane not shown"}"# }
            let from = src.convert(NSPoint(x: src.bounds.midX, y: src.bounds.maxY - 5), to: nil)
            let r = dst.convert(dst.bounds, to: nil)
            let to: NSPoint = switch msg["edge"] {
            case "left": NSPoint(x: r.minX + 10, y: r.midY)
            case "right": NSPoint(x: r.maxX - 10, y: r.midY)
            case "up": NSPoint(x: r.midX, y: r.maxY - 10)
            default: NSPoint(x: r.midX, y: r.minY + 10)
            }
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            DispatchQueue.main.async {
                NSApp.postEvent(ev(.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)), atStart: false)
                NSApp.postEvent(ev(.leftMouseDragged, to), atStart: false)
                NSApp.postEvent(ev(.leftMouseUp, to), atStart: false)
                w.sendEvent(ev(.leftMouseDown, from))
            }
            return "{}"
        case "tabdrag":  // test harness: drag tab (or with in=sidebar, project) `from` onto `to`'s position
            let center = msg["in"] == "sidebar" ? sidebar.rowCenter : tabBar.tabCenter
            guard let a = msg["from"].flatMap(Int.init).flatMap(center), let b = msg["to"].flatMap(Int.init).flatMap(center),
                  let w = tabBar.window else { return #"{"error":"no tab"}"# }
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let to = NSPoint(x: b.x + (b.x - a.x).sign(10), y: b.y + (b.y - a.y).sign(6))
            DispatchQueue.main.async {
                NSApp.postEvent(ev(.leftMouseDragged, NSPoint(x: (a.x + to.x) / 2, y: (a.y + to.y) / 2)), atStart: false)
                NSApp.postEvent(ev(.leftMouseDragged, to), atStart: false)
                // hold: stay mid-drag for that many seconds (for screenshots); control commands can't run until release
                nonisolated(unsafe) let up = ev(.leftMouseUp, to)
                if let hold = msg["hold"].flatMap(Double.init) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + hold) { NSApp.postEvent(up, atStart: false) }
                } else {
                    NSApp.postEvent(up, atStart: false)
                }
                w.sendEvent(ev(.leftMouseDown, a))
            }
            return "{}"
        case "menu":     // test harness: pick a pane's "Move to Tab" entry by title
            guard let id = pane, let move = paneMenu(id),
                  let item = move.item(withTitle: msg["item"] ?? ""), let action = item.action else { return #"{"error":"no item"}"# }
            NSApp.sendAction(action, to: item.target, from: item)
            return "{}"
        #endif
        default:
            return #"{"error":"unknown command"}"#
        }
    }

    private func cwdFor(_ pane: PaneID?) -> String {
        if let id = pane, let spec = spec(id), case let .terminal(cwd, _) = spec.kind { return cwd }
        return cwdForNewPane()
    }

    // MARK: - NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) { syncVisibility() }
    func windowDidBecomeKey(_ notification: Notification) { (window?.firstResponder as? SurfaceView)?.syncFocus() }
    func windowDidResignKey(_ notification: Notification) { (window?.firstResponder as? SurfaceView)?.syncFocus() }

    /// Single-window app: closing the window is quitting, so it goes through the quit confirmation
    /// instead of leaving a running app with no window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) { newTab(kind: .terminal(cwd: cwdForNewPane(), launch: nil)) }
    @objc func newScratchTerminal(_ sender: Any?) {
        if let i = store.layout.projects.firstIndex(where: { $0.scratch == true }) {
            store.layout.activeProject = i
        } else {
            store.layout.projects.append(Project(id: UUID(), path: NSHomeDirectory(), name: "Scratch", tabs: [],
                                                 activeTab: 0, scratch: true))
            store.layout.activeProject = store.layout.projects.count - 1
        }
        newTab(kind: .terminal(cwd: NSHomeDirectory(), launch: nil))
    }
    @objc func movePaneToTab(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID], let pane = ids.first else { return }
        movePane(pane, to: ids.dropFirst().first)
    }
    @objc func splitRight(_ sender: Any?) { split(.horizontal, kind: .terminal(cwd: cwdForNewPane(), launch: nil)) }
    @objc func splitDown(_ sender: Any?) { split(.vertical, kind: .terminal(cwd: cwdForNewPane(), launch: nil)) }
    @objc func closePane(_ sender: Any?) {
        if let id = focusedPane { closePane(id) }
    }
    @objc func closeTab(_ sender: Any?) {
        if let p = activeProjectIndex { closeTab(at: store.layout.projects[p].activeTab) }
    }
    @objc func equalizeSplits(_ sender: Any?) {
        mutateActiveTab { $0.root = $0.root.equalized() }
        render()
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }
    private func cycleTab(_ d: Int) {
        guard let p = activeProjectIndex else { return }
        let n = store.layout.projects[p].tabs.count
        guard n > 0 else { return }
        selectTab((store.layout.projects[p].activeTab + d + n) % n)
    }
    @objc func selectProjectByTag(_ sender: NSMenuItem) { selectProject(sender.tag - 1) }
    @objc func nextProject(_ sender: Any?) { cycleProject(1) }
    @objc func previousProject(_ sender: Any?) { cycleProject(-1) }
    private func cycleProject(_ d: Int) {
        let n = store.layout.projects.count
        guard n > 0 else { return }
        selectProject((store.layout.activeProject + d + n) % n)
    }
    @objc func addProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }
    private func addProject(at url: URL) {
        if let i = store.layout.projects.firstIndex(where: { $0.path == url.path && $0.scratch != true }) { selectProject(i); return }
        let spec = PaneSpec(id: UUID(), kind: .terminal(cwd: url.path, launch: nil))
        store.layout.projects.append(Project(id: UUID(), path: url.path, name: url.lastPathComponent,
                                             tabs: [Tab(id: UUID(), title: "Terminal", root: .leaf(spec), focused: spec.id)],
                                             activeTab: 0))
        store.layout.activeProject = store.layout.projects.count - 1
        store.changed()
        render()
    }
    // Not `toggleSidebar(_:)`: NSWindow implements that action itself and, earlier in the responder chain, swallows it.
    @objc func toggleProjectSidebar(_ sender: Any?) {
        store.layout.sidebarVisible.toggle()
        store.changed()
        let visible = store.layout.sidebarVisible
        sidebar.isHidden = !visible
        sidebarWidth.constant = visible ? 220 : 0
    }
    @objc func focusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusDown(_ sender: Any?) { moveFocus(.down) }
    private func moveFocus(_ d: FocusDirection) {
        guard let id = focusedPane, let n = tree.neighbor(of: id, d) else { return }
        focus(n)
    }
    /// Focus a pane in the active tab. The model is updated directly because markdown panes never become first responder.
    private func focus(_ id: PaneID) {
        guard let v = views[id] else { return }
        window?.makeFirstResponder(v)
        paneFocused(id)
    }
    @objc func focusNextPane(_ sender: Any?) { cyclePane(1) }
    @objc func focusPreviousPane(_ sender: Any?) { cyclePane(-1) }
    private func cyclePane(_ d: Int) {
        guard let tab = activeTab, let id = focusedPane else { return }
        let leaves = tab.root.leaves.map(\.id)
        guard let i = leaves.firstIndex(of: id) else { return }
        focus(leaves[(i + d + leaves.count) % leaves.count])
    }
    @objc func clearScreen(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("clear_screen") }
    @objc func find(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("start_search") }
    @objc func increaseFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("increase_font_size:1") }
    @objc func decreaseFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("decrease_font_size:1") }
    @objc func resetFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("reset_font_size") }
    @objc func launchPreset(_ sender: NSMenuItem) {
        guard let preset = store.layout.presets.first(where: { $0.key == sender.tag }) else { return }
        let launch = Launch(command: preset.command, scrollbackLimit: preset.scrollbackLimit)
        let kind = PaneKind.terminal(cwd: activeProjectIndex.map { store.layout.projects[$0].path } ?? NSHomeDirectory(),
                                     launch: launch)
        if activeTab == nil { newTab(kind: kind) } else { split(.horizontal, kind: kind) }
    }
    @objc func openFileDialog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url.path)
    }
    @objc func selectTheme(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { applyTheme(id) }
    }
}

#if DEBUG
private extension CGFloat { func sign(_ m: CGFloat) -> CGFloat { self > 0 ? m : self < 0 ? -m : 0 } }
#endif

extension SplitNode {
    func withRatios(from other: SplitNode) -> SplitNode {
        switch (self, other) {
        case let (.split(axis, _, a, b), .split(oAxis, ratio, oa, ob)) where axis == oAxis:
            return .split(axis: axis, ratio: ratio, a: a.withRatios(from: oa), b: b.withRatios(from: ob))
        default:
            return self
        }
    }
}

extension WorkspaceController {
    nonisolated static func stripStatusGlyphs(_ title: String) -> String {
        String(String.UnicodeScalarView(title.unicodeScalars.drop {
            $0.properties.generalCategory == .otherSymbol || $0 == "·" || $0.properties.isWhitespace
        }))
    }
}

/// The preview sidebar's left edge: drag to resize. Reports horizontal movement since the last event.
@MainActor final class ResizeEdge: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaX) }
}
