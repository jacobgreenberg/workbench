import AppKit

/// The toolbar search field; the match counter ("2/7") sits inside it, left of the cancel button.
final class FindField: NSSearchField {
    private let count = NSTextField(labelWithString: "")

    final class Cell: NSSearchFieldCell {
        var reserved: CGFloat = 0   // width taken by the counter
        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            var r = super.searchTextRect(forBounds: rect)
            r.size.width = max(0, r.width - reserved)
            return r
        }
    }
    override class var cellClass: AnyClass? { get { Cell.self } set {} }

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholderString = "Find"
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        addSubview(count)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `selected` is 0-based, -1 if none; `total` -1 = unknown.
    func setCounts(total: Int, selected: Int) {
        count.stringValue = total > 0 ? (selected < 0 ? "–/\(total)" : "\(selected + 1)/\(total)") : (total == 0 ? "0/0" : "")
        count.sizeToFit()
        (cell as? Cell)?.reserved = count.stringValue.isEmpty ? 0 : count.frame.width + 4
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let cancel = (cell as? NSSearchFieldCell)?.cancelButtonRect(forBounds: bounds) ?? .zero
        let edge = cancel.isEmpty ? bounds.maxX - 8 : cancel.minX
        count.setFrameOrigin(NSPoint(x: edge - count.frame.width - 2, y: (bounds.height - count.frame.height) / 2))
    }
}
