import AppKit
import Carbon
@preconcurrency import GhosttyKit

final class SurfaceBox: Sendable {
    let id: PaneID
    init(id: PaneID) { self.id = id }
}

@MainActor
final class SurfaceView: NSView, @preconcurrency NSTextInputClient {
    let paneID: PaneID
    let box: SurfaceBox
    private(set) var surface: ghostty_surface_t?
    var onFocus: ((PaneID) -> Void)?
    var contextMenu: ((PaneID) -> NSMenu?)?   // right-click, unless the terminal app captures the mouse (⇧ bypasses)
    static var isReservedShortcut: (NSEvent) -> Bool = { _ in false }

    private var markedText = NSMutableAttributedString()
    private(set) var focused: Bool = false
    private var prevPressureStage: Int = 0
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var eventMonitor: Any?
    private var sentSize: (w: UInt32, h: UInt32) = (0, 0)
    private var displayID: UInt32?
    private var screenObserver: NSObjectProtocol?
    private var visible = true
    private var realized = true
    private var closed = false
    private var cursor: NSCursor = .iBeam
    private var contentSizeBacking: NSSize?
    private var contentSize: NSSize {
        get { contentSizeBacking ?? frame.size }
        set { contentSizeBacking = newValue }
    }
    private var cellSize: CGSize {
        guard let surface else { return .zero }
        let s = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: Double(s.cell_width_px) / scale, height: Double(s.cell_height_px) / scale)
    }

    override var acceptsFirstResponder: Bool { true }

    init(app: ghostty_app_t, id: PaneID, cwd: String, initialInput: String?, env: [String: String], scrollbackLimit: Int?) {
        self.paneID = id
        self.box = SurfaceBox(id: id)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var c = ghostty_surface_config_new()
        c.userdata = Unmanaged.passUnretained(box).toOpaque()
        c.platform_tag = GHOSTTY_PLATFORM_MACOS
        c.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        c.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        c.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        c.font_size = 0

        let cwdC = strdup(cwd)
        let inputC = initialInput.map { strdup($0) }
        var keyCs: [UnsafeMutablePointer<CChar>?] = []
        var valueCs: [UnsafeMutablePointer<CChar>?] = []
        var envVars: [ghostty_env_var_s] = []
        for (k, v) in env {
            let kc = strdup(k)
            let vc = strdup(v)
            keyCs.append(kc)
            valueCs.append(vc)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(kc), value: UnsafePointer(vc)))
        }
        defer {
            free(cwdC)
            if let inputC { free(inputC) }
            keyCs.forEach { free($0) }
            valueCs.forEach { free($0) }
        }
        c.working_directory = UnsafePointer(cwdC)
        c.initial_input = inputC.flatMap { UnsafePointer($0) }

        let created: ghostty_surface_t? = envVars.withUnsafeMutableBufferPointer { buf in
            c.env_vars = buf.baseAddress
            c.env_var_count = buf.count
            if let scrollbackLimit {
                return ghostty_surface_new_with_scrollback_limit(app, &c, scrollbackLimit)
            }
            return ghostty_surface_new(app, &c)
        }
        guard let created else {
            NSLog("Workbench: ghostty_surface_new failed for pane \(id)")
            return
        }
        self.surface = created

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: - Public API

    /// True when the surface became visible and already refreshed. libghostty can refuse a realize/unrealize
    /// mid-frame; `realized` records only what it accepted, so the next sync retries instead of forgetting.
    @discardableResult func setVisible(_ visible: Bool) -> Bool {
        guard let s = surface, !closed, self.visible != visible || realized != visible else { return false }
        let shown = visible && !self.visible
        self.visible = visible
        if !visible { ghostty_surface_set_occlusion(s, false) }
        if realized != visible, ghostty_surface_set_renderer_realized(s, visible) { realized = visible }
        guard shown else { return false }
        ghostty_surface_set_occlusion(s, true)
        refresh()
        return true
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        guard surface != nil, !closed else { return }
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: cursor = .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: cursor = .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: cursor = .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: cursor = .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: cursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        default: return
        }
        window?.invalidateCursorRects(for: self)
    }

    func setCursorVisibility(_ visible: Bool) {
        guard surface != nil, !closed else { return }
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        guard let s = surface, !closed else { return false }
        return action.withCString { ghostty_surface_binding_action(s, $0, UInt(action.utf8.count)) }
    }

    var needsConfirmQuit: Bool {
        surface.map(ghostty_surface_needs_confirm_quit) ?? false
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        trackingAreas.forEach { removeTrackingArea($0) }
        guard let s = surface else { return }
        ghostty_surface_request_process_termination(s)
        surface = nil
        nonisolated(unsafe) let ptr = s
        let view = self
        DispatchQueue.global(qos: .utility).async {
            ghostty_surface_free(ptr)
            DispatchQueue.main.async { _ = view }   // last release (NSView dealloc) must happen on main
        }
    }

    @IBAction func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @IBAction func paste(_ sender: Any?) {
        // An image-only clipboard has nothing for Ghostty to paste. Send ⌃V instead: Claude Code and Codex
        // read the clipboard image themselves on ⌃V, so ⌘V works for screenshots too.
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, pb.availableType(from: [.fileURL]) == nil,
           pb.canReadObject(forClasses: [NSImage.self], options: nil), let s = surface, !closed {
            for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                var ev = ghostty_input_key_s()
                ev.action = action
                ev.mods = GHOSTTY_MODS_CTRL
                ev.keycode = 9   // kVK_ANSI_V
                ev.unshifted_codepoint = 0x76
                _ = ghostty_surface_key(s, ev)
            }
            return
        }
        perform("paste_from_clipboard")
    }
    @IBAction func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    @IBAction override func selectAll(_ sender: Any?) { perform("select_all") }

    // MARK: - Focus / size

    private func focusDidChange(_ focused: Bool) {
        guard let surface, !closed else { return }
        guard self.focused != focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
        // ⌘-key releases never reach keyUp (AppKit eats them), so the focused surface watches for them; only the
        // focused one, so a keystroke costs one monitor call however many panes exist.
        if focused, eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
                nonisolated(unsafe) let ev = event
                nonisolated(unsafe) var result: NSEvent? = ev
                MainActor.assumeIsolated { result = self?.localEventHandler(ev) ?? ev }
                return result
            }
        } else if !focused, let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    /// layout() and setFrameSize both fire per resize step; only a changed pixel size reaches Ghostty.
    private func sizeDidChange(_ size: CGSize, force: Bool = false) {
        guard let surface, !closed else { return }
        let px = convertToBacking(size)
        let w = UInt32(max(px.width, 1)), h = UInt32(max(px.height, 1))
        contentSize = size
        guard force || w != sentSize.w || h != sentSize.h else { return }
        sentSize = (w, h)
        ghostty_surface_set_size(surface, w, h)
    }

    func refresh() {
        guard let s = surface, !closed else { return }
        sizeDidChange(frame.size, force: true)
        ghostty_surface_refresh(s)
    }

    override func layout() {
        super.layout()
        sizeDidChange(frame.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Local events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp: return localEventKeyUp(event)
        default: return event
        }
    }

    private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
        if !event.modifierFlags.contains(.command) { return event }
        guard focused else { return event }
        self.keyUp(with: event)
        return nil
    }

    // MARK: - Window / screen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let window, !closed else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidChangeScreen() }
        }
        windowDidChangeScreen()
    }

    private func windowDidChangeScreen() {
        guard let window, let screen = window.screen, let surface, !closed else { return }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard id != displayID else { return }   // re-parenting within a split rebuild lands here on the same screen
        displayID = id
        ghostty_surface_set_display_id(surface, id)
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDidChange(true)
            onFocus?(paneID)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface, !closed else { return }

        let fbFrame = self.convertToBacking(self.frame)
        let xScale = fbFrame.size.width / self.frame.size.width
        let yScale = fbFrame.size.height / self.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        sizeDidChange(contentSize, force: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? { closed ? nil : contextMenu?(paneID) }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface, !closed else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        guard let surface, !closed else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, !closed else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event), mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, !closed else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event), mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface, !closed else { return super.rightMouseDown(with: event) }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface, !closed else { return super.rightMouseUp(with: event) }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface, !closed else { return }
        let pos = self.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface, !closed else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface, !closed else { return }
        let pos = self.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface, !closed else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.scrollMods(precision: precision, momentum: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface, !closed else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        guard prevPressureStage < 2 else { return }
        prevPressureStage = event.stage
    }

    // MARK: - Keyboard

    private static var keyboardLayoutID: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            return unsafeBitCast(ptr, to: CFString.self) as String
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        guard let surface, !closed else {
            self.interpretKeyEvents([event])
            return
        }

        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.ghosttyMods(event.modifierFlags)
            )
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        let keyboardIdBefore: String? = if !markedTextBefore {
            Self.keyboardLayoutID
        } else {
            nil
        }

        self.lastPerformKeyEvent = nil

        self.interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore,
           let list = keyTextAccumulator,
           list.count > 0 {
            for text in list {
                if SurfaceView.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = committedPreeditTextAction(action, text: text)
            }

            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, composing: false)
            }
            return
        }

        if let list = keyTextAccumulator, list.count > 0 {
            for text in list {
                if SurfaceView.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if SurfaceView.shouldSuppressComposingControlInput(event.characters, composing: composing) {
                return
            }
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        if !focused {
            return false
        }

        if SurfaceView.isReservedShortcut(event) { return true }

        guard let surface, !closed else { return false }

        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }
        if isBinding {
            self.keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) {
                return false
            }
            equivalent = "\r"

        case "/":
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }
            equivalent = "_"

        default:
            if event.timestamp == 0 {
                return false
            }

            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }

        self.keyDown(with: finalEvent)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)

        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface, !closed else { return false }

        var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key_ev.composing = composing

        if let text,
           !text.isEmpty,
           let scalar = text.unicodeScalars.first,
           !(scalar.value < 0x20 || scalar.value == 0x7F) {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        } else {
            return ghostty_surface_key(surface, key_ev)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E:
            return true
        case 0x7B:
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private func committedPreeditTextAction(
        _ action: ghostty_input_action_e,
        text: String
    ) -> Bool {
        guard let surface, !closed else { return false }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = 0
        key_ev.text = nil
        key_ev.composing = false
        key_ev.mods = GHOSTTY_MODS_NONE
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        key_ev.unshifted_codepoint = 0

        return text.withCString { ptr in
            key_ev.text = ptr
            return ghostty_surface_key(surface, key_ev)
        }
    }

    // MARK: - IME helpers

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface, !closed else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    static func shouldSuppressComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface, !closed else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, !closed else { return nil }
        guard range.length > 0 else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return .init(string: String(cString: text.text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, !closed else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        let cell = cellSize
        var x: Double = 0
        var y: Double = 0
        var width: Double = cell.width
        var height: Double = cell.height

        if range.length > 0 && range != self.selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            width = 0
            x += cell.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cell.height))

        let winRect = self.convert(viewRect, to: nil)

        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        guard surface != nil, !closed else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        let hadMarkedText = hasMarkedText()

        unmarkText()

        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        if hadMarkedText, !chars.isEmpty {
            _ = committedPreeditTextAction(GHOSTTY_ACTION_PRESS, text: chars)
            return
        }

        if let surface {
            chars.withCString { ghostty_surface_text(surface, $0, UInt(chars.utf8.count)) }
        }
    }

    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
