import AppKit

struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }

/// Borderless chrome button that shows the pointing-hand cursor on hover.
final class HandButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor private final class TabButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSTextField(labelWithString: "×")
    private let status: PaneStatus
    private var selected = false
    private var hovering = false
    private var theme: Theme?

    static func width(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return min(max(ceil(w) + 56, 80), 220)
    }

    init(item: TabItem, height: CGFloat) {
        status = item.status
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(for: item.title), height: height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: frame.width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = item.status == .idle
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.font = .systemFont(ofSize: 13)
        close.isHidden = true
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

    func apply(selected: Bool, theme: Theme) {
        self.selected = selected
        self.theme = theme
        refresh()
    }

    private func refresh() {
        guard let theme else { return }
        label.textColor = theme.color(selected ? "cardForeground" : hovering ? "foreground" : "mutedForeground")
        close.textColor = theme.color("mutedForeground")
        close.isHidden = !hovering
        let key: String
        switch status {
        case .busy: key = "primary"
        case .done: key = "chart2"
        default: key = "chart3"
        }
        dot.layer?.backgroundColor = theme.color(key).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !close.isHidden && p.x >= close.frame.minX - 6 { onClose?() } else { onSelect?() }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }
}

@MainActor final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let plus = HandButton(title: "+", target: nil, action: nil)
    private let border = NSView()
    private var items: [TabItem] = []
    private var buttons: [TabButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        border.wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.edgeInsets = NSEdgeInsets()
        plus.isBordered = false
        plus.refusesFirstResponder = true
        plus.target = self
        plus.action = #selector(newTapped)
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.widthAnchor.constraint(equalToConstant: 30).isActive = true
        for v in [stack, border] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func newTapped() { onNew?() }

    func update(items newItems: [TabItem], selected: Int, theme: Theme) {
        if newItems != items || buttons.count != newItems.count {
            items = newItems
            buttons.forEach { $0.removeFromSuperview() }
            plus.removeFromSuperview()
            buttons = newItems.enumerated().map { i, item in
                let b = TabButton(item: item, height: max(bounds.height, 34))
                b.onSelect = { [weak self] in self?.onSelect?(i) }
                b.onClose = { [weak self] in self?.onClose?(i) }
                stack.addArrangedSubview(b)
                return b
            }
            stack.addArrangedSubview(plus)
        }
        layer?.backgroundColor = theme.color("background").cgColor
        border.layer?.backgroundColor = theme.color("border").cgColor
        plus.attributedTitle = NSAttributedString(string: "+", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: theme.color("mutedForeground"),
        ])
        for (i, b) in buttons.enumerated() { b.apply(selected: i == selected, theme: theme) }
    }
}
