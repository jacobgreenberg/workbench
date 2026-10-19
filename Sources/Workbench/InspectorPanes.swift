import AppKit

private final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

/// The right sidebar's checklist for one project: tick, edit in place (an emptied item is deleted), add at the bottom, Clear Completed.
@MainActor final class TodoListView: NSView {
    var onChange: (([Todo]) -> Void)?
    private(set) var todos: [Todo] = []
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let addField = NSTextField()
    private let clearButton = NSButton(title: "Clear Completed", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No to-dos for this project yet.")
    private var rowFields: [NSTextField] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addField.placeholderString = "Add a to-do"
        addField.bezelStyle = .roundedBezel
        addField.font = .systemFont(ofSize: 13)
        addField.target = self
        addField.action = #selector(add(_:))   // Return (or Accessibility's confirm) adds
        clearButton.controlSize = .small
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [addField, clearButton])   // a hidden Clear Completed gives its room to the field
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(emptyLabel)
        addSubview(bar)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ todos: [Todo]) {
        self.todos = todos
        rebuild()
    }

    private func rebuild() {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        rowFields = []
        for (i, t) in todos.enumerated() {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.tag = i
            box.state = t.done ? .on : .off
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            field.target = self
            field.action = #selector(commit(_:))
            field.cell?.sendsActionOnEndEditing = true   // clicking away saves too
            field.tag = i
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            style(field, t)
            rowFields.append(field)
            let row = NSStackView(views: [box, field])
            row.spacing = 6
            row.alignment = .firstBaseline
            let menu = NSMenu()
            let del = NSMenuItem(title: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: "")
            del.target = self
            del.tag = i
            menu.addItem(del)
            row.menu = menu
            row.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -24).isActive = true
        }
        emptyLabel.isHidden = !todos.isEmpty
        clearButton.isHidden = !todos.contains { $0.done }
    }

    private func style(_ field: NSTextField, _ t: Todo) {
        if t.done {
            field.textColor = .secondaryLabelColor
            field.attributedStringValue = NSAttributedString(string: t.text, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        } else {
            field.textColor = .labelColor
            field.stringValue = t.text
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard todos.indices.contains(sender.tag) else { return }
        todos[sender.tag].done.toggle()
        style(rowFields[sender.tag], todos[sender.tag])
        clearButton.isHidden = !todos.contains { $0.done }
        onChange?(todos)
    }

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard todos.indices.contains(sender.tag) else { return }
        todos.remove(at: sender.tag)
        rebuild()
        onChange?(todos)
    }

    @objc private func clearCompleted() {
        todos.removeAll { $0.done }
        rebuild()
        onChange?(todos)
    }

    @objc private func commit(_ field: NSTextField) {
        guard rowFields.contains(field), todos.indices.contains(field.tag) else { return }
        let i = field.tag
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            todos.remove(at: i)
            rebuild()
        } else if text != todos[i].text {
            todos[i].text = text
            style(field, todos[i])
        } else { return }
        onChange?(todos)
    }

    @objc private func add(_ sender: NSTextField) {
        let text = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        todos.append(Todo(id: UUID(), text: text, done: false))
        addField.stringValue = ""
        rebuild()
        onChange?(todos)
        window?.makeFirstResponder(addField)
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
