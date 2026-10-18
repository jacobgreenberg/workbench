import AppKit

/// Find results for an agent's session transcript, shown in the right sidebar: the matches as a list (kind icon,
/// age, snippet with the hit bold) above the full text of the selected entry, scrolled to and flashing the hit.
/// Selection is the only state: `select(_:)` drives the table, whose delegate updates the text and calls `onSelect`.
@MainActor final class TranscriptSearchView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?                  // Esc while focus is in the list or text
    private(set) var selected = -1
    var count: Int { result.matches.count }

    private var result = TranscriptResult(entries: [], matches: [])
    private let table = NSTableView()
    private let list = NSScrollView()
    private let detail = NSTextView.scrollableTextView()
    private var text: NSTextView { detail.documentView as! NSTextView }
    private let empty = NSTextField(labelWithString: "Search this session's transcript")
    private let split = NSSplitView()
    private var placed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("match"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        list.documentView = table
        list.hasVerticalScroller = true
        list.drawsBackground = false
        table.backgroundColor = .clear

        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        detail.drawsBackground = false
        text.drawsBackground = false

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.frame = bounds
        split.autoresizingMask = [.width, .height]
        addSubview(split)

        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if !placed, bounds.height > 0 { placed = true; split.setPosition(bounds.height * 0.45, ofDividerAt: 0) }
    }
    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p + 80 }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p - 80 }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// New results: selects the newest match.
    func show(_ r: TranscriptResult, query: String) {
        table.deselectAll(nil)
        result = r
        selected = -1
        table.reloadData()
        empty.stringValue = query.isEmpty ? "Search this session's transcript" : "No matches"
        empty.isHidden = !r.matches.isEmpty
        if r.matches.isEmpty { text.string = "" } else { select(r.matches.count - 1) }
    }

    func select(_ i: Int) {
        guard result.matches.indices.contains(i) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { result.matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell()
        let m = result.matches[row], e = result.entries[m.entry]
        cell.set(kind: e.kind, time: e.time, snippet: snippet(m))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let i = table.selectedRow
        guard i >= 0 else { return }
        selected = i
        showEntry(of: i)
        onSelect?(i)
    }

    /// The hit with some context either side, on one line (newlines become spaces, so ranges still line up).
    private func snippet(_ m: TranscriptMatch) -> NSAttributedString {
        let s = result.entries[m.entry].text as NSString
        let start = max(0, m.range.location - 40), end = min(s.length, NSMaxRange(m.range) + 100)
        let r = s.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let flat = String(String.UnicodeScalarView(s.substring(with: r).unicodeScalars.map { "\n\r\t".unicodeScalars.contains($0) ? " " : $0 }))
        let lead = r.location > 0 ? "…" : ""
        let out = NSMutableAttributedString(string: lead + flat, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let hit = NSRange(location: m.range.location - r.location + lead.utf16.count, length: m.range.length)
        if NSMaxRange(hit) <= out.length {
            out.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12), .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)], range: hit)
        }
        return out
    }

    /// Full text of the selected match's entry, every hit tinted and the current one scrolled to and flashed.
    private func showEntry(of i: Int) {
        let m = result.matches[i]
        let out = NSMutableAttributedString(string: result.entries[m.entry].text,
                                            attributes: [.font: text.font!, .foregroundColor: NSColor.labelColor])
        for other in result.matches where other.entry == m.entry { out.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: other.range) }
        out.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.7), range: m.range)
        text.textStorage?.setAttributedString(out)
        text.scrollRangeToVisible(m.range)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if self?.selected == i { self?.text.showFindIndicator(for: m.range) } }
        }
    }

    private final class Cell: NSTableCellView {
        static let id = NSUserInterfaceItemIdentifier("transcriptCell")
        private let icon = NSImageView(), time = NSTextField(labelWithString: ""), snippet = NSTextField(labelWithString: "")
        private static let age: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            time.font = .systemFont(ofSize: 11)
            snippet.maximumNumberOfLines = 2
            snippet.textColor = .labelColor
            snippet.lineBreakMode = .byTruncatingTail
            snippet.cell?.wraps = true
            snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textField = snippet
            for v in [icon, time, snippet] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: time.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                time.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                time.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                snippet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                snippet.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 2),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func set(kind: TranscriptEntry.Kind, time t: Date?, snippet s: NSAttributedString) {
            let (symbol, label) = switch kind {
            case .user: ("person", "You")
            case .assistant: ("sparkle", "Assistant")
            case .toolCall: ("wrench", "Tool call")
            case .toolOutput: ("text.alignleft", "Tool output")
            }
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            time.stringValue = label + (t.map { " · " + Self.age.localizedString(for: $0, relativeTo: Date()) } ?? "")
            snippet.attributedStringValue = s
        }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet {
                let on = backgroundStyle == .emphasized
                time.textColor = on ? .alternateSelectedControlTextColor : .secondaryLabelColor
                icon.contentTintColor = time.textColor
                snippet.textColor = on ? .alternateSelectedControlTextColor : .labelColor
            }
        }
    }
}
