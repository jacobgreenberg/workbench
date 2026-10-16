# Workbench

Native macOS terminal IDE for running many Claude Code / Codex sessions. Swift 6 + AppKit + GhosttyKit (libghostty, cmux fork `manaflow-ai/ghostty@cb1ef70`, prebuilt via `scripts/fetch-ghosttykit.sh`). Single SwiftPM executable target `Workbench`, all sources in `Sources/Workbench/`. Reference Ghostty sources (read-only) are in `vendor/ghostty-src/macos/Sources/Ghostty/`; the C API is `vendor/ghostty-src/include/ghostty.h`.

Build: `swift build -c release`, then `scripts/bundle.sh` → `build/Workbench.app`. Run: `open build/Workbench.app`.

Rules: AppKit only (no SwiftUI). No polling timers. Every C callback is a nonisolated `@convention(c)` function that copies data into owned Swift values and hops to main with `DispatchQueue.main.async`. Never touch a SurfaceView's `wantsLayer`/`layer` before `ghostty_surface_new`. Import GhosttyKit as `@preconcurrency import GhosttyKit`.

## Contract (cross-file interfaces — keep exact)

```swift
// Model.swift
typealias PaneID = UUID
enum Agent: String, Codable, Sendable { case claude, codex }
struct Launch: Codable, Equatable, Sendable {
    var command: String          // typed into the shell as initial input
    var resume: String?          // template containing "{id}", used when sessionID != nil
    var agent: Agent?
    var sessionID: String?
    var scrollbackLimit: Int?    // bytes; nil = global default
    var commandLine: String { /* sessionID != nil && resume != nil ? resume!.replacingOccurrences(of: "{id}", with: sessionID!) : command */ }
}
enum PaneKind: Codable, Equatable, Sendable { case terminal(cwd: String, launch: Launch?), markdown(path: String) }
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
    func equalized() -> SplitNode                                  // every ratio = 0.5
}
struct Tab: Codable, Identifiable, Equatable, Sendable { var id: UUID; var title: String; var root: SplitNode; var focused: PaneID? }
struct Project: Codable, Identifiable, Equatable, Sendable { var id: UUID; var path: String; var name: String; var tabs: [Tab]; var activeTab: Int }
struct Preset: Codable, Equatable, Sendable { var key: Int; var name: String; var command: String; var resume: String?; var agent: Agent?; var scrollbackLimit: Int? }
struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]; var activeProject: Int; var sidebarVisible: Bool; var theme: String; var presets: [Preset]
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
    func shutdown()                      // stop ticking, ghostty_app_free (call after all surfaces are freed)
}

// SurfaceView.swift
final class SurfaceBox: Sendable { let id: PaneID; init(id: PaneID) }   // C userdata (passUnretained); owned by SurfaceView
@MainActor final class SurfaceView: NSView, NSTextInputClient {
    let paneID: PaneID
    let box: SurfaceBox
    private(set) var surface: ghostty_surface_t?
    var onFocus: ((PaneID) -> Void)?                     // called from becomeFirstResponder
    static var isReservedShortcut: (NSEvent) -> Bool = { _ in false }   // set by AppDelegate; performs the matching Pane menu action and returns true, else false
    init(app: ghostty_app_t, id: PaneID, cwd: String, initialInput: String?, env: [String: String], scrollbackLimit: Int?)
    func setVisible(_ visible: Bool)     // hide: set_occlusion(false) then set_renderer_realized(false); show: realized(true), occlusion(true), resend size. No-op if unchanged.
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
    static func all() -> [Theme]                         // Bundle.main.resourceURL/themes/*.json, then Store.directory/themes/*.json overriding by id; sorted by name
    static func named(_ id: String) -> Theme             // falls back to "oceanic-v2", then first
    func color(_ key: String) -> NSColor                  // ui[key] (hex #RRGGBB or rgba(r, g, b, a)); magenta if missing
    var ghosttyConfig: String                             // newline-separated ghostty config lines for terminal colors + split-divider-color
}

// SplitTreeView.swift
enum FocusDirection: Sendable { case left, right, up, down }
@MainActor final class SplitTreeView: NSView {
    var onRatiosChanged: ((SplitNode) -> Void)?           // user dragged a divider; tree with updated ratios
    init(provider: @escaping (PaneSpec) -> NSView)        // returns the existing leaf view for a pane (never creates duplicates)
    func render(_ root: SplitNode, dividerColor: NSColor)
    func neighbor(of id: PaneID, _ direction: FocusDirection) -> PaneID?
}

// MarkdownPaneView.swift
@MainActor final class MarkdownPaneView: NSView { let paneID: PaneID; init(id: PaneID, path: String, theme: Theme); func apply(theme: Theme); func close() }

// SidebarView.swift
struct SidebarRow: Equatable, Sendable { let name: String; let path: String; let status: PaneStatus }
enum PaneStatus: Int, Comparable, Sendable { case idle = 0, busy = 1, done = 2, attention = 3 }   // Comparable by rawValue
@MainActor final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?; var onAdd: (() -> Void)?; var onRemove: ((Int) -> Void)?
    func update(rows: [SidebarRow], selected: Int, theme: Theme)
}

// TabBarView.swift
struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }
@MainActor final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?; var onClose: ((Int) -> Void)?; var onNew: (() -> Void)?
    func update(items: [TabItem], selected: Int, theme: Theme)
}

// FindBar.swift
@MainActor final class FindBar: NSView {
    var onChange: ((String) -> Void)?; var onNext: (() -> Void)?; var onPrevious: (() -> Void)?; var onClose: (() -> Void)?
    func show(needle: String); func setCounts(total: Int, selected: Int); func apply(theme: Theme)
}

// Control.swift — unix socket at Store.directory/pane.sock, one JSON object per line ([String: String]), one reply line
final class ControlServer: @unchecked Sendable { init(path: String, handler: @escaping @MainActor ([String: String]) -> String); func start(); func stop() }
enum ControlClient { static func run(_ args: [String]) -> Int32 }   // argv after the program name
```
