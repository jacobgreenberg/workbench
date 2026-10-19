import AppKit

private final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

private final class CheckCircle: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.toggle)
        setAccessibilityRole(.checkBox)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if state == .on {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            guard let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) else { return }
            let rect = NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            let white = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: rect)
        } else {
            circle.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            circle.stroke()
        }
    }
}

/// The right sidebar's checklist for one project, edited like an Apple Notes checklist: tick the circle, type in place, Return for a new item, Backspace on an empty one to delete it; a "New to-do" line always waits at the bottom.
@MainActor final class TodoListView: NSView, NSTextFieldDelegate {
    var onChange: (([Todo]) -> Void)?
    private(set) var todos: [Todo] = []
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private var rowFields: [NSTextField] = []
    private var circles: [CheckCircle] = []
    private var newRow: NSView?   // the "New to-do" line: shown while the list is empty or you're adding
    private var rebuilding = false   // removing the field being edited fires its end-editing action; ignore it

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ todos: [Todo]) {
        self.todos = todos
        rebuild()
    }

    override func mouseDown(with event: NSEvent) { beginNew() }   // empty space below the items starts a new one

    private func beginNew() {
        newRow?.isHidden = false
        window?.makeFirstResponder(rowFields.last)
    }

    private func rebuild() {
        rebuilding = true
        defer { rebuilding = false }
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        rowFields = []
        circles = []
        let anyDone = todos.contains { $0.done }
        for i in 0...todos.count {
            let t = todos.indices.contains(i) ? todos[i] : nil
            let circle = CheckCircle()
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.font = .systemFont(ofSize: 14)
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            field.target = self
            field.action = #selector(commit(_:))
            field.cell?.sendsActionOnEndEditing = true   // clicking away saves too
            field.tag = i
            field.delegate = self
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.focusRingType = .none
            field.placeholderAttributedString = NSAttributedString(string: "New to-do", attributes: [   // a borderless field draws a plain placeholder in label color
                .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 14)])
            if let t {
                circle.target = self
                circle.action = #selector(toggle(_:))
                circle.tag = i
                circle.state = t.done ? .on : .off
                circle.setAccessibilityLabel(t.text)
                field.stringValue = t.text
                field.textColor = t.done ? .secondaryLabelColor : .labelColor
            } else {
                circle.isEnabled = false
                circle.alphaValue = 0.5
                field.textColor = .labelColor
            }
            rowFields.append(field)
            circles.append(circle)
            // A plain row, not a stack: the circle centers on the text's first line (baseline − half the cap height).
            let row = NSView()
            field.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(circle)
            row.addSubview(field)
            let font = field.font!
            NSLayoutConstraint.activate([
                circle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                circle.centerYAnchor.constraint(equalTo: field.firstBaselineAnchor, constant: -font.capHeight / 2),
                field.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                field.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
                field.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
            ])
            if t != nil {
                let menu = NSMenu()
                menu.autoenablesItems = false
                let del = NSMenuItem(title: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: "")
                del.tag = i
                menu.addItem(del)
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Uncheck All", action: #selector(uncheckAll(_:)), keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "Delete Checked Items", action: #selector(deleteChecked(_:)), keyEquivalent: ""))
                for item in menu.items where item.action != nil { item.target = self; item.isEnabled = true }
                menu.items[2].isEnabled = anyDone
                menu.items[3].isEnabled = anyDone
                row.menu = menu
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            if t == nil { newRow = row; row.isHidden = !todos.isEmpty }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -28).isActive = true
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard todos.indices.contains(sender.tag) else { return }
        todos[sender.tag].done.toggle()
        rowFields[sender.tag].textColor = todos[sender.tag].done ? .secondaryLabelColor : .labelColor
        onChange?(todos)
    }

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard todos.indices.contains(sender.tag) else { return }
        todos.remove(at: sender.tag)
        rebuild()
        onChange?(todos)
    }

    @objc private func uncheckAll(_ sender: NSMenuItem) {
        for i in todos.indices { todos[i].done = false }
        rebuild()
        onChange?(todos)
    }

    @objc private func deleteChecked(_ sender: NSMenuItem) {
        todos.removeAll { $0.done }
        rebuild()
        onChange?(todos)
    }

    @objc private func commit(_ field: NSTextField) {
        guard !rebuilding, rowFields.contains(field), field.tag <= todos.count else { return }
        let i = field.tag
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if i == todos.count {   // focus left the new line: keep what was typed, else hide it again
            if !text.isEmpty { todos.append(Todo(id: UUID(), text: text, done: false)); rebuild(); onChange?(todos) }
            else { newRow?.isHidden = !todos.isEmpty }
        } else if text.isEmpty {
            todos.remove(at: i)
            rebuild()
            onChange?(todos)
        } else if text != todos[i].text {
            todos[i].text = text
            circles[i].setAccessibilityLabel(text)
            onChange?(todos)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField, rowFields.contains(field) else { return false }
        let i = field.tag
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if i == todos.count {   // Return on the new line: add it and keep going on a fresh one
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return true }
                todos.append(Todo(id: UUID(), text: text, done: false))
                rebuild()
                onChange?(todos)
                beginNew()
                return true
            }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { todos[i].text = text }
            todos.insert(Todo(id: UUID(), text: "", done: false), at: i + 1)
            rebuild()
            onChange?(todos)
            window?.makeFirstResponder(rowFields[i + 1])
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard i < todos.count, field.stringValue.isEmpty else { return false }
            todos.remove(at: i)
            rebuild()
            onChange?(todos)
            window?.makeFirstResponder(rowFields[max(i - 1, 0)])
            (window?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard i > 0 else { return false }
            window?.makeFirstResponder(rowFields[i - 1])
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard i + 1 < rowFields.count else { return false }
            window?.makeFirstResponder(rowFields[i + 1])
            return true
        default: return false
        }
    }
}

/// A tab that isn't built yet.
@MainActor final class PlaceholderPane: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
