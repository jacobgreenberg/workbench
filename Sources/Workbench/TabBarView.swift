import AppKit

struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }

/// Borderless chrome button that shows the pointing-hand cursor on hover.
final class HandButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // Cursor rects lose to a text view's I-beam tracking underneath (the file preview's zoom bar); a cursorUpdate area wins.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.cursorUpdate) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        }
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    /// A round Liquid Glass icon button (new tab, add project).
    static func glass(_ symbol: String, _ label: String, _ size: NSControl.ControlSize = .regular) -> HandButton {
        let b = HandButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.bezelStyle = .glass
        b.borderShape = .circle
        b.controlSize = size
        b.refusesFirstResponder = true
        return b
    }
}

/// Double-click rename: makes a label an in-place text field. Return or clicking away commits, Esc cancels
/// (`done(nil)`).
@MainActor final class InlineRename: NSObject, NSTextFieldDelegate {
    private static var active: InlineRename?
    private let field: NSTextField
    private let original: String
    private let done: (String?) -> Void
    private var finished = false

    static var isEditing: Bool { active != nil }

    @discardableResult init(_ field: NSTextField, done: @escaping (String?) -> Void) {
        self.field = field
        original = field.stringValue
        self.done = done
        super.init()
        InlineRename.active?.finish(field.stringValue)
        InlineRename.active = self
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(field.stringValue) }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        if InlineRename.active === self { InlineRename.active = nil }
        if value == nil { field.stringValue = original }
        field.delegate = nil
        field.isEditable = false
        field.isSelectable = false
        field.abortEditing()
        done(value)
    }
}

@MainActor private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

extension NSView {
    /// Resolves a dynamic system color for this view's current appearance.
    @MainActor func cg(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }
}

@MainActor private final class TabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String?) -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?   // x moved since mouse-down, done
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSImageView(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!)
    private var status = PaneStatus.idle
    private var width: NSLayoutConstraint!
    var preferredWidth: CGFloat { width.constant }
    private var selected = false
    private var hovering = false
    private var theme: Theme?
    /// While dragged, the tab paints its own selected fill (the shared selection indicator stays behind).
    var lifted = false { didSet { refresh() } }

    static func width(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return max(ceil(w) + 56, 80)   // the full title: an overflowing bar scrolls instead of truncating
    }

    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: frame.width)
        width.isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        close.contentTintColor = .secondaryLabelColor
        close.alphaValue = 0
        layer?.cornerRadius = height / 2
        for v in [dot, label, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    /// The tab takes every click itself (the toolbar would otherwise treat label/dot clicks as window drags and a
    /// double-click as a title-bar zoom). The label gets clicks only mid-rename.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return label.isEditable ? hit : self
    }

    /// Updates in place.
    func apply(item: TabItem, selected: Bool, theme: Theme) {
        if !label.isEditable {
            if label.stringValue != item.title { label.stringValue = item.title }
            width.constant = Self.width(for: item.title)   // also after a rename, where the label already shows the new title
        }
        status = item.status
        self.selected = selected
        self.theme = theme
        refresh()
    }

    private func refresh() {
        guard let theme else { return }
        label.textColor = selected || hovering ? .labelColor : .secondaryLabelColor
        let fill: CGColor? = (selected && lifted) ? theme.color("foreground").withAlphaComponent(0.15).cgColor : (hovering && !selected) ? cg(.quaternarySystemFill) : nil
        if let layer, layer.backgroundColor != fill {
            if !reduceMotion, window != nil {
                let a = CABasicAnimation(keyPath: "backgroundColor")
                a.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? cg(.clear)
                a.toValue = fill ?? cg(.clear)
                a.duration = 0.15
                layer.add(a, forKey: "fill")
            }
            layer.backgroundColor = fill
        }
        let target: CGFloat = hovering ? 1 : 0
        if close.alphaValue != target {
            if reduceMotion { close.alphaValue = target } else { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; close.animator().alphaValue = target } }
        }
        styleStatusDot(dot, status, theme: theme)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hovering && p.x >= close.frame.minX - 6 { onClose?() }
        else if event.clickCount == 2 { InlineRename(label) { [weak self] in self?.onRename?($0) } }
        else {
            onSelect?()
            let x = event.locationInWindow.x
            trackDrag(from: event, in: window) { [weak self] p, done in self?.onDrag?(p.x - x, done) }
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }
}

