import AppKit

struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }

/// Borderless chrome button that shows the pointing-hand cursor on hover.
final class HandButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// A round Liquid Glass icon button (new tab, add project, close preview).
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

@MainActor private final class TabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String?) -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?   // x moved since mouse-down, done
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSTextField(labelWithString: "×")
    private var status = PaneStatus.idle
    private var width: NSLayoutConstraint!
    private var selected = false
    private var hovering = false
    private var theme: Theme?

    static func width(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return min(max(ceil(w) + 56, 80), 220)
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
        close.font = .systemFont(ofSize: 13)
        close.isHidden = true
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
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
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

    /// The tab takes every click itself: the label and dot are window-draggable, so a double-click landing on them
    /// reached the title bar (the tab bar sits in it) and minimized the window. The label gets clicks only mid-rename.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return label.isEditable ? hit : self
    }

    /// Updates in place; buttons are only rebuilt when the tab count changes.
    func apply(item: TabItem, selected: Bool, theme: Theme) {
        if label.stringValue != item.title, !label.isEditable {
            label.stringValue = item.title
            width.constant = Self.width(for: item.title)
        }
        status = item.status
        self.selected = selected
        self.theme = theme
        refresh()
    }

    private func refresh() {
        guard let theme else { return }
        label.textColor = theme.color(selected ? "cardForeground" : hovering ? "foreground" : "mutedForeground")
        close.textColor = theme.color("mutedForeground")
        close.isHidden = !hovering
        // A lighter pill on the glass, like native segmented tabs.
        let fg = theme.color("foreground")
        layer?.backgroundColor = selected ? fg.withAlphaComponent(0.14).cgColor : hovering ? fg.withAlphaComponent(0.06).cgColor : nil
        styleStatusDot(dot, status, theme: theme)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !close.isHidden && p.x >= close.frame.minX - 6 { onClose?() }
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

@MainActor final class TabBarView: NSView {
    /// Empty band above the tabs: it is the window's title bar (drag, double-click to minimize, traffic lights),
    /// kept apart so double-clicking a tab can only rename it.
    static let titleStrip: CGFloat = 28
    static let tabHeight: CGFloat = 34   // the glass capsule row; tabs are pills inset in it
    private static let pill: CGFloat = 26

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((Int, String?) -> Void)?
    var onMove: ((Int, Int) -> Void)?   // from, to

    private let stack = NSStackView()
    private let plus = HandButton.glass("plus", "New Tab", .large)
    private let glass = NSGlassEffectView()
    private var buttons: [TabButton] = []
    private let reorder = Reorder(.x)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        glass.cornerRadius = Self.pill / 2 + 4
        plus.target = self
        plus.action = #selector(newTapped)
        for v in [glass, stack, plus] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The capsule hugs the tabs; + floats beside it. Above them (titleStrip) is bare title bar.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.heightAnchor.constraint(equalToConstant: Self.pill + 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            glass.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            glass.topAnchor.constraint(equalTo: stack.topAnchor),
            glass.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            plus.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 8),
            plus.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            plus.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
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

    private var last: (items: [TabItem], selected: Int, theme: String)?

    func update(items newItems: [TabItem], selected: Int, theme: Theme) {
        // Called on every title/status event of any pane; most change nothing visible here.
        let state = (newItems, selected, theme.id)
        if let last, last == state { return }
        last = state
        if buttons.count != newItems.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = newItems.indices.map { i in
                let b = TabButton(height: Self.pill)
                // Looked up at call time: dragging reorders the buttons.
                let index = { [unowned self, unowned b] in buttons.firstIndex { $0 === b } ?? i }
                b.onSelect = { [weak self] in self?.onSelect?(index()) }
                b.onClose = { [weak self] in self?.onClose?(index()) }
                b.onRename = { [weak self] in self?.onRename?(index(), $0) }
                b.onDrag = { [weak self, unowned b] dx, done in
                    guard let self, let from = buttons.firstIndex(where: { $0 === b }) else { return }
                    reorder.drag(buttons, from, by: dx, done: done) { [self] from, to in
                        buttons.insert(buttons.remove(at: from), at: to)
                        stack.insertArrangedSubview(b, at: to)
                        stack.layoutSubtreeIfNeeded()
                        onMove?(from, to)
                    }
                }
                stack.addArrangedSubview(b)
                return b
            }
            glass.isHidden = buttons.isEmpty
        }
        for (i, b) in buttons.enumerated() { b.apply(item: newItems[i], selected: i == selected, theme: theme) }
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
