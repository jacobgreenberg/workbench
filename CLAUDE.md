# Workbench

Native macOS terminal IDE for running many Claude Code / Codex sessions. Swift 6 + AppKit + GhosttyKit (libghostty, our fork `jacobgreenberg/ghostty` branch `workbench` (based on cmux `manaflow-ai/ghostty@cb1ef70`), built from source by `scripts/ghosttykit.sh` at its pinned SHA). Single SwiftPM executable target `Workbench`, all sources in `Sources/Workbench/`. Reference Ghostty sources (read-only) are in `vendor/ghostty-src/macos/Sources/Ghostty/`; the C API is `vendor/ghostty-src/include/ghostty.h`.

Build: `swift build -c release`, then `scripts/bundle.sh` → `build.noindex/Workbench.app`. Run: `open build.noindex/Workbench.app`.

Rules: AppKit only (no SwiftUI). macOS 27+. Chrome is Liquid Glass (NSGlassEffectView panels/capsules, `HandButton.glass` round buttons) floating over the solid theme background; never put glass over a terminal surface except transient overlays (find bar), since glass over changing content recomposites every frame. No polling timers. Every C callback is a nonisolated `@convention(c)` function that copies data into owned Swift values and hops to main with `DispatchQueue.main.async`. Never touch a SurfaceView's `wantsLayer`/`layer` before `ghostty_surface_new`. Import GhosttyKit as `@preconcurrency import GhosttyKit`.

## Contract (cross-file interfaces — keep exact)