/// Scrolls only sideways; a mouse wheel's vertical turn scrolls it too.
private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let cg = event.cgEvent?.copy() else { return super.scrollWheel(with: event) }
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        for (y, x) in [(CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis2),
                       (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)] {
            cg.setDoubleValueField(x, value: cg.getDoubleValueField(y))
            cg.setDoubleValueField(y, value: 0)
        }
        super.scrollWheel(with: NSEvent(cgEvent: cg) ?? event)
    }
}

/// A toolbar item's view: a glass capsule of tab pills plus a round glass +. Fixed height; the width hugs the tabs
/// up to the room the toolbar gives it, past which the tabs scroll sideways (trackpad, or the mouse wheel).
@MainActor final class TabBarView: NSView {
    private static let pill: CGFloat = 26
    private static let height: CGFloat = 34   // pill + 4pt glass inset each side

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to
    /// The room the toolbar has for the bar, set by the owner as the window resizes (the toolbar itself only ever gives a
    /// view item its minimum, its flexible spaces take the rest).
    /// Starts modest: a bar wider than the toolbar's room drops into its overflow menu, out of the window, where the
    /// owner can no longer measure it.
    static let startWidth: CGFloat = 400
    var maxWidth: CGFloat = startWidth { didSet { if maxWidth != oldValue { fit() } } }
    private lazy var barWidth = widthAnchor.constraint(equalToConstant: 0)

    private let stack = NSStackView()
    private let plus = HandButton.glass("plus", "New Tab", .large)
    private let glass = NSGlassEffectView()
    private let scroll = TabScrollView()   // the tabs, scrolling sideways once they outgrow the bar
    private let indicator = NSView()   // the selected pill, in the theme's foreground at 15%; one view, pinned to the selected tab, slides between tabs
    private var indicatorPins: [NSLayoutConstraint] = []
    private var plusAfterTabs: NSLayoutConstraint!
    private var plusAlone: NSLayoutConstraint!   // no tabs: the glass capsule is hidden, so the + sits at the leading edge
    private var buttons: [TabButton] = []
    private var selectedIndex = -1
    private let reorder = Reorder()

    override init(frame: NSRect) {
        super.init(frame: frame)
        plusAfterTabs = plus.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8)
        plusAlone = plus.leadingAnchor.constraint(equalTo: leadingAnchor)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        glass.cornerRadius = Self.height / 2
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = Self.pill / 2
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        plus.setContentHuggingPriority(.required, for: .horizontal)   // the glass takes the slack: it has no width of its own
        plus.target = self
        plus.action = #selector(newTapped)
        for v in [glass, stack, plus] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        setContentHuggingPriority(.required, for: .horizontal)
        let inner = NSView()   // the scrolled content: selection pill under the tabs
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(indicator)
        inner.addSubview(stack)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = inner
        glass.contentView = scroll
        addSubview(glass)
        addSubview(plus)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: inner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            inner.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            inner.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            inner.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            plusAfterTabs,
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func newTapped() { onNew?() }

    #if DEBUG
    func tabCenter(_ i: Int) -> NSPoint? {
        buttons.indices.contains(i) ? buttons[i].convert(NSPoint(x: buttons[i].bounds.midX, y: buttons[i].bounds.midY), to: nil) : nil
    }
    #endif

    /// The bar's width: hugs the tabs (plus), up to `maxWidth`, past which the tabs scroll. Both a required constraint (the
    /// toolbar sizes a view item to its minimum) and the intrinsic size (whose invalidation makes the toolbar re-measure).
    override var intrinsicContentSize: NSSize { NSSize(width: barWidth.constant, height: Self.height) }

    private func fit() {
        let tabs = buttons.reduce(CGFloat(8)) { $0 + $1.preferredWidth + 2 } - (buttons.isEmpty ? 0 : 2)
        let w = (buttons.isEmpty ? 0 : tabs + 8) + plus.fittingSize.width
        barWidth.constant = max(min(w, maxWidth), plus.fittingSize.width)
        barWidth.isActive = true
        invalidateIntrinsicContentSize()
    }

