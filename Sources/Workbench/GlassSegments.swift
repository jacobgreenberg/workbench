import AppKit

/// One segment: a centered label, hover fill, pointing-hand cursor.
@MainActor private final class SegmentButton: NSView {
    var onClick: (() -> Void)?
    let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { refresh() } }
    var selected = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = GlassSegments.pill / 2
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: GlassSegments.pill).isActive = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)   // the segment itself is the radio button
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { selected ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func refresh() {
        label.textColor = selected || hovering ? .labelColor : .secondaryLabelColor
        layer?.backgroundColor = hovering && !selected ? cg(.quaternarySystemFill) : nil
    }
}

/// The tab bar's toggle look (see TabBarView): a Liquid Glass capsule of equal segments with one selection pill
/// that slides between them (0.28 s, same curve; snaps with Reduce Motion). Visual constants are copied from the tab bar.
@MainActor final class GlassSegments: NSView {
    static let pill: CGFloat = 26
    static let height: CGFloat = 34   // pill + 4pt glass inset each side

    var onSelect: ((Int) -> Void)?
    /// The selection pill's color: the theme's primary, set by the owner on every theme change.
    var tint: NSColor = .controlAccentColor { didSet { indicator.layer?.backgroundColor = tint.withAlphaComponent(0.3).cgColor } }

    private let glass = NSGlassEffectView()
    private let indicator = NSView()   // the selected pill; pinned to the selected segment
    private var pins: [NSLayoutConstraint] = []
    private var buttons: [SegmentButton] = []
    private var selectedIndex = -1

    init(labels: [String]) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        glass.cornerRadius = Self.height / 2
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = Self.pill / 2
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        for (i, text) in labels.enumerated() {
            let b = SegmentButton()
            b.label.stringValue = text
            b.onClick = { [weak self] in self?.onSelect?(i) }
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        let inner = NSView()   // glass content: selection pill under the segments
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(indicator)
        inner.addSubview(stack)
        glass.contentView = inner
        addSubview(glass)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            stack.topAnchor.constraint(equalTo: inner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    func setLabel(_ text: String, at i: Int) {
        if buttons.indices.contains(i) { buttons[i].label.stringValue = text }
    }

    func select(_ i: Int, animated: Bool) {
        guard i != selectedIndex, buttons.indices.contains(i) else { return }
        let moved = animated && selectedIndex >= 0
        selectedIndex = i
        for (n, b) in buttons.enumerated() { b.selected = n == i }
        indicator.layer?.backgroundColor = tint.withAlphaComponent(0.3).cgColor
        NSLayoutConstraint.deactivate(pins)
        let b = buttons[i]
        pins = [indicator.leadingAnchor.constraint(equalTo: b.leadingAnchor),
                indicator.trailingAnchor.constraint(equalTo: b.trailingAnchor),
                indicator.topAnchor.constraint(equalTo: b.topAnchor),
                indicator.bottomAnchor.constraint(equalTo: b.bottomAnchor)]
        NSLayoutConstraint.activate(pins)
        let slide = moved && !indicator.isHidden && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        indicator.isHidden = false
        guard slide, let inner = indicator.superview else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
            c.allowsImplicitAnimation = true
            inner.layoutSubtreeIfNeeded()
        }
    }
}
