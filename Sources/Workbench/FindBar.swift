import AppKit

@MainActor final class FindBar: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let prev = HandButton(title: "‹", target: nil, action: nil)
    private let next = HandButton(title: "›", target: nil, action: nil)
    private let close = HandButton(title: "×", target: nil, action: nil)
    private var theme: Theme?

    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 36) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        field.placeholderString = "Find"
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (b, a) in [(prev, #selector(prevTapped)), (next, #selector(nextTapped)), (close, #selector(closeTapped))] {
            b.isBordered = false
            b.target = self
            b.action = a
            b.setContentHuggingPriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [field, count, prev, next, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
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

    func apply(theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = theme.color("popover").cgColor
        layer?.borderColor = theme.color("border").cgColor
        field.textColor = theme.color("popoverForeground")
        count.textColor = theme.color("mutedForeground")
        for b in [prev, next, close] {
            b.attributedTitle = NSAttributedString(
                string: b.title,
                attributes: [.foregroundColor: theme.color("mutedForeground"), .font: NSFont.systemFont(ofSize: 14)])
        }
    }

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