    /// Pins the pill to the selected tab, so layout keeps it there; a selection change slides it.
    private func placeIndicator(animated: Bool) {
        NSLayoutConstraint.deactivate(indicatorPins)
        indicatorPins = []
        guard buttons.indices.contains(selectedIndex), !buttons[selectedIndex].lifted else { indicator.isHidden = true; return }
        let b = buttons[selectedIndex]
        indicatorPins = [indicator.leadingAnchor.constraint(equalTo: b.leadingAnchor),
                         indicator.trailingAnchor.constraint(equalTo: b.trailingAnchor),
                         indicator.topAnchor.constraint(equalTo: b.topAnchor),
                         indicator.bottomAnchor.constraint(equalTo: b.bottomAnchor)]
        NSLayoutConstraint.activate(indicatorPins)
        let slide = animated && !indicator.isHidden && !reduceMotion
        indicator.isHidden = false
        // Reveal after the slide starts: its layout pass would otherwise apply the new pins at once, and the pill jumps.
        defer { revealSelected() }
        guard slide, let inner = indicator.superview else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
            c.allowsImplicitAnimation = true
            inner.layoutSubtreeIfNeeded()
        }
    }

    /// Scrolls the selected tab into view: on selection, and when the bar's width changes (the toolbar settles it late).
    private func revealSelected() {
        guard buttons.indices.contains(selectedIndex) else { return }
        layoutSubtreeIfNeeded()
        let b = buttons[selectedIndex]
        b.scrollToVisible(b.bounds.insetBy(dx: -4, dy: 0))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { revealSelected() }
    }

    private func endLift() {
        guard buttons.contains(where: \.lifted) else { return }
        buttons.forEach { $0.lifted = false }
        placeIndicator(animated: false)
    }

    private func makeButton() -> TabButton {
        let b = TabButton(height: Self.pill)
        // Looked up at call time: dragging reorders the buttons.
        let index = { [unowned self, unowned b] in buttons.firstIndex { $0 === b } ?? 0 }
        b.onSelect = { [weak self] in self?.onSelect?(index()) }
        b.onClose = { [weak self] in self?.onClose?(index()) }
        b.onRename = { [weak self] in self?.onRename?(index(), $0) }
        b.onDrag = { [weak self, unowned b] dx, done in
            guard let self, let from = buttons.firstIndex(where: { $0 === b }) else { return }
            if !done, !b.lifted { b.lifted = true; placeIndicator(animated: false) }
            reorder.drag(buttons, from, by: dx, done: done) { [self] from, to in
                buttons.insert(buttons.remove(at: from), at: to)
                stack.insertArrangedSubview(b, at: to)
                stack.layoutSubtreeIfNeeded()
                onMove?(from, to)
            }
            if done { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.endLift() } }
        }
        return b
    }

    private var last: (items: [TabItem], selected: Int, theme: String)?

    func update(items newItems: [TabItem], selected: Int, theme: Theme) {
        // Called on every title/status event of any pane; most change nothing visible here.
        let state = (newItems, selected, theme.id)
        if let last, last == state { return }
        let sameTabs = last?.items.map(\.title) == newItems.map(\.title)   // a project switch snaps, a tab click slides
        last = state
        // Add or drop only the difference: the remaining tabs keep their views, so nothing flashes.
        while buttons.count < newItems.count { let b = makeButton(); buttons.append(b); stack.addArrangedSubview(b) }
        while buttons.count > newItems.count { buttons.removeLast().removeFromSuperview() }
        glass.isHidden = buttons.isEmpty
        plusAfterTabs.isActive = !buttons.isEmpty
        plusAlone.isActive = buttons.isEmpty
        let moved = sameTabs && selected != selectedIndex
        selectedIndex = selected
        indicator.layer?.backgroundColor = theme.color("foreground").withAlphaComponent(0.15).cgColor
        for (i, b) in buttons.enumerated() { b.apply(item: newItems[i], selected: i == selected, theme: theme) }
        fit()
        placeIndicator(animated: moved)
    }
}

/// Status dot: hidden when idle, a slow breathing pulse while busy, solid green when done, amber when it needs you.
/// The pulse is a Core Animation layer animation, so it runs in the render server without waking the app.
@MainActor func styleStatusDot(_ dot: NSView, _ status: PaneStatus, theme: Theme) {
    dot.isHidden = status == .idle
    let key = switch status { case .idle, .busy: "primary"; case .done: "chart2"; case .attention: "chart3" }
    dot.layer?.backgroundColor = theme.color(key).cgColor
    guard let layer = dot.layer else { return }
    if status != .busy {
        layer.removeAnimation(forKey: "pulse")
    } else if layer.animation(forKey: "pulse") == nil {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.2
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "pulse")
    }
}
