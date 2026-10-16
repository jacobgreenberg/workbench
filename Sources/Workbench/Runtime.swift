import AppKit
import Synchronization
@preconcurrency import GhosttyKit

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

    private var config: ghostty_config_t
    fileprivate var shuttingDown = false
    private var keyboardObserver: NSObjectProtocol?

    nonisolated static let pending = Atomic<Bool>(false)
    nonisolated(unsafe) static var current: Runtime?

    private static func makeConfig(_ overrides: String) -> ghostty_config_t {
        let cfg = ghostty_config_new()!
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        overrides.withCString { ghostty_config_load_string(cfg, $0, UInt(overrides.utf8.count), "pane") }
        ghostty_config_finalize(cfg)
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let m = d.message { NSLog("ghostty config: %@", String(cString: m)) }
        }
        return cfg
    }

    init(overrides: String) {
        let cfg = Runtime.makeConfig(overrides)
        var rt = ghostty_runtime_config_s()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = Runtime.wakeup
        rt.action_cb = Runtime.action
        rt.read_clipboard_cb = Runtime.readClipboard
        rt.confirm_read_clipboard_cb = Runtime.confirmReadClipboard
        rt.write_clipboard_cb = Runtime.writeClipboard
        rt.close_surface_cb = Runtime.closeSurface
        rt.tmux_control_cb = nil
        guard let app = ghostty_app_new(&rt, cfg) else { fatalError("ghostty_app_new failed") }
        self.app = app
        self.config = cfg
        Runtime.current = self
        ghostty_app_set_focus(app, NSApp.isActive)
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { [app = UncheckedBox(app)] _ in
            ghostty_app_keyboard_changed(app.value)
        }
    }

    func setFocus(_ focused: Bool) { ghostty_app_set_focus(app, focused) }

    func reload(overrides: String) {
        let new = Runtime.makeConfig(overrides)
        ghostty_app_update_config(app, new)
        ghostty_config_free(config)
        config = new
    }

    func shutdown() {
        shuttingDown = true
        ghostty_app_free(app)
        ghostty_config_free(config)
        Runtime.current = nil
    }

    private func deliver(_ id: PaneID, _ event: PaneEvent) {
        delegate?.runtime(self, pane: id, event: event)
    }

    private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    // MARK: callbacks

    private nonisolated static func boxID(_ userdata: UnsafeMutableRawPointer?) -> PaneID? {
        guard let userdata else { return nil }
        return Unmanaged<SurfaceBox>.fromOpaque(userdata).takeUnretainedValue().id
    }

    private nonisolated static let wakeup: ghostty_runtime_wakeup_cb = { _ in
        if !pending.exchange(true, ordering: .acquiringAndReleasing) {
            DispatchQueue.main.async {
                pending.store(false, ordering: .releasing)
                MainActor.assumeIsolated {
                    if let rt = Runtime.current, !rt.shuttingDown { ghostty_app_tick(rt.app) }
                }
            }
        }
    }

    private nonisolated static func post(_ id: PaneID, _ event: PaneEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Runtime.current?.deliver(id, event) }
        }
    }

    private nonisolated static let action: ghostty_runtime_action_cb = { _, target, action in
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        let surface: ghostty_surface_t? = target.target.surface
        guard let surface, let id = boxID(ghostty_surface_userdata(surface)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let t = action.action.set_title.title else { return false }
            post(id, .title(String(cString: t)))
        case GHOSTTY_ACTION_PWD:
            guard let p = action.action.pwd.pwd else { return false }
            post(id, .pwd(String(cString: p)))
        case GHOSTTY_ACTION_RING_BELL:
            post(id, .bell)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            post(id, .notification(
                title: n.title.map { String(cString: $0) } ?? "",
                body: n.body.map { String(cString: $0) } ?? ""))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let c = action.action.command_finished
            post(id, .commandFinished(exitCode: Int(c.exit_code), durationNs: c.duration))
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return true }
            post(id, .openURL(String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)))
        case GHOSTTY_ACTION_START_SEARCH:
            post(id, .startSearch(action.action.start_search.needle.map { String(cString: $0) } ?? ""))
        case GHOSTTY_ACTION_END_SEARCH:
            post(id, .endSearch)
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            post(id, .searchTotal(Int(action.action.search_total.total)))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            post(id, .searchSelected(Int(action.action.search_selected.selected)))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Runtime.current?.delegate?.surfaceView(for: id)?.setCursorShape(shape)
                }
            }
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Runtime.current?.delegate?.surfaceView(for: id)?.setCursorVisibility(visible)
                }
            }
        default:
            return false
        }
        return true
    }

    private nonisolated static let closeSurface: ghostty_runtime_close_surface_cb = { userdata, alive in
        guard let id = boxID(userdata) else { return }
        post(id, .closeRequested(processAlive: alive))
    }

    private nonisolated static func complete(_ id: PaneID, _ str: String, _ state: UInt, _ confirmed: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let surface = Runtime.current?.delegate?.surfaceView(for: id)?.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, str, UnsafeMutableRawPointer(bitPattern: state), confirmed)
            }
        }
    }

    private nonisolated static let readClipboard: ghostty_runtime_read_clipboard_cb = { userdata, location, state in
        // Called on main from inside key handling (paste binding). Complete synchronously, as upstream does, so the
        // paste lands before any later keystroke; return false with no text so a performable paste binding falls through.
        guard location == GHOSTTY_CLIPBOARD_STANDARD, Thread.isMainThread, let id = boxID(userdata) else { return false }
        nonisolated(unsafe) let state = state
        return MainActor.assumeIsolated {
            guard let surface = Runtime.current?.delegate?.surfaceView(for: id)?.surface,
                  let str = NSPasteboard.general.string(forType: .string) else { return false }
            ghostty_surface_complete_clipboard_request(surface, str, state, false)
            return true
        }
    }

    private nonisolated static let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = { userdata, cstr, state, request in
        guard let id = boxID(userdata) else { return }
        let s = UInt(bitPattern: state)
        if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            complete(id, cstr.map { String(cString: $0) } ?? "", s, true)
        } else {
            complete(id, "", s, true)   // deny an OSC 52 read: empty data, confirmed (upstream's cancel path)
        }
    }

    private nonisolated static let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, location, content, len, _ in
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        var text: String?
        for i in 0..<len {
            let item = content[i]
            if let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data {
                text = String(cString: data)
                break
            }
        }
        guard let text else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