```swift
// Model.swift
typealias PaneID = UUID
struct Launch: Codable, Equatable, Sendable {
    var command: String          // typed into the shell as initial input; rewritten at quit to the running agent's resume command
    var scrollbackLimit: Int?    // bytes; nil = global default
}
enum PaneKind: Codable, Equatable, Sendable { case terminal(cwd: String, launch: Launch?), file(path: String) }   // file: markdown preview or highlighted code; coded as "markdown" for old layouts
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
struct Project: Codable, Identifiable, Equatable, Sendable { var id: UUID; var path: String; var name: String; var tabs: [Tab]; var activeTab: Int; var scratch: Bool? = nil /* ⇧⌘N scratch terminal in ~ (reused: each press adds a tab): never listed as a project, shown in the sidebar's bottom area; dropped when its last tab closes and at load */; var hidden: Bool? = nil /* off the Active list, listed under Hidden; terminals and agents keep running; nil/absent = active */ }
struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]; var activeProject: Int /* -1 = none (the last active project was hidden) */; var sidebarVisible: Bool; var theme: String
    var showHidden: Bool? = nil   // sidebar shows the Hidden list instead of Active (view state; nil = Active)
    static let `default`: Layout
}
@MainActor final class Store {
    static let directory: URL            // ~/Library/Application Support/Workbench (created on first use)
    var layout: Layout                   // mutate, then call changed()
    init()                               // loads directory/layout.json, falls back to .default on missing/corrupt
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

// SurfaceView.swift
final class SurfaceBox: Sendable { let id: PaneID; init(id: PaneID) }   // C userdata (passUnretained); owned by SurfaceView
@MainActor final class SurfaceView: NSView, NSTextInputClient {
    let paneID: PaneID
    let box: SurfaceBox
    private(set) var surface: ghostty_surface_t?
    var onFocus: ((PaneID) -> Void)?                     // called from becomeFirstResponder
    var contextMenu: ((PaneID) -> NSMenu?)?              // right-click menu: the "Move to Tab" targets (other tabs, New Tab); set by WorkspaceController
    static var isReservedShortcut: (NSEvent) -> Bool = { _ in false }   // set by AppDelegate; performs the matching Pane menu action and returns true, else false
    init(app: ghostty_app_t, id: PaneID, cwd: String, initialInput: String?, env: [String: String], scrollbackLimit: Int?)
    @discardableResult func setVisible(_ visible: Bool) -> Bool   // hide: occlusion(false), realized(false); show: realized(true), occlusion(true), refresh. Realize state is kept only when libghostty accepts it, so a refused one retries on the next call. True = just shown (already refreshed).
    func syncFocus()                     // libghostty focus = first responder && key window (a focused surface runs blink + termios-poll timers); WorkspaceController calls it on window key changes
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e)
    func setCursorVisibility(_ visible: Bool)
    @discardableResult func perform(_ action: String) -> Bool   // ghostty_surface_binding_action
    var needsConfirmQuit: Bool
    func close()                         // idempotent: request_process_termination, then ghostty_surface_free on a utility queue; the view stays retained by that closure until free returns
}

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

// SettingsWindow.swift — ⌘, ("Settings…" in the app menu): SettingsWindowController, a window with an NSTabViewController (.toolbar tab style; add panes as NSTabViewItems). "Themes" pane: Dark/Light cards (NSButton), Custom Themes list (radio per theme; user ones get Edit…/Delete with confirmation), "Add Custom Theme…". Add/Edit is a sheet with a monospace JSON editor prefilled by Theme.template (or the file); Save runs Theme.validate, shows the error inline, else Theme.save → Theme.reload → applyTheme. Selecting applies live via WorkspaceController.applyTheme.

// Agents.swift — agent processes found by inherited PANE_ID; launcher (cc1/cc2/gpt1…) recovered from the user's zsh functions
enum Agents {
    static let claudeHookArgs: String; static let codexHookArgs: String
    static func discoverLaunchers()                       // once at launch, background
    static func running() -> [PaneID: String?]           // pane → resume command; nil = agent running but id unknown yet (keep the saved command), e.g. "cc2 --resume <id>", "gpt1 resume <thread id>" (id from argv, else a distinct recent CLI thread of its folder from CODEX_HOME/state_*.sqlite)
    static func transcript(for pane: PaneID) -> URL?    // the pane agent's session jsonl: Claude <config dir>/projects/*/<sessionId>.jsonl (globbed by name), Codex <CODEX_HOME>/sessions/Y/M/D/rollout-*-<threadId>.jsonl (newest dirs first); nil = no agent / not found. Scans processes + disk: off main
}

// SplitTreeView.swift
enum FocusDirection: Sendable { case left, right, up, down }
@MainActor final class SplitTreeView: NSView {
    var onRatiosChanged: ((SplitNode) -> Void)?           // user dragged a divider; tree with updated ratios
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header (shown when the tab has 2+ panes) onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    func updateHeaders(focused: PaneID?, theme: Theme, status: (PaneID) -> PaneStatus, title: (PaneID) -> String)   // called from updateChrome; each header is a strip (theme background) above the pane with a glass capsule pill (status dot + title)
    init(provider: @escaping (PaneSpec) -> NSView)        // returns the existing leaf view for a pane (never creates duplicates)
    @discardableResult func render(_ root: SplitNode, dividerColor: NSColor) -> Bool   // false = unchanged, nothing rebuilt
    func clear()                                          // drop the tree and every view it retains
    func neighbor(of id: PaneID, _ direction: FocusDirection) -> PaneID?
}

// FilePaneView.swift — .md previewed, other files as monospace code highlighted via Syntax; reloads on file change. Shown in the right preview sidebar (⌘-click a path, `pane open`, Open File…; ⌥⌘B toggles), or as a .file pane from old layouts
@MainActor final class FilePaneView: NSView { let paneID: PaneID; init(id: PaneID, path: String, theme: Theme); func apply(theme: Theme); func close() }

// Syntax.swift — tree-sitter grammars (SwiftPM packages; queries read from their resource bundles in Contents/Resources)
enum Syntax {
    static func key(for path: String) -> String?          // grammar key by extension (or file name, e.g. dockerfile); nil = unknown
    static func key(fence: String) -> String?             // markdown code fence info string → grammar key
    static func highlights(_ text: String, key: String) -> [(range: NSRange, name: String)]?   // thread-safe; UTF-16 ranges, less specific first
}

// Model.swift sidebar helpers: visibleProjectIndices(_:hidden:) excludes scratch (so ⌘1–9, next/previous project, reorder and the Hidden count only see real projects); scratchProjectIndices(_:) -> [Int]. The sidebar table is one row per project (table row == visible project index).

// SidebarView.swift
struct SidebarRow: Equatable, Sendable { let id: UUID; let name: String; let path: String; let status: PaneStatus; var tabCount = 0 }   // status = busiest pane of the project; tabCount = its tabs (shown right of the row, omitted when 0; a project with none is dimmed unless selected)
enum PaneStatus: Int, Comparable, Sendable { case idle = 0, busy = 1, done = 2, attention = 3 }   // Comparable by rawValue
@MainActor final class SidebarView: NSView {   // a large bold "Projects" title, the Active/Hidden GlassSegments under it, then a native .sourceList table. One 34 pt line per project (ProjectCell): name (13 pt, semibold when selected), then on the right the status dot (max of its panes, hidden when idle) and the tab count; no chevrons or tab rows. Selection = the active project (the single glass capsule). update() restyles cells in place and reloads only when the row ids change. Native drag-and-drop reorders projects. Pinned below the list: separator, scratch terminal rows (own small source-list table, same ProjectCell/row view, named "Scratch Terminal [n]", cwd as tooltip), a content-hugging "Scratch Terminal" glass button at the leading edge
    var onSelect: ((Int) -> Void)?; var onRemove: ((Int) -> Void)?         // project indices are rows of the list shown; WorkspaceController maps rows to projects (visibleProjectIndices / reorderedProjects in Model.swift)
    var onShowHidden: ((Bool) -> Void)?                  // Active/Hidden segmented control above the list
    var onToggleHidden: ((Int) -> Void)?                 // context menu Hide Project (Active view) / Show Project (Hidden view)
    var onRename: ((Int, String?) -> Void)?              // double-click a project row (or context menu Rename); nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a project: from, to (final index after removal)
    var onSelectScratch: ((Int) -> Void)?; var onCloseScratch: ((Int) -> Void)?   // indices are rows of the scratch list; right-click Close
    var onNewScratch: (() -> Void)?                      // the Scratch Terminal button (same as ⇧⌘N)
    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme)   // selected -1 = none; skipped while a name is being edited (the rename's end re-renders)
    func updateScratch(rows: [SidebarRow], selected: Int, theme: Theme)   // scratch terminals; selected -1 = none (a project is active)
}   // Add Project is a toolbar item (WorkspaceController), not a sidebar button

// GlassSegments.swift — `GlassSegments(labels:)`: the tab bar's toggle look as a standalone view (glass capsule + sliding tertiary-fill selection pill, same 0.28 s curve, Reduce Motion snaps); `onSelect: ((Int) -> Void)?`, `setLabel(_:at:)`, `select(_:animated:)`. Used by the sidebar's Active/Hidden switch. Sidebar rows are GlassRowView (selection = NSGlassEffectView capsule inset 6 pt, hover fill; no flat source-list fill).

// TabBarView.swift
struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }
@MainActor final class TabBarView: NSView {   // a toolbar item view: fixed 34 pt height, intrinsic width hugs the tabs (cap 760, tabs then shrink); system colors; selection pill slides (reduce-motion respected)
    var onSelect: ((Int) -> Void)?; var onClose: ((Int) -> Void)?; var onNew: (() -> Void)?
    var onRename: ((Int, String?) -> Void)?              // double-click a tab; nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a tab: from, to (lifted tab follows the cursor, others slide aside, snaps on release; then the model follows)
    func update(items: [TabItem], selected: Int, theme: Theme)
}

// Reorder.swift — the one drag gesture: trackDrag(from:in:_:) (4 pt threshold, closed hand; tabs, pane headers),
// and Reorder().drag(views, from, by: offset, done:, commit:) for pick-up, drag and snap in a row of views (x axis only).

// InlineRename (TabBarView.swift): makes a label editable in place; Return/click away commits, Esc cancels. static var isEditing (render() skips refocusing the terminal while true)

// FindBar.swift
@MainActor final class FindBar: NSView {   // glass capsule, NSSearchField, glass chevron/xmark buttons; fades+scales when isHidden toggles; apply(theme:) is a no-op (system colors)
    var onChange: ((String) -> Void)?; var onNext: (() -> Void)?; var onPrevious: (() -> Void)?; var onClose: (() -> Void)?
    var text: String
    func show(needle: String); func setCounts(total: Int, selected: Int); func apply(theme: Theme)
}
// Find (WorkspaceController): ⌘F → find(). Agent pane (Agents.transcript resolved, off main) → transcript mode: the bar's typing (debounced 120 ms) / Return / ⇧Return / ⌘G / ⇧⌘G / counter drive the transcript matches, listed in the right preview sidebar by TranscriptSearchView (previous inspector content + collapsed state restored by hideFind/endTranscript; opening a file, Esc/close, or focusing another pane ends it). Any other pane, or no transcript found → libghostty search (start_search / search:<text> / navigate_search / end_search), as before.

// Transcript.swift — session jsonl → searchable entries; the terminal of a fullscreen-TUI agent only holds the visible screen
struct TranscriptEntry: Sendable, Equatable { enum Kind { case user, assistant, toolCall, toolOutput }; let kind: Kind; let text: String; let time: Date? }
struct TranscriptMatch: Sendable, Equatable { let entry: Int; let range: NSRange }   // one per occurrence; UTF-16 range in the entry's text
struct TranscriptResult: Sendable { let entries: [TranscriptEntry]; let matches: [TranscriptMatch] }   // matches in file order
enum TranscriptParser {
    static func entries(_ line: Data, codex: Bool) -> [TranscriptEntry]   // one jsonl line; Claude: user/assistant text, tool_use "<name> <compact json>", tool_result; Codex: response_item message/function_call/custom_tool_call (+ outputs); everything else, isMeta and injected context skipped
    static func matches(in entries: [TranscriptEntry], _ query: String) -> [TranscriptMatch]   // case- and diacritic-insensitive substring
}
final class TranscriptIndex: @unchecked Sendable { init(_ url: URL); var entries: [TranscriptEntry]; func update() }   // reads only appended complete lines since the last call; confined to TranscriptSearch's queue
enum TranscriptSearch {   // background queue; per-file index cache; a newer call supersedes older ones (stale results dropped)
    static func locate(_ pane: PaneID, done: @escaping @Sendable @MainActor (URL?) -> Void)
    static func search(_ url: URL, _ query: String, done: @escaping @Sendable @MainActor (TranscriptResult) -> Void)
    static func cancel()
}
// TranscriptSearchView.swift — right-sidebar results: NSTableView of matches (kind SF Symbol, relative time, snippet with the hit bold) above an NSTextView with the selected entry's full text, hit highlighted + showFindIndicator
@MainActor final class TranscriptSearchView: NSView {
    var onSelect: ((Int) -> Void)?; var onCancel: (() -> Void)?; private(set) var selected: Int; var count: Int
    func show(_ r: TranscriptResult, query: String)   // selects the newest (last) match
    func select(_ i: Int)                              // table selection drives the text and onSelect
}

// Control.swift — unix socket at Store.directory/pane.sock, one JSON object per line ([String: String]), one reply line
final class ControlServer: @unchecked Sendable { init(path: String, handler: @escaping @MainActor ([String: String]) -> String); func start(); func stop() }
enum ControlClient { static func run(_ args: [String]) -> Int32 }   // argv after the program name
```
