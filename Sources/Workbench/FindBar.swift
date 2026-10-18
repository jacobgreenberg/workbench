import AppKit

@MainActor final class FindBar: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let prev = HandButton.glass("chevron.up", "Previous Match", .small)
    private let next = HandButton.glass("chevron.down", "Next Match", .small)
    private let close = HandButton.glass("xmark", "Close Find", .small)

    override var intrinsicContentSize: NSSize { NSSize(width: 340, height: 40) }

    /// Appears and disappears with a short fade + scale; the controller just toggles `isHidden`.
    override var isHidden: Bool {
        get { super.isHidden }
        set {
            let fading = pendingHide != nil   // still visible, fading out
            pendingHide?.cancel()
            pendingHide = nil
            guard newValue != super.isHidden || (!newValue && fading) else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else {
                super.isHidden = newValue
                alphaValue = 1
                return
            }
            if newValue {
                animate(from: 1, to: 0, scale: 0.97)
                let hide = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    pendingHide = nil
                    setHidden(true)
                    layer?.removeAllAnimations()
                }
                pendingHide = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: hide)
            } else {
                super.isHidden = false
                animate(from: 0, to: 1, scale: 0.96)
            }
        }
    }
    private var pendingHide: DispatchWorkItem?

    private func setHidden(_ h: Bool) { super.isHidden = h }

    private func animate(from: Float, to: Float, scale: CGFloat) {
        guard let layer else { return }
        let (w, h) = (bounds.width, bounds.height)
        // Scale about the center (layer-backed views anchor at the origin).
        func t(_ s: CGFloat) -> CATransform3D {
            CATransform3DScale(CATransform3DMakeTranslation(w * (1 - s) / 2, h * (1 - s) / 2, 0), s, s, 1)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = to
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = t(to == 1 ? scale : 1); grow.toValue = t(to == 1 ? 1 : scale)
        for a in [fade, grow] {
            a.duration = 0.14
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = to == 1
        }
        layer.add(fade, forKey: "fade")
        layer.add(grow, forKey: "grow")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let glass = NSGlassEffectView(frame: bounds)
        glass.cornerRadius = 20
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        field.placeholderString = "Find"
        field.controlSize = .large
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (b, a) in [(prev, #selector(prevTapped)), (next, #selector(nextTapped)), (close, #selector(closeTapped))] {
            b.target = self
            b.action = a
            b.setContentHuggingPriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [field, count, prev, next, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func prevTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }

    func show(needle: String) {
        field.stringValue = needle
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func setCounts(total: Int, selected: Int) {
        if total > 0 {
            count.stringValue = selected < 0 ? "–/\(total)" : "\(selected + 1)/\(total)"
        } else {
            count.stringValue = total == 0 ? "0/0" : ""
        }
    }

    /// Chrome uses system colors; kept for the controller's theme pass.
    func apply(theme: Theme) {}

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
