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
    /// Find on an agent pane searches its session transcript (the terminal only holds the screen; the agent scrolls internally),
    /// shown in the right sidebar. `transcript` is the file while that mode is on; `findResolving` while we look for it.
    private var transcript: URL?
    private var transcriptView: TranscriptSearchView?
    private var transcriptDebounce: DispatchWorkItem?
    private var findResolving = false
    private var inspectorWasCollapsed = true
    private var savedPreviewTitle: (text: String, tip: String?) = ("", nil)
    private var activity: NSObjectProtocol?

    private let sidebar = SidebarView(frame: .zero)
    private let tabBar = TabBarView(frame: .zero)
    private let content = NSView()
    private let findBar = FindBar(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")
    private lazy var tree = SplitTreeView { [unowned self] spec in self.view(for: spec) }
    /// Native split: glass sidebar (projects) | terminals | inspector (the file ⌘-clicked last). AppKit owns the
    /// materials, divider dragging and the collapse animations.
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var collapseObservation: NSKeyValueObservation?
    private let preview = NSView()
    private let previewTitle = NSTextField(labelWithString: "No file. ⌘-click a path to preview it here.")
    private var previewFile: FilePaneView?

    init(store: Store, runtime: Runtime) {
        self.store = store
        self.runtime = runtime
        self.theme = Theme.named(store.layout.theme)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.appearance = theme.appearance
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        runtime.delegate = self
        buildLayout()
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        window.setFrameAutosaveName("Main")
        wireCallbacks()
        paintTheme()
        restore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func buildLayout() {
        func controller(_ v: NSView) -> NSViewController { let c = NSViewController(); c.view = v; return c }

        let main = NSView()
        main.wantsLayer = true
        for v in [content, findBar, emptyLabel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        main.addSubview(content)
        content.wantsLayer = true
        tree.frame = content.bounds
        tree.autoresizingMask = [.width, .height]
        content.addSubview(tree)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        content.addSubview(emptyLabel)
        findBar.isHidden = true
        content.addSubview(findBar)

        previewTitle.font = .systemFont(ofSize: 12, weight: .medium)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.lineBreakMode = .byTruncatingMiddle
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewTitle)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: main.safeAreaLayoutGuide.topAnchor),   // below the toolbar
            content.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            previewTitle.topAnchor.constraint(equalTo: preview.safeAreaLayoutGuide.topAnchor, constant: 6),
            previewTitle.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 16),
            previewTitle.trailingAnchor.constraint(lessThanOrEqualTo: preview.trailingAnchor, constant: -16),
        ])

        sidebarItem = NSSplitViewItem(sidebarWithViewController: controller(sidebar))
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.isCollapsed = !store.layout.sidebarVisible
        let mainItem = NSSplitViewItem(viewController: controller(main))
        mainItem.minimumThickness = 300
        inspectorItem = NSSplitViewItem(inspectorWithViewController: controller(preview))
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 1600
        inspectorItem.isCollapsed = true
        for item in [sidebarItem!, mainItem, inspectorItem!] { split.addSplitViewItem(item) }
        split.splitView.autosaveName = "Workbench.split"   // divider positions survive relaunch
        window?.contentViewController = split
        // Collapsing from the toolbar button bypasses our actions; persist whatever AppKit did.
        collapseObservation = sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateWindowTitle()
                guard let self, self.store.layout.sidebarVisible == self.sidebarItem.isCollapsed else { return }
                self.store.layout.sidebarVisible = !self.sidebarItem.isCollapsed
                self.store.changed()
            }
        }
    }

    private func wireCallbacks() {
        sidebar.onSelect = { [unowned self] i in project(atRow: i).map(selectProject) }
        sidebar.onRemove = { [unowned self] i in project(atRow: i).map(removeProject) }
        sidebar.onShowHidden = { [unowned self] on in setShowHidden(on) }
        sidebar.onToggleHidden = { [unowned self] i in toggleHidden(row: i) }
        sidebar.onSelectScratch = { [unowned self] i in scratch(atRow: i).map(selectProject) }
        sidebar.onCloseScratch = { [unowned self] i in scratch(atRow: i).map(closeScratch) }
        sidebar.onNewScratch = { [unowned self] in newScratchTerminal(nil) }
        tabBar.onSelect = { [unowned self] i in selectTab(i) }
        tabBar.onClose = { [unowned self] i in closeTab(at: i) }
        tabBar.onNew = { [unowned self] in newTab(nil) }
        sidebar.onRename = { [unowned self] i, name in renameProject(project(atRow: i) ?? -1, name) }
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
        findBar.onChange = { [unowned self] text in
            if transcript != nil { scheduleTranscriptSearch() } else { findSurface?.perform("search:\(text)") }
        }
        findBar.onNext = { [unowned self] in findNext(nil) }
        findBar.onPrevious = { [unowned self] in findPrevious(nil) }
        findBar.onClose = { [unowned self] in closeFind() }
    }

    // MARK: - Model access

    /// The sidebar lists either the active or the hidden projects; its rows map to project indices through this.
    private var showingHidden: Bool { store.layout.showHidden ?? false }
    private var visibleProjects: [Int] { visibleProjectIndices(store.layout.projects, hidden: showingHidden) }
    private func project(atRow r: Int) -> Int? { let v = visibleProjects; return v.indices.contains(r) ? v[r] : nil }
    private func scratch(atRow r: Int) -> Int? { let v = scratchProjectIndices(store.layout.projects); return v.indices.contains(r) ? v[r] : nil }

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
        if let f = findPane, !(activeTab?.root.contains(f) ?? false) { closeFind(refocus: false) }
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

    /// With the sidebar collapsed the toolbar names the active project (and its path); expanded, the sidebar does.
    private func updateWindowTitle() {
        guard let window else { return }
        let project = sidebarItem.isCollapsed ? activeProjectIndex.map { store.layout.projects[$0] } : nil
        window.title = project?.name ?? ""
        window.subtitle = (project?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""
        window.titleVisibility = project == nil ? .hidden : .visible
    }

    private func updateChrome() {
        updateWindowTitle()
        let projects = store.layout.projects
        let visible = visibleProjects
        sidebar.update(rows: visible.map { projects[$0] }.map { p in
            let items = tabItems(p)
            return SidebarRow(id: p.id, name: p.name, path: p.path, status: items.map(\.status).max() ?? .idle,
                              tabCount: items.count)
        }, selected: visible.firstIndex(of: store.layout.activeProject) ?? -1,
           hiddenCount: projects.count { $0.scratch != true && $0.hidden == true }, showingHidden: showingHidden, theme: theme)
        let scratches = scratchProjectIndices(projects)
        sidebar.updateScratch(rows: scratches.enumerated().map { n, i in
            let p = projects[i]
            return SidebarRow(id: p.id, name: scratches.count > 1 ? "Scratch Terminal \(n + 1)" : "Scratch Terminal", path: p.path,
                              status: tabItems(p).map(\.status).max() ?? .idle, tabCount: p.tabs.count)
        }, selected: scratches.firstIndex(of: store.layout.activeProject) ?? -1, theme: theme)
        if let p = activeProjectIndex {
            let project = projects[p]
            tabBar.update(items: tabItems(project), selected: project.activeTab, theme: theme)
            tree.updateHeaders(focused: focusedPane, theme: theme, status: { [status] in status[$0] ?? .idle }) { [titles] id in
                if let t = titles[id] { return t }
                switch spec(id)?.kind {
                case let .file(path)?: return (path as NSString).lastPathComponent
                case let .terminal(cwd, _)?: return Self.folderTitle(cwd)
                case nil: return ""
                }
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

    /// A project's tabs as the tab bar and the sidebar show them: title, and the busiest status among their panes.
    private func tabItems(_ p: Project) -> [TabItem] {
        p.tabs.map { TabItem(title: title(of: $0), status: $0.root.leaves.map { status[$0.id] ?? .idle }.max() ?? .idle) }
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
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    private func paintTheme() {
        window?.appearance = theme.appearance
        window?.backgroundColor = theme.color("background")
        content.layer?.backgroundColor = theme.color("background").cgColor
        for v in views.values { (v as? FilePaneView)?.apply(theme: theme) }
        previewFile?.apply(theme: theme)
        findBar.apply(theme: theme)
    }

    // MARK: - Focus & status

    private func paneFocused(_ id: PaneID) {
        if let f = findPane, f != id, transcript != nil || findResolving { closeFind(refocus: false) }   // the transcript list belongs to one pane
        if let (p, t) = locate(id), store.layout.projects[p].tabs[t].focused != id {
            store.layout.projects[p].tabs[t].focused = id
            store.changed()
        }
        if let s = status[id], s == .done || s == .attention { status[id] = .idle }
        updateChrome()
    }

    func focusPane(_ id: PaneID) {
        guard let (p, t) = locate(id) else { return }
        activate(p)
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
            // not only through hooked launchers. Spinner gone means the turn ended.
            let spinning = raw.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
            let t = Self.displayTitle(raw)
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
            scheduleCapture()   // a command ended: maybe an agent exited (its count leaves the sidebar)
        case let .openURL(url):
            openURL(url, from: id)
        case .closeRequested:
            closePane(id, confirm: false)
        case .startSearch, .endSearch, .searchTotal, .searchSelected:
            if transcript == nil { terminalSearchEvent(id, event) }
        }
    }

    private func terminalSearchEvent(_ id: PaneID, _ event: PaneEvent) {
        switch event {
        case let .startSearch(needle):
            if let old = findPane, old != id { surfaceView(for: old)?.perform("end_search") }
            findPane = id
            searchCounts = (-1, -1)
            findBar.isHidden = false
            findBar.setCounts(total: -1, selected: -1)
            findBar.show(needle: needle)
        case .endSearch:
            if findPane == id { hideFind() }
        case let .searchTotal(n):
            searchCounts.total = n
            findBar.setCounts(total: searchCounts.total, selected: searchCounts.selected)
        case let .searchSelected(n):
            searchCounts.selected = n
            findBar.setCounts(total: searchCounts.total, selected: searchCounts.selected)
        default:
            break
        }
    }

    private var findSurface: SurfaceView? { findPane.flatMap { surfaceView(for: $0) } }

    /// Closes the find bar (and the transcript list, restoring the sidebar); focus goes back to the terminal (`refocus`).
    private func hideFind(refocus: Bool = true) {
        let v = findSurface
        findBar.isHidden = true
        findPane = nil
        findResolving = false
        endTranscript()
        if refocus, let v { window?.makeFirstResponder(v) }
    }

    /// The user ended the search: also ends libghostty's.
    private func closeFind(refocus: Bool = true) {
        if transcript == nil { findSurface?.perform("end_search") }
        hideFind(refocus: refocus)
    }

    /// Find is on an agent pane: list matches from its transcript in the right sidebar until the search ends.
    private func beginTranscriptFind(_ id: PaneID, _ url: URL) {
        transcript = url
        findBar.isHidden = false
        findBar.setCounts(total: -1, selected: -1)
        findBar.show(needle: "")
        let v = TranscriptSearchView()
        v.onSelect = { [unowned self] _ in transcriptCounts() }
        v.onCancel = { [unowned self] in closeFind() }
        v.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            v.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        previewFile?.isHidden = true
        savedPreviewTitle = (previewTitle.stringValue, previewTitle.toolTip)
        previewTitle.stringValue = "Session transcript"
        previewTitle.toolTip = url.path
        inspectorWasCollapsed = inspectorItem.isCollapsed
        if inspectorWasCollapsed { togglePreview(nil) }
        transcriptView = v
    }

    /// Puts the sidebar back as it was: the previous file (or nothing, collapsed).
    private func endTranscript() {
        guard transcript != nil else { return }
        transcript = nil
        transcriptDebounce?.cancel()
        transcriptDebounce = nil
        TranscriptSearch.cancel()
        transcriptView?.removeFromSuperview()
        transcriptView = nil
        previewFile?.isHidden = false
        previewTitle.stringValue = savedPreviewTitle.text
        previewTitle.toolTip = savedPreviewTitle.tip
        if inspectorWasCollapsed, !inspectorItem.isCollapsed { togglePreview(nil) }
    }

    private func scheduleTranscriptSearch() {
        transcriptDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.runTranscriptSearch() } }
        transcriptDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func runTranscriptSearch() {
        guard let url = transcript else { return }
        transcriptDebounce?.cancel()
        transcriptDebounce = nil
        let query = findBar.text
        TranscriptSearch.search(url, query) { [weak self] result in
            guard let self, transcript == url, let v = transcriptView else { return }
            v.show(result, query: query)
            transcriptCounts()
        }
    }

    private func transcriptCounts() {
        guard let v = transcriptView else { return }
        findBar.setCounts(total: findBar.text.isEmpty ? -1 : v.count, selected: v.selected)
    }

    private func stepTranscript(_ d: Int) {
        if transcriptDebounce != nil { runTranscriptSearch(); return }   // typed just now: results first
        guard let v = transcriptView, v.count > 0 else { return }
        v.select((max(v.selected, 0) + d + v.count) % v.count)
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
        activate(p)
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
            store.layout.projects[p].tabs.append(Tab(id: UUID(), title: Self.title(of: spec), root: .leaf(spec), focused: spec.id))
            store.layout.projects[p].activeTab = store.layout.projects[p].tabs.count - 1
        }
        activate(p)
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
        store.layout.projects[p].tabs.append(Tab(id: UUID(), title: Self.title(of: spec), root: .leaf(spec), focused: spec.id))
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
        if findPane == id { hideFind(refocus: false) }
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

    /// `from`/`to` are rows of the list being shown.
    private func moveProject(_ from: Int, _ to: Int) {
        guard let projects = reorderedProjects(store.layout.projects, map: visibleProjects, from: from, to: to) else { return }
        let active = activeProjectIndex.map { store.layout.projects[$0].id }
        store.layout.projects = projects
        store.layout.activeProject = projects.firstIndex { $0.id == active } ?? store.layout.activeProject
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
        activate(index)
        store.changed()
        render()
    }

    /// Makes `p` the active project and switches the sidebar to the list it is in.
    private func activate(_ p: Int) {
        store.layout.activeProject = p
        guard store.layout.projects[p].scratch != true else { return }   // not in either list: leave the list as is
        let hidden = store.layout.projects[p].hidden == true
        if hidden != showingHidden { store.layout.showHidden = hidden ? true : nil }
    }

    /// The Hidden/Active switch only changes the list; the active project stays until the user clicks another.
    private func setShowHidden(_ on: Bool) {
        store.layout.showHidden = on ? true : nil
        store.changed()
        render()
    }

    /// Hide Project (Active view) / Show Project (Hidden view). Terminals and agents of a hidden project keep running.
    private func toggleHidden(row: Int) {
        guard let i = project(atRow: row) else { return }
        let pos = visibleProjects.firstIndex(of: i) ?? 0
        let hiding = !showingHidden
        store.layout.projects[i].hidden = hiding ? true : nil
        if hiding, i == store.layout.activeProject { selectVisible(near: pos) }
        store.changed()
        render()
    }

    /// Selects the project now at row `pos` of the list shown (the last one if the list got shorter), or none if empty.
    private func selectVisible(near pos: Int) {
        let v = visibleProjects
        store.layout.activeProject = v.isEmpty ? -1 : v[min(pos, v.count - 1)]
    }

    private func removeProject(_ index: Int) {
        guard store.layout.projects.indices.contains(index), let window else { return }
        let project = store.layout.projects[index]
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.name)”?"
        alert.informativeText = "Its tabs and terminals will be closed. The folder on disk is not touched."
            + (needsConfirm(project.tabs.flatMap { $0.root.leaves.map(\.id) }) ? " Running processes will be terminated." : "")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let i = store.layout.projects.firstIndex(where: { $0.id == project.id }) else { return }
            store.layout.projects[i].tabs.flatMap { $0.root.leaves.map(\.id) }.forEach(destroy)
            dropProject(i)
            store.changed()
            render()
        }
    }

    /// Closes a scratch terminal: no project sheet, only the usual running-process confirmation.
    private func closeScratch(_ index: Int) {
        guard store.layout.projects.indices.contains(index) else { return }
        let id = store.layout.projects[index].id
        let panes = store.layout.projects[index].tabs.flatMap { $0.root.leaves.map(\.id) }
        if needsConfirm(panes), !confirm("Close this scratch terminal?") { return }
        guard let i = store.layout.projects.firstIndex(where: { $0.id == id }) else { return }   // the modal may have changed things
        store.layout.projects[i].tabs.flatMap { $0.root.leaves.map(\.id) }.forEach(destroy)
        dropProject(i)
        store.changed()
        render()
    }

    /// Removes a project; if it was the active one, the next project in the list shown takes over.
    private func dropProject(_ i: Int) {
        // A closed scratch (never in the list) hands over to the first project shown.
        let pos = i == store.layout.activeProject ? visibleProjects.firstIndex(of: i) ?? (store.layout.projects[i].scratch == true ? 0 : nil) : nil
        store.layout.projects.remove(at: i)
        if let pos { selectVisible(near: pos); return }
        var active = store.layout.activeProject
        if i < active { active -= 1 }
        store.layout.activeProject = active < 0 ? active : max(0, min(active, store.layout.projects.count - 1))
    }

    /// Shows `path` in the right sidebar, replacing the file shown there.
    func openFile(_ path: String) {
        if transcript != nil { closeFind(refocus: false) }
        previewFile?.close()
        previewFile?.removeFromSuperview()
        let f = FilePaneView(id: UUID(), path: path, theme: theme)
        f.onOpenLink = { [unowned self] url in open(url) }
        f.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            f.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            f.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 4),
            f.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        previewFile = f
        previewTitle.stringValue = (path as NSString).abbreviatingWithTildeInPath
        previewTitle.toolTip = path
        if inspectorItem.isCollapsed { togglePreview(nil) }
    }
    @objc func togglePreview(_ sender: Any?) { split.toggleInspector(sender) }

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
        updateChrome()   // the sidebar's agent counts
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
        case "tabdrag":  // test harness: drag tab `from` onto tab `to`'s position
            guard let a = msg["from"].flatMap(Int.init).flatMap(tabBar.tabCenter), let b = msg["to"].flatMap(Int.init).flatMap(tabBar.tabCenter),
                  let w = tabBar.window else { return #"{"error":"no tab"}"# }
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let to = NSPoint(x: b.x + (b.x > a.x ? 10 : -10), y: b.y)
            DispatchQueue.main.async {
                NSApp.postEvent(ev(.leftMouseDragged, NSPoint(x: (a.x + to.x) / 2, y: a.y)), atStart: false)
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
            activate(i)
        } else {
            store.layout.projects.append(Project(id: UUID(), path: NSHomeDirectory(), name: "Scratch", tabs: [],
                                                 activeTab: 0, scratch: true))
            activate(store.layout.projects.count - 1)
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
    @objc func selectProjectByTag(_ sender: NSMenuItem) { project(atRow: sender.tag - 1).map(selectProject) }
    @objc func nextProject(_ sender: Any?) { cycleProject(1) }
    @objc func previousProject(_ sender: Any?) { cycleProject(-1) }
    private func cycleProject(_ d: Int) {
        let v = visibleProjects
        guard !v.isEmpty else { return }
        let cur = v.firstIndex(of: store.layout.activeProject) ?? (d > 0 ? -1 : 0)   // none selected: start at an end
        selectProject(v[(cur + d + v.count) % v.count])
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
                                             tabs: [Tab(id: UUID(), title: Self.title(of: spec), root: .leaf(spec), focused: spec.id)],
                                             activeTab: 0))
        activate(store.layout.projects.count - 1)   // also leaves the Hidden list
        store.changed()
        render()
    }
    // Not `toggleSidebar(_:)` in the menu: NSWindow implements that action itself and, earlier in the responder chain,
    // swallows it. The split view animates it; collapseObservation persists it.
    @objc func toggleProjectSidebar(_ sender: Any?) { split.toggleSidebar(sender) }
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
    @objc func find(_ sender: Any?) {
        guard let id = focusedPane, let v = surfaceView(for: id) else { return }
        if findPane == id {
            if transcript != nil { findBar.show(needle: findBar.text) } else if !findResolving { v.perform("start_search") }
            return
        }
        if findPane != nil { closeFind(refocus: false) }
        // An agent pane searches its transcript; finding it scans processes and disk, so off the main thread.
        findPane = id
        findResolving = true
        TranscriptSearch.locate(id) { [weak self] url in
            guard let self, findResolving, findPane == id else { return }
            findResolving = false
            if let url { beginTranscriptFind(id, url) } else { surfaceView(for: id)?.perform("start_search") }
        }
    }
    @objc func findNext(_ sender: Any?) { if transcript != nil { stepTranscript(1) } else { findSurface?.perform("navigate_search:next") } }
    @objc func findPrevious(_ sender: Any?) { if transcript != nil { stepTranscript(-1) } else { findSurface?.perform("navigate_search:previous") } }
    @objc func increaseFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("increase_font_size:1") }
    @objc func decreaseFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("decrease_font_size:1") }
    @objc func resetFontSize(_ sender: Any?) { focusedPane.flatMap { surfaceView(for: $0) }?.perform("reset_font_size") }
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
    /// A terminal title as tabs and headers show it. Agent spinner/status glyphs are dropped (the status dot shows
    /// them), and a shell prompt's title (`user@host:~/dir`, or a bare path) becomes the folder name: the same text a
    /// new tab starts with, so a tab doesn't change width when its shell comes up.
    nonisolated static func displayTitle(_ raw: String) -> String {
        let t = String(String.UnicodeScalarView(raw.unicodeScalars.drop {
            $0.properties.generalCategory == .otherSymbol || $0 == "·" || $0.properties.isWhitespace
        }))
        var path = Substring(t)
        if let colon = t.firstIndex(of: ":"), let at = t.firstIndex(of: "@"), at < colon, !t[..<colon].contains(" ") {
            path = t[t.index(after: colon)...]
        }
        guard path.hasPrefix("/") || path.hasPrefix("~"), !path.contains(" ") else { return t }
        return folderTitle(String(path))
    }

    /// What a new tab is called before its pane reports a title.
    nonisolated static func title(of spec: PaneSpec) -> String {
        switch spec.kind {
        case let .terminal(cwd, _): folderTitle(cwd)
        case let .file(path): (path as NSString).lastPathComponent
        }
    }

    nonisolated static func folderTitle(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p == NSHomeDirectory() ? "~" : (p as NSString).lastPathComponent
    }
}

extension NSToolbarItem.Identifier {
    static let tabs = NSToolbarItem.Identifier("tabs")
    static let addProject = NSToolbarItem.Identifier("addProject")
}

/// Unified toolbar: sidebar toggle over the sidebar, the tab capsule over the terminals, inspector toggle over the preview.
extension WorkspaceController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .addProject, .sidebarTrackingSeparator, .tabs, .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == .addProject {
            item.label = "Add Project"
            item.toolTip = "Add Project"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Project")
            item.target = self
            item.action = #selector(addProject(_:))
            return item
        }
        guard id == .tabs else { return nil }
        item.view = tabBar
        item.isBordered = false   // the tab bar draws its own glass capsule
        item.visibilityPriority = .high
        return item
    }
}
