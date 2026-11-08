# Workbench

Native macOS terminal IDE for running many Claude Code / Codex sessions. Swift 6 + AppKit + GhosttyKit (libghostty, our fork `jacobgreenberg/ghostty` branch `workbench` (based on cmux `manaflow-ai/ghostty@cb1ef70`), built from source by `scripts/ghosttykit.sh` at its pinned SHA). Single SwiftPM executable target `Workbench`, all sources in `Sources/Workbench/`. Reference Ghostty sources (read-only) are in `vendor/ghostty-src/macos/Sources/Ghostty/`; the C API is `vendor/ghostty-src/include/ghostty.h`.

Build: `swift build -c release`, then `scripts/bundle.sh` → `build.noindex/Workbench.app` (`--install` rsyncs it file by file into /Applications/Workbench.app, never moving the bundle: WorkbenchHost's privacy grants are keyed by its path, and a running host whose bundle moved loses them). Run: `open build.noindex/Workbench.app`.

Tests: `swift build && .build/debug/Workbench --selfcheck` (the in-binary self-checks, DEBUG; main.swift lists them). The GUI needs a bundle (UNUserNotificationCenter aborts without one): `scripts/bundle.sh --debug` → `build.noindex/Workbench-debug.app`; run its `Contents/MacOS/Workbench` with `PANE_STATE_DIR=<short dir>` so it never shares the socket, layout or sessions of the real app, and drive it over `<dir>/pane.sock` (the test-harness commands in WorkspaceController.handleControl).

Rules: AppKit only (no SwiftUI). macOS 27+. Chrome is Liquid Glass (NSGlassEffectView panels/capsules, `HandButton.glass` round buttons) floating over the solid theme background; never put glass over a terminal surface except transient overlays (find bar), since glass over changing content recomposites every frame. No polling timers. Every C callback is a nonisolated `@convention(c)` function that copies data into owned Swift values and hops to main with `DispatchQueue.main.async`. Never touch a SurfaceView's `wantsLayer`/`layer` before `ghostty_surface_new`. Import GhosttyKit as `@preconcurrency import GhosttyKit`.

## Contract (cross-file interfaces — keep exact)

```swift
// Model.swift
typealias PaneID = UUID
struct Launch: Codable, Equatable, Sendable {
    var command: String          // typed into the shell as initial input; rewritten at quit to the running agent's resume command
    var scrollbackLimit: Int?    // bytes; nil = global default
}
enum PaneKind: Codable, Equatable, Sendable { case terminal(cwd: String, launch: Launch?), file(path: String), web(url: String) }   // file: markdown preview or highlighted code; coded as "markdown" for old layouts. web: WebPaneView (WebPaneView.swift), a WKWebView (system WebKit) on an http(s) URL, e.g. a localhost dashboard; `pane open <http(s) url>` focuses the active tab's pane on it or splits one in right; header title = page title; links off its host open in the browser (http/https only); unreachable → a note with Try again; ephemeral website data, loads ignore the cache; ⌘R (focused) reloads from origin; its header has no Read Aloud capsule. No auto-reload: a page that wants it reloads itself
struct PaneSpec: Codable, Equatable, Sendable { var id: PaneID; var kind: PaneKind }
enum Axis: String, Codable, Sendable { case horizontal /* a | b, ⌘D */, vertical /* a over b, ⇧⌘D */ }
indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(PaneSpec)
    case split(axis: Axis, ratio: Double, a: SplitNode, b: SplitNode)
}
extension SplitNode {
    var leaves: [PaneSpec]                                        // depth-first, a before b
    func contains(_ id: PaneID) -> Bool
    func replacing(_ id: PaneID, with node: SplitNode) -> SplitNode
    func removing(_ id: PaneID) -> SplitNode?                      // nil if tree becomes empty; parent split collapses to sibling
    func updating(_ id: PaneID, _ f: (inout PaneSpec) -> Void) -> SplitNode
    func mapLeaves(_ f: (inout PaneSpec) -> Void) -> SplitNode    // f applied to every leaf
    func equalized() -> SplitNode                                  // every ratio = 0.5
    func moving(_ id: PaneID, to target: PaneID, _ edge: FocusDirection) -> SplitNode   // id re-split beside target on edge; self if same/missing
}
struct Tab: Codable, Identifiable, Equatable, Sendable { var id: UUID; var title: String; var root: SplitNode; var focused: PaneID?; var customTitle: String? = nil /* user rename; wins over the terminal title */ }
struct Project: Codable, Identifiable, Equatable, Sendable { var id: UUID; var path: String; var name: String; var tabs: [Tab]; var activeTab: Int; var scratch: Bool? = nil /* ⇧⌘N scratch terminal in ~ (reused: each press adds a tab): never listed as a project; the toolbar's terminal button (beside Add Project, badged with the scratch tab count) goes to it, or adds a tab when it is already shown; dropped when its last tab closes and at load */; var hidden: Bool? = nil /* off the Active list, listed under Hidden; terminals and agents keep running; nil/absent = active */; var workspace: UUID? = nil /* its workspace; nil only for scratch */; var dashboard: String? = nil /* http(s) page for the toolbar's chart button (WorkspaceController.toggleDashboard: opens it as a .web pane right of the focused pane, or closes the tab's one), hidden when nil; set by the project menu's Dashboard… (empty removes) */; var dashboardCommand: String? = nil /* optional server behind it, asked right after the URL; run by Services (no pane, no tab) while the dashboard is open */ }
struct Workspace: Codable, Identifiable, Equatable, Sendable { var id: UUID; var name: String; var image: String? = nil /* file in Store.workspaceImages (128 px PNG, center-cropped by workspaceIconPNG; new name per image) */; var emoji: String? = nil; var color: Int? = nil /* rail palette index; nil = derived from id */; var lastProject: UUID? = nil /* reselected on switching back */ }   // icon = image, else emoji on a tint, else monogram(name)
func normalizeWorkspaces(_ l: inout Layout)   // at load: ≥1 workspace (old layouts get "Personal" holding everything), strays join the first, activeWorkspace follows the active project
struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]; var activeProject: Int /* -1 = none (the last active project was hidden) */; var sidebarVisible: Bool; var theme: String
    var showHidden: Bool? = nil   // sidebar shows the Hidden list instead of Active (view state; nil = Active)
    var workspaces: [Workspace]? = nil; var activeWorkspace: UUID? = nil   // never empty / always valid after load
    static let `default`: Layout
}
@MainActor final class Store {
    static let directory: URL            // ~/Library/Application Support/Workbench (created on first use)
    static let workspaceImages: URL      // directory/workspaces
    var layout: Layout                   // mutate, then call changed()
    init()                               // loads directory/layout.json; missing → .default. Unreadable → moved to layout.json.bad-<time> (never over an earlier one), layout.last-good.json (copied after each good load) is used if it decodes, else .default, and layoutProblem is set: AppDelegate then skips Session.endOrphans (an unreadable layout is not "no panes") and says where the bad file is. Saves fsync before the rename
    func changed()                       // debounced 500 ms save on a private serial queue, atomic write
    func flush()                         // synchronous save; cancels pending debounce
}

// Runtime.swift
enum PaneEvent: Sendable {
    case title(String), pwd(String), bell, notification(title: String, body: String)
    case commandFinished(exitCode: Int, durationNs: UInt64)
    case openURL(String), closeRequested(processAlive: Bool)
    case startSearch(String), endSearch, searchTotal(Int), searchSelected(Int)
}
@MainActor protocol RuntimeDelegate: AnyObject {
    func surfaceView(for id: PaneID) -> SurfaceView?
    func runtime(_ runtime: Runtime, pane: PaneID, event: PaneEvent)
}
@MainActor final class Runtime {
    let app: ghostty_app_t
    weak var delegate: RuntimeDelegate?
    init(overrides: String)              // default files + recursive files, then ghostty_config_load_string(overrides), finalize, ghostty_app_new
    func reload(overrides: String)       // build new config the same way, ghostty_app_update_config, free old config
    func setFocus(_ focused: Bool)       // ghostty_app_set_focus
}

// Session.swift — surviving sessions. Ghostty runs in manual IO mode (io_mode MANUAL: spawns nothing; output in via ghostty_surface_process_output, keys/replies out via io_write_cb). Each terminal pane's shell is owned by a `wbhost` process (Sources/wbhost/main.c, protocol in its header; bundled as Contents/Helpers/WorkbenchHost) listening on Store.directory/s/<PANE-UUID>, spawned with posix_spawn (setsid, no inherited fds) via Session.shell (the env/argv Ghostty's exec backend built: TERM/TERMINFO, zsh shell integration, login wrapper). SurfaceView init: Session.attach(id) else Session.spawn; the host replays recent output on attach (writes during the replay are dropped: they are Ghostty's replies to old queries; for 2 s after a reattach WorkspaceController.setStatus keeps only busy from status events, so a replayed turn never comes back as done). Socket EOF = shell ended → closeRequested(processAlive: false), unless the host's socket file is still there (Session.wasKilled: every normal host exit unlinks it, so the host was killed, e.g. a broad pkill or a force-quit of an app launched from the pane, which takes the pane's coalition) → sessionLost: WorkspaceController.restartLost starts a new session in the same pane rerunning its saved command; killed again within 30 s, the pane stays with a note. A pane's saved command killed or crashed while its shell lives (exit 137/134/138/139: an endpoint-security kill, a broad pkill) comes back the same way: rerunKilled resets the modes an agent TUI left on (agentModesReset: mouse reporting, kitty keys, alt screen) and types it again (killedCommandRerun; an agent resume gets an interruption note as its prompt); again within 30 s → a note instead. Quit ends sessions (close → kill); a crash leaves them running and the next launch reattaches; "Restart Workbench" (app menu) sets Session.keepOnClose so closing detaches, then relaunches. At launch Session.endOrphans(keeping:) kills hosts whose pane is no longer in the layout (skipped when the layout failed to load). Input goes to the host in frames of at most 64 KiB (Session.maxInput); the host always reads its client, queueing up to 64 MiB of input the shell has not read, so 'k', resizes and EOF are never stuck behind a paste. The fd is closed only on the write queue by kill()/detach(), after stopReading().
// SurfaceView.swift
final class SurfaceBox: Sendable { let id: PaneID; let session: Mutex<Session?>; init(id: PaneID) }   // C userdata (passUnretained); owned by SurfaceView
@MainActor final class SurfaceView: NSView, NSTextInputClient {
    let paneID: PaneID
    let box: SurfaceBox
    private(set) var surface: ghostty_surface_t?
    var onFocus: ((PaneID) -> Void)?                     // called from becomeFirstResponder
    // drops: file URLs (Finder) paste their Runtime.shellEscape'd paths, space-separated, plus a trailing space
    var onKey: ((PaneID) -> Void)?                       // every keyDown: a key into a pane whose agent still has its OSC 9;4 progress up (Claude waiting on a question/plan approval) puts it back to busy; Claude 2.1.30x no longer animates its title, so progress + hooks are the busy signals
    var contextMenu: ((PaneID) -> NSMenu?)?              // right-click menu: the "Move to Tab" targets (other tabs, New Tab); set by WorkspaceController. Over a link the view adds Copy Link on top: link(at:) hovers with ⌘ mods so Ghostty resolves it (OSC 8 URI or regex URL) and reports it via MOUSE_OVER_LINK, synchronously on main, into hoveredLink; endLinkHover restores the real mods. ⌘-click paths: WorkspaceController.clickedPath — agents hard-wrap long paths, so Ghostty matches one row's part, or nothing (onPathClick fires on a ⌘-mouseUp with no hovered link); wordAtMouse (quicklook_word + the exact rows around it) is rejoined over the line breaks and the longest join that exists opens, ahead of Ghostty's own match (which can be the folder before a break after /)
    static var isReservedShortcut: (NSEvent) -> Bool = { _ in false }   // set by AppDelegate; performs the matching Pane menu action and returns true, else false
    init(app: ghostty_app_t, id: PaneID, cwd: String, initialInput: String?, env: [String: String], scrollbackLimit: Int?, initialSize: CGSize? = nil, startShell: Bool = true)   // initialSize (points) = the size a new, unattached shell starts at (set_size before Session.spawn, then Session.resize with whole-cell pixels), not libghostty's 800x600; WorkspaceController.paneSize computes it from SplitNode.paneSizes. startShell false = no session, for surfaceSelfCheck. After init the pty follows every set_size 30 ms later (syncPty, coalesced) with whole-cell pixels, since libghostty applies a size to its terminal up to 25 ms after set_size
    @discardableResult func setVisible(_ visible: Bool) -> Bool   // hide: occlusion(false), realized(false); show: realized(true), occlusion(true), refresh. Realize state is kept only when libghostty accepts it, so a refused one retries on the next call. True = just shown (already refreshed).
    func syncFocus()                     // libghostty focus = first responder && key window (a focused surface runs blink + termios-poll timers); WorkspaceController calls it on window key changes
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e)
    func setCursorVisibility(_ visible: Bool)
    @discardableResult func perform(_ action: String) -> Bool   // ghostty_surface_binding_action
    var needsConfirmQuit: Bool
    func close()                         // idempotent: session.stopReading then kill() (ends the shell; detach() while Session.keepOnClose, i.e. Restart), then ghostty_surface_request_process_termination on main (out of app routing), then ghostty_surface_free on a utility queue; the view stays retained by that closure until free returns
}

// SurfaceView.swift geometry (pure, in surfaceSelfCheck): PaneGeometry.pixels(_:scale:) points → backing px; PaneGeometry.ptySize(columns:rows:cellWidth:cellHeight:) the pty's winsize in whole cells (the kernel signals the pane on any winsize change, so never raw surface pixels); PaneGeometry.headerHeight (36, keep equal to PaneHeader.height); SplitNode.paneSizes(in:header:) -> [PaneID: CGSize] each pane's content size in a SplitTreeView of that size (ratio positions the divider, 1 pt; every pane has a header strip, a lone one too: it holds the Read Aloud controls)
// Input.swift — ports of Ghostty helpers
extension NSEvent { func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s; var ghosttyCharacters: String? }
enum GhosttyInput {
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags
}

// Theme.swift
struct Theme: Decodable, Sendable { let id: String; let name: String; let type: String; let ui: [String: String]; let terminal: [String: String] }
extension Theme {
    @MainActor static func all() -> [Theme]              // cached until reload(): system-dark/system-light ("Dark"/"Light", built in code: Terminal.app "Basic" colors, accents from system colors resolved under their fixed appearance), then Bundle.main.resourceURL/themes/*.json (bundled, read-only), then Store.directory/themes/*.json (user) overriding by id; sorted by name
    @MainActor static func reload()                      // rescan; Theme.userFiles[id] = file of the editable (user) themes
    @MainActor static func named(_ id: String) -> Theme  // falls back to "oceanic-v2", then first
    var isSystem: Bool; var appearance: NSAppearance?    // system-* ids; window appearance from `type` ("light" → .aqua, else .darkAqua), applied in paintTheme
    static let requiredUI: [String]; static let requiredTerminal: [String]   // every key the app reads; a custom theme must provide all
    func template(id:name:) -> String                    // complete theme JSON seeded with this theme's colors
    static func validate(_ text: String) -> Result<Theme, Invalid>   // JSON parses, id filename-safe (not system-*), name, type dark|light, required keys, every color parses; Invalid.message is user-facing
    @MainActor static func save(_ t: Theme, text: String) throws -> URL   // atomic write to Store.directory/themes/<id>.json
    func color(_ key: String) -> NSColor                  // ui[key] (hex #RRGGBB or rgba(r, g, b, a)); magenta if missing
    func terminalColor(_ key: String) -> NSColor          // terminal[key] (ANSI palette); ui foreground if missing
    var ghosttyConfig: String                             // newline-separated ghostty config lines for terminal colors + split-divider-color
}

// Notification.Name.themeChanged — posted by WorkspaceController.applyTheme (and so after any list change); the Theme menu (AppDelegate.rebuildThemeMenu: Dark, Light, separator, custom, current checked) and Settings refresh on it.

// Settings "Read Aloud" pane (ReadAloudViewController): Tone slider (0.87–1.13, live; applyReadAloudTone), Pace (= readAloudSpeed), Preview (WorkspaceController.previewReadAloud). Siri's Expressivity/Pace sliders (System Settings) have no API and do not reach AVSpeechSynthesizer output (measured).
// SettingsWindow.swift — ⌘, ("Settings…" in the app menu): SettingsWindowController, a window with an NSTabViewController (.toolbar tab style; add panes as NSTabViewItems). "Themes" pane: Dark/Light cards (NSButton), Custom Themes list (radio per theme; user ones get Edit…/Delete with confirmation), "Add Custom Theme…". Add/Edit is a sheet with a monospace JSON editor prefilled by Theme.template (or the file); Save runs Theme.validate, shows the error inline, else Theme.save → Theme.reload → applyTheme. Selecting applies live via WorkspaceController.applyTheme.
// Backup.swift — Backup (version, machine, layout minus scratch projects, user themes by file name, workspace images as base64, Ghostty config). current()/encoded() throw instead of dropping files; Backup.maxSize (64 MB) caps every read/write; decode rejects newer versions and unsafe/over-255-byte file names. forSync strips selection/focus/titles/export time and agent launches (resume ids churn every turn) so unchanged setups make no commit. BackupSync: per-Mac file workbench-<thisMachine>.json; 10 min throttle (first change arms it, later ones ride along) on Store.onChange and app activation; run = write, add, commit only that path if changed, fetch, rebase @{u}, push only if ahead; stop() bumps a generation so queued work no-ops; a cycle with nothing to commit or push makes no network call; quit runs startFlush before ending sessions and finishFlush (≤5 s) after, so git overlaps their exit; every git call has a watchdog timeout (90 s, clone 300 s) and uses the user's own ssh setup; fetchBackups = fetch + rebase + decode every workbench-*.json (this Mac first). backupSelfCheck.
// Settings "Backup" pane (BackupViewController): Export…/Import…/Copy JSON/Paste JSON, or drop a .json. Snapshots call workspace.captureAgents() first. Import: Backup.decode → each missingProjects gets Locate… (relocate rewrites the path and tabs' cwds/file paths under it) / Remove Project / Cancel Import → confirm (warns if agents are mid-turn) → Backup.saveCurrent (Store.directory/backups/, the rollback) → AppDelegate.restore(_:rollback:): quit, Backup.install, on failure reinstall the rollback and write restore-error.txt (alert at next launch), relaunch via `open -n`. Git Sync: Connect… takes a remote URL (Layout.backupRemote, machine-local); BackupSync clones it to Store.directory/sync and owns that clone.

// Agents.swift — agent processes found by inherited PANE_ID; launcher (cc1/cc2/gpt1…) recovered from the user's zsh functions
enum Agents {
    static let claudeHookArgs: String; static let codexHookArgs: String
    static func discoverLaunchers()                       // once at launch, background; the zsh capture ends at the child's exit or a 10 s timeout, never waits for EOF
    static func running() -> [PaneID: String?]           // pane → resume command; nil = agent running but id unknown yet (keep the saved command), e.g. "cc2 --resume <id>", "gpt1 resume <thread id>" (id from argv, else a distinct recent CLI thread of its folder from CODEX_HOME/state_*.sqlite); folded into the layout by recordAgents (WorkspaceController.swift): a pane absent from a scan drops its launch only if an agent was seen there before, since a scan is a snapshot and a resumed agent may not have started yet
    static func transcript(for pane: PaneID) -> URL?    // the pane agent's session jsonl: Claude <config dir>/projects/*/<sessionId>.jsonl (globbed by name), Codex <CODEX_HOME>/sessions/Y/M/D/rollout-*-<threadId>.jsonl (newest dirs first); nil = no agent / not found. Scans processes + disk: off main
    static func backgroundWork(for panes: Set<PaneID>) -> Set<PaneID>   // panes still working; one process scan and at most one 1 s CPU sample per batch. A Claude pane still has work after its turn ended: subagents (<session>/subagents/agent-*.meta.json without "finished", log touched in the last 15 min) or background shells/Monitors (agent children `zsh -c source …/shell-snapshots/…`), except a shell tree listening on TCP and under 2% CPU over 1 s (a dev server). WorkspaceController holds a busy→done turn end as busy while true, rechecking every 5 s. Off main, may block 1 s
}

// SplitTreeView.swift
enum FocusDirection: Sendable { case left, right, up, down }
@MainActor final class SplitTreeView: NSView {
    var onRatiosChanged: ((SplitNode) -> Void)?           // user dragged a divider; tree with updated ratios
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header (on every pane) onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    func updateHeaders(focused: PaneID?, theme: Theme, status: (PaneID) -> PaneStatus, title: (PaneID) -> String)   // called from updateChrome; each header is a strip (theme background) above the pane with a glass capsule pill (status dot + title)
    init(provider: @escaping (PaneSpec) -> NSView)        // returns the existing leaf view for a pane (never creates duplicates)
    @discardableResult func render(_ root: SplitNode, dividerColor: NSColor) -> Bool   // false = nothing rebuilt: same structure (axes, leaf ids) and the provider returns the same view for every leaf, so a cwd, launch or file-path change (or only ratios, applied in place) keeps every pane where it is
    func clear()                                          // drop the tree and every view it retains
    func neighbor(of id: PaneID, _ direction: FocusDirection) -> PaneID?
}

// FilePaneView.swift — .md previewed, other files as monospace code highlighted via Syntax; reloads on file change. Read-only (selectable, links clickable). A regular `.file` pane in the split tree, focusable like a terminal (acceptsFirstResponder forwards to its text view; onFocus → paneFocused), so ⌘W closes it. WorkspaceController.openFile (⌘-click a path, `pane open`, Open File…) retargets the tab's existing file pane in place (kind swapped, FilePaneView.retarget: same view, zoom kept, scroll to top, watchers moved) or splits one in right of the focused pane: one preview pane per tab. A file change during a render marks the pane dirty and reloads once that render lands (never supersedes it); otherwise one reload per 100 ms. Renders run on one shared serial queue; replacing the text empties the storage first in one editing transaction (re-setting over many attribute runs is quadratic)
// Zoom: each preview has its own ZoomBar (glass capsule top-right: −, percentage = reset, +); ⌘=/⌘-/⌘0 (Bigger/Smaller/Actual Size) zoom a focused preview instead of the terminal font. 50–300 % in 10 % steps, applied by scaling the rendered fonts and indents (text rewraps); WorkspaceController.fileZoom keeps it per pane across retargets (in memory, not saved)
@MainActor final class FilePaneView: NSView { let paneID: PaneID; init(id: PaneID, path: String, theme: Theme, zoom: CGFloat = 1); private(set) var zoom: CGFloat; var onZoom: ((CGFloat) -> Void)?; func setZoom(_ z: CGFloat); func retarget(path: String); func apply(theme: Theme); func close() }

// Syntax.swift — tree-sitter grammars (SwiftPM packages; queries read from their resource bundles in Contents/Resources)
enum Syntax {
    static func key(for path: String) -> String?          // grammar key by extension (or file name, e.g. dockerfile); nil = unknown
    static func key(fence: String) -> String?             // markdown code fence info string → grammar key
    static func highlights(_ text: String, key: String) -> [(range: NSRange, name: String)]?   // thread-safe; UTF-16 ranges, less specific first
}

// Model.swift sidebar helpers: visibleProjectIndices(_:hidden:workspace:) is the active workspace's list and excludes scratch (so ⌘1–9, next/previous project, reorder and the Hidden count only see real projects); scratchProjectIndices(_:) -> [Int]. The sidebar table is one row per project (table row == visible project index).
// Workspace navigation (Go menu, reserved shortcuts): ⌃1–9 selectWorkspaceByTag (no-op past the count), ⌃⌘↑/↓ previous/next workspace, wrapping (WorkspaceController.cycleWorkspace).
// Focus: render(focus:) moves keyboard focus to the focused pane; renders from events (a shell exiting, restartLost, control split/open) pass focus only when the keyboard was already in the panes (keyboardInPanes) or in the closing pane's find bar, so they never pull it out of the find bar.
// Back/Forward (mouse buttons 4/5, ⌃⌘←/→): history of {workspace, project, tab} recorded at the end of render(), max 100, entries for closed projects/tabs resolve to what still exists or are skipped.

// SidebarView.swift
struct SidebarRow: Equatable, Sendable { let id: UUID; let name: String; let path: String; let status: PaneStatus; var tabCount = 0 }   // status = busiest pane of the project; tabCount = its tabs (shown right of the row, omitted when 0; a project with none is dimmed unless selected)
enum PaneStatus: Int, Comparable, Sendable { case idle = 0, busy = 1, done = 2, attention = 3 }   // Comparable by rawValue
@MainActor final class SidebarView: NSView {   // the WorkspaceRail at the leading edge; right of it the workspace's name as a large bold title, the Active/Hidden GlassSegments under it, then a native .sourceList table. Two lines per project (ProjectRowCell, 46 pt): status dot (grey idle, hollow ring with nothing open), name, then "Needs you / Working… / Done / N tabs / Nothing open". Selection = the active project, drawn by SelectionRowView (label color at 15%, the app-wide selection fill shared with the tab bar, switches and pane headers; its bar spans the same width as the Active/Hidden switch; native highlight off). update() restyles cells in place and reloads only when the row ids change. Projects reorder by press-and-drag on a row (SidebarTable.onPress → Reorder(vertical: true); a press released before the 4 pt threshold selects the row): the row lifts and follows the pointer, the others slide aside.
    var onSelect: ((Int) -> Void)?; var onRemove: ((Int) -> Void)?         // project indices are rows of the list shown; WorkspaceController maps rows to projects (visibleProjectIndices / reorderedProjects in Model.swift)
    var onShowHidden: ((Bool) -> Void)?                  // Active/Hidden segmented control above the list
    var onToggleHidden: ((Int) -> Void)?                 // context menu Hide Project (Active view) / Show Project (Hidden view); the menu also has Copy Path, Reveal in Finder and Open in VS Code (omitted when not installed) (handled in the view)
    var onRename: ((Int, String?) -> Void)?              // double-click a project row (or context menu Rename); nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a project: from, to (final index after removal)
    var onMoveToWorkspace: ((Int, Int) -> Void)?         // project context menu "Move to Workspace" (2+ workspaces): row, workspace index
    let rail: WorkspaceRail
    func updateWorkspaces(_ items: [WorkspaceItem], selected: Int, theme: Theme)   // rail + title
    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme)   // selected -1 = none; skipped while a name is being edited (the rename's end re-renders)
}   // Add Project and Scratch Terminal (apple.terminal) are toolbar items (WorkspaceController), not sidebar buttons

// GlassSegments.swift — `GlassSegments(labels:)`: the tab bar's toggle look as a standalone view (glass capsule + sliding selection pill in the theme foreground at 15% (`tint`, set by the owner), same 0.28 s curve, Reduce Motion snaps); `onSelect: ((Int) -> Void)?`, `setLabel(_:at:)`, `select(_:animated:)`. Used by the sidebar's Active/Hidden switch. Scratch rows are soft rounded bars (5% label fill, 9% hover, 15% when selected; no glass).

// WorkspaceRail.swift — 60 pt rail, darker strip starting below the toolbar (black 16%) with a 1 px trailing divider, Slack-style: one 40 pt icon per workspace (gradient tile + rounded-bold monogram, or emoji on a soft tint, or image), status badge = busiest pane inside, selected marked by a bar at the rail's edge; glass + New Workspace below. Right-click: Rename…, Choose Emoji… (sheet with a field + character palette; first character kept), Choose Image… (NSOpenPanel), Color ▸ (6 named swatches, checkmark on the current; tints the monogram tile and emoji, not images), Use Monogram, Delete Workspace… (2+; projects move to the neighbour, nothing closed)
struct WorkspaceItem: Equatable, Sendable { let id: UUID; let name: String; let image: String? /* absolute path */; let emoji: String?; let color: Int?; let status: PaneStatus }
func monogram(_ name: String) -> String   // KWI → KWI, side-projects → SP, Personal → P
func workspaceIconPNG(_ url: URL, px: Int = 128) -> Data?
@MainActor final class WorkspaceRail: NSView { var onSelect, onRename, onChooseEmoji, onChooseImage, onClearIcon, onDelete: ((Int) -> Void)?; var onChooseColor: ((Int /* workspace */, Int /* palette */) -> Void)?; var onNew: (() -> Void)?; static let width: CGFloat; func update(_ items: [WorkspaceItem], selected: Int, theme: Theme) }

// TabBarView.swift
struct TabItem: Equatable, Sendable { let id: UUID; let title: String; let status: PaneStatus }   // id: an inline rename ends (cancelled) when its position no longer holds the same tab, so it never renames another
@MainActor final class TabBarView: NSView {   // a toolbar item view: fixed 34 pt height, width hugs the tabs (full titles, no per-tab cap) up to `maxWidth`, which WorkspaceController.fitTabBar sets from the toolbar slot to the end of the terminals column (less the project title) on every mainPane resize; the width is a required constraint plus the intrinsic size, since the toolbar sizes view items to their minimum and re-measures only on intrinsic invalidation; overflowing tabs scroll sideways in a TabScrollView (the mouse wheel scrolls it too) and the selected tab is scrolled into view on selection and resize; system colors; selection pill is the theme foreground at 15% (a solid fill, not glass: it must read the same in active, inactive and fullscreen-reveal toolbars) and slides (reduce-motion respected)
    var onSelect: ((Int) -> Void)?; var onClose: ((Int) -> Void)?; var onNew: (() -> Void)?
    var onRename: ((Int, String?) -> Void)?              // double-click a tab; nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a tab: from, to (lifted tab follows the cursor, others slide aside, snaps on release; then the model follows)
    func update(items: [TabItem], selected: Int, theme: Theme)
}

// Reorder.swift — the one drag gesture: trackDrag(from:in:_:) (4 pt threshold, closed hand; tabs, pane headers, sidebar rows),
// and Reorder().drag(views, from, by: offset, done:, commit:) for pick-up, drag and snap in a row of views (x axis; `Reorder(vertical: true)` for the sidebar's rows, y axis in the flipped table, +offset = down).

// InlineRename (TabBarView.swift): makes a label editable in place; Return/click away commits, Esc cancels. static var isEditing (render() skips refocusing the terminal while true)

// FindBar.swift
@MainActor final class FindBar: NSView {   // glass capsule, NSSearchField, glass chevron/xmark buttons; fades+scales when isHidden toggles; apply(theme:) is a no-op (system colors)
    var onChange: ((String) -> Void)?; var onNext: (() -> Void)?; var onPrevious: (() -> Void)?; var onClose: (() -> Void)?
    var text: String
    func show(needle: String); func setCounts(total: Int, selected: Int); func apply(theme: Theme)
}
// Find (WorkspaceController): ⌘F → find(). Agent pane (Agents.transcript resolved, off main) → agent mode: Claude fullscreen and Codex draw history on the alternate screen and scroll it themselves, so there is no scrollback. Typing (debounced 150 ms) counts matches in the transcript (none → no scrolling, bar shows 0); otherwise seek() writes PageUp/PageDown (`text:\x1b[5~`/`[6~`) and reads SurfaceView.viewportText() every 60 ms until the whitespace-stripped, case-folded query is on screen (after a page only the lines it brought in count), then `search:<text>` highlights it. Return/⌘G = older, ⇧Return/⇧⌘G = newer. Past the last match it pages back to it (restore); for a new query it pages back about as far as it went. 400-page cap. Any other pane, or no transcript → libghostty search (start_search / search:<text> / navigate_search / end_search).

// Transcript.swift — session jsonl → searchable entries; the terminal of a fullscreen-TUI agent only holds the visible screen
struct TranscriptEntry: Sendable, Equatable { enum Kind { case user, assistant, toolCall, toolOutput }; let kind: Kind; let text: String; let time: Date? }
struct TranscriptMatch: Sendable, Equatable { let entry: Int; let range: NSRange }   // one per occurrence; UTF-16 range in the entry's text
enum TranscriptParser {
    static func entries(_ line: Data, codex: Bool) -> [TranscriptEntry]   // one jsonl line; Claude: user/assistant text, tool_use "<name> <compact json>", tool_result; Codex: response_item message/function_call/custom_tool_call (+ outputs); everything else, isMeta and injected context skipped
    static func matches(in entries: [TranscriptEntry], _ query: String) -> [TranscriptMatch]   // case- and diacritic-insensitive substring
    static func count(in entries: [TranscriptEntry], _ query: String) -> Int   // the same matching, without building them (Find only shows a count)
}
final class TranscriptIndex: @unchecked Sendable { init(_ url: URL); var entries: [TranscriptEntry]; func update(chunk: Int = 8 << 20, stop: () -> Bool = { false }) }   // reads only appended complete lines since the last call, 8 MB chunks each in an autorelease pool; stop is checked between chunks and leaves a valid partial index the next call resumes; confined to TranscriptSearch's queue
enum TranscriptSearch {   // background queue; one parsed file kept (current); a newer call supersedes older ones: their parse stops at the next chunk, stale results dropped
    static func locate(_ pane: PaneID, done: @escaping @Sendable @MainActor (URL?) -> Void)   // takes the index before done, then parses it (prewarm), so typing finds it ready
    static func search(_ url: URL, _ query: String, done: @escaping @Sendable @MainActor (Int) -> Void)   // match count
    static func cancel()
    static func release(after delay: TimeInterval = keepAfterClose)   // Find closed: stop any parse, drop the index after 60 s unless Find is used again
}
// SpeechText.swift — Read Aloud's words (pure): what the focused agent pane says aloud
enum SpeechText {
    static func tail(_ url: URL, bytes: Int = 4 << 20) -> [TranscriptEntry]   // entries in the last `bytes` of a transcript (partial first line dropped): only the latest turn matters
    static func latest(_ url: URL) -> String?   // utterance of the last 256 KB, else of the last 4 MB
    static func utterance(_ entries: [TranscriptEntry]) -> String?   // a pending AskUserQuestion ("Claude is asking: … Option one, …", after the turn's text before it) or ExitPlanMode ("Claude has a plan ready. …"; pending = no tool output or user entry after it), else the last assistant text; cleaned; nil = nothing to read
    static func clean(_ markdown: String) -> String   // for the ear: code fences → "(code omitted)", table rows → "a, b", headings/bullets/quotes/emphasis/backticks stripped, links → their text, URLs → host, paths → last component, File.swift:42 → "File.swift, line 42"; every line ends as a sentence
    static func selection(_ text: String) -> String   // selected terminal text for the ear: TUI glyphs (⏺ ⎿, box drawing) dropped, hard-wrapped lines rejoined (blank line / list item / heading starts a new one), then clean
    static func chunks(_ text: String, limit: Int = 400) -> [String]   // whole sentences packed to ≤ limit characters (shorter chunks: faster first audio); an over-long sentence splits at spaces
}
// Speaker.swift — Read Aloud's voice: Siri Voice 6 only (com.apple.siri.natural.en-US-G, pinned in the helper; the en-US system voice if it is missing; other voices sounded robotic, so there is no voice choice) through AVSpeechSynthesizer.write in a JXA helper, Resources/speech/siri_helper.js, run by /usr/bin/osascript -l JavaScript: macOS lists Siri voices only to Apple-signed processes, so the same code compiled into Workbench (or any binary we sign) silently gets a fallback voice; osascript is on every Mac (no Xcode). PANE_SPEECH_HELPER = an executable to run instead, for tests. Started on the first press (prewarm: while the transcript is looked up; ~0.9 s to first audio cold, ~0.2 s warm, ~40 MB), exits after 5 min without a job or at stdin EOF (quit). stdin: JSON lines {"id":N,"text":chunk} / {"cancel":N} (stops the chunk mid-word), kept as bytes until a newline (a read can split UTF-8); stdout: frames of LE u32 id, LE u32 sample rate, LE u32 byte count, float32 mono PCM at the voice's native rate (Siri 48 kHz; a fallback voice may differ; never resampled: the engine's mixer converts), first buffer of a chunk at once, then ≥ 100 ms per frame; <id><0><0> ends one chunk. Speaker sends at most 2 chunks ahead and ≤ 30 s of queued audio; the text goes out before the engine starts; a helper exit is handled after its last stdout data: playback of everything received continues, a chunk still in synthesis fails (beep), an idle-out between chunks respawns. Its stderr ("voice: <id>" at start, errors) goes to Speaker.directory/helper.log. scripts/speech-helper-check.py runs the real helper (split UTF-8, rate header, batching, Voice 6 picked).
enum SpeechFrame { static func parse(_ buffer: inout Data) -> [(id: UInt32, rate: Double, samples: [Float])] }   // complete frames off the front in one pass; a partial one waits
@MainActor final class Speaker {
    enum State { case idle, loading /* until this job's first audio */, speaking }
    static let shared: Speaker; static var directory: URL /* Store.directory/speech: helper.log */
    private(set) var state: State; var onChange: ((State) -> Void)?; var onFailure: () -> Void /* beep: nothing to say, the helper failed to start or died mid-job */
    var rate: Float   // playback speed through an AVAudioUnitTimePitch (pitch kept), live mid-reply; Layout.readAloudSpeed (Edit > Read Aloud Speed, 1–2×, nil = 1×) sets it
    var pitch: Float     // "Tone": pitch multiplier applied by the same TimePitch unit (cents), live: Siri voices ignore pitchMultiplier and SSML pitch (measured); Layout.readAloudPitch
    func speak(_ chunks: [String])   // replaces whatever is playing; idle once every chunk's end frame arrived and every buffer played (the AVAudioEngine is stopped when idle, so it costs nothing)
    func stop()                      // idle now; cancels the job in the helper; its later frames are dropped (job ids)
    func prewarm()                   // start the helper now
}
// Read Aloud (WorkspaceController.readAloud: Edit menu ⌥⌘S reads the focused pane; each terminal pane header has a glass capsule right of its pill: speaker / ellipsis / stop for that pane, and the speed (click cycles 1–2×, shared)): the focused pane's transcript (Agents.transcript, off main) → SpeechText.tail → utterance → chunks → Speaker.shared; pressed while not idle, it stops. Every Stop goes through WorkspaceController.stopReading (bumps speechLookup, so a lookup in flight never speaks after it); text cleaning and chunking run off main. Right-click with text selected (terminal: SurfaceView.selectedText in paneMenu; file pane: its NSTextView menu, FilePaneView.onReadAloud) adds "Read Aloud Selection" → WorkspaceController.speakSelection → SpeechText.selection → chunks. Test harness (DEBUG control): speak path=<jsonl> (replies {"text":…}), speak-stop, speak-state (+ speed, pitch, playback cents), speak-tone pitch= (what Settings > Tone does), settings tab=<label> (opens Settings there; replies with its window number, for screencapture -l), header-click pane= button=speak|speed, select-all pane=, menu pane= item="Read Aloud Selection"; scripts/speech-e2e.sh drives them against the debug bundle with a stub helper.
// Services.swift — a project's dashboard server behind the scenes: Services.wanted(layout) = projects with a dashboardCommand whose dashboard .web pane is open in any tab; WorkspaceController.render() (and the Dashboard… sheet) calls services.sync(wanted), which starts or stops each. A server runs in a WorkbenchHost session keyed by the project id ("zsh -lc <command>" in the project folder, no view), so it has the pane shells' file access and survives a crash or Restart (attached at launch; AppDelegate keeps its id from Session.endOrphans); output to Store.directory/services/<project id>.log, emptied on a fresh start. Any end restarts it after 1 s, unless it ran under 10 s (stays down until the command changes or the dashboard reopens). terminateAll → closeAll: Quit kills, Restart detaches.
// Control.swift — unix socket at Store.directory/pane.sock, one JSON object per line ([String: String]), one reply line
final class ControlServer: @unchecked Sendable { init(path: String, handler: @escaping @MainActor ([String: String]) -> String); func start(); func stop() }
enum ControlClient { static func run(_ args: [String]) -> Int32 }   // argv after the program name
```
