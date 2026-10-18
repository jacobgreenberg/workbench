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
struct Project: Codable, Identifiable, Equatable, Sendable { var id: UUID; var path: String; var name: String; var tabs: [Tab]; var activeTab: Int; var scratch: Bool? = nil /* ⇧⌘N temp project in ~: dropped when its last tab closes and at load */; var hidden: Bool? = nil /* off the Active list, listed under Hidden; terminals and agents keep running; nil/absent = active */ }
struct Preset: Codable, Equatable, Sendable { var key: Int; var name: String; var command: String; var scrollbackLimit: Int? }
struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]; var activeProject: Int /* -1 = none (the last active project was hidden) */; var sidebarVisible: Bool; var theme: String; var presets: [Preset]
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
    static func all() -> [Theme]                         // read once per run: Bundle.main.resourceURL/themes/*.json, then Store.directory/themes/*.json overriding by id; sorted by name
    static func named(_ id: String) -> Theme             // falls back to "oceanic-v2", then first
    func color(_ key: String) -> NSColor                  // ui[key] (hex #RRGGBB or rgba(r, g, b, a)); magenta if missing
    func terminalColor(_ key: String) -> NSColor          // terminal[key] (ANSI palette); ui foreground if missing
    var ghosttyConfig: String                             // newline-separated ghostty config lines for terminal colors + split-divider-color
}

// Agents.swift — agent processes found by inherited PANE_ID; launcher (cc1/cc2/gpt1…) recovered from the user's zsh functions
enum Agents {
    static let claudeHookArgs: String; static let codexHookArgs: String
    static func discoverLaunchers()                       // once at launch, background
    static func running() -> [PaneID: String?]           // pane → resume command; nil = agent running but id unknown yet (keep the saved command), e.g. "cc2 --resume <id>", "gpt1 resume <thread id>" (id from argv, else a distinct recent CLI thread of its folder from CODEX_HOME/state_*.sqlite)
}

// SplitTreeView.swift
enum FocusDirection: Sendable { case left, right, up, down }
@MainActor final class SplitTreeView: NSView {
    var onRatiosChanged: ((SplitNode) -> Void)?           // user dragged a divider; tree with updated ratios
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header (shown when the tab has 2+ panes) onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    func updateHeaders(focused: PaneID?, theme: Theme, title: (PaneID) -> String)   // called from updateChrome
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

// SidebarView.swift
struct SidebarRow: Equatable, Sendable { let name: String; let path: String; let status: PaneStatus; let terminals: Int; let agents: Int }   // agents: terminals whose launch is set (an agent runs there)
enum PaneStatus: Int, Comparable, Sendable { case idle = 0, busy = 1, done = 2, attention = 3 }   // Comparable by rawValue
@MainActor final class SidebarView: NSView {   // native .sourceList table: selection = active project, native drag-and-drop reorder
    var onSelect: ((Int) -> Void)?; var onRemove: ((Int) -> Void)?         // all indices are rows of the list shown; WorkspaceController maps rows to projects (visibleProjectIndices / reorderedProjects in Model.swift)
    var onShowHidden: ((Bool) -> Void)?                  // Active/Hidden segmented control above the list
    var onToggleHidden: ((Int) -> Void)?                 // context menu Hide Project (Active view) / Show Project (Hidden view)
    var onRename: ((Int, String?) -> Void)?              // double-click a row; nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a project: from, to (final index after removal)
    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme)   // selected -1 = none
}   // Add Project is a toolbar item (WorkspaceController), not a sidebar button

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
    func show(needle: String); func setCounts(total: Int, selected: Int); func apply(theme: Theme)
}

// Control.swift — unix socket at Store.directory/pane.sock, one JSON object per line ([String: String]), one reply line
final class ControlServer: @unchecked Sendable { init(path: String, handler: @escaping @MainActor ([String: String]) -> String); func start(); func stop() }
enum ControlClient { static func run(_ args: [String]) -> Int32 }   // argv after the program name
```
