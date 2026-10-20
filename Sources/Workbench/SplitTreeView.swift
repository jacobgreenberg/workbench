import AppKit

enum FocusDirection: Sendable { case left, right, up, down }

private final class DividerSplitView: NSSplitView {
    var color: NSColor = .separatorColor
    override var dividerColor: NSColor { color }
    override var dividerThickness: CGFloat { 1 }
}

/// Strip above each pane of a split tab, holding a glass pill with the pane's status dot and title; dragging the strip
/// or pill moves the pane (see SplitTreeView.drag). The glass sits in the strip, never over the terminal.
@MainActor private final class PaneHeader: NSView {
    static let height: CGFloat = 36
    private static let pillHeight: CGFloat = 24, inset: CGFloat = 10
    let id: PaneID
    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    let pill = NSGlassEffectView()
    private let row = NSStackView()
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint, _ done: Bool) -> Void)?   // window point; done = mouse released

    init(id: PaneID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = true
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
        row.setViews([dot, label], in: .leading)
        row.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSView()
        inner.addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            row.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
        ])
        pill.contentView = inner
        pill.cornerRadius = Self.pillHeight / 2
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pill hugs its content, up to the strip width minus the insets.
    override func layout() {
        super.layout()
        let w = min(row.fittingSize.width, max(0, bounds.width - 2 * Self.inset))
        pill.frame = NSRect(x: Self.inset, y: (bounds.height - Self.pillHeight) / 2, width: w, height: Self.pillHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        trackDrag(from: event, in: window) { [weak self] p, done in self?.onDrag?(p, done) }
    }
}

/// A pane's view with its header above it.
@MainActor private final class PaneFrame: NSView {
    let header: PaneHeader
    let content: NSView

    init(header: PaneHeader, content: NSView) {
        self.header = header
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = PaneHeader.height
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
    }
}

@MainActor final class SplitTreeView: NSView, NSSplitViewDelegate {
    var onRatiosChanged: ((SplitNode) -> Void)?
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    private var headers: [PaneID: PaneHeader] = [:]
    private let dropIndicator = NSView()
    private let provider: (PaneSpec) -> NSView
    private var root: SplitNode?
    private var paths: [ObjectIdentifier: [Bool]] = [:]
    private var splits: [(NSSplitView, Double)] = []
    private var rootView: NSView?
    private var isApplyingRatios = false
    private var dividerColor: NSColor?

    init(provider: @escaping (PaneSpec) -> NSView) {
        self.provider = provider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Rebuilds the split hierarchy; returns false (and does nothing) when the tree and colour are unchanged.
    @discardableResult func render(_ root: SplitNode, dividerColor: NSColor) -> Bool {
        if root == self.root, dividerColor == self.dividerColor, rootView != nil { return false }
        self.dividerColor = dividerColor
        isApplyingRatios = true
        defer { isApplyingRatios = false }
        subviews.forEach { $0.removeFromSuperview() }
        paths = [:]
        splits = []
        headers = [:]
        self.root = root
        let view = build(root, path: [], color: dividerColor)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
        rootView = view
        layoutSubtreeIfNeeded()
        applyRatios()
        return true
    }

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        paths = [:]
        headers = [:]
        splits = []
        root = nil
        rootView = nil
        dividerColor = nil
    }

    private func build(_ node: SplitNode, path: [Bool], color: NSColor) -> NSView {
        switch node {
        case .leaf(let spec):
            let v = provider(spec)
            v.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = [.width, .height]
            guard case .split = root else { return v }   // a lone pane has nothing to be dragged beside: no header
            let header = PaneHeader(id: spec.id)
            header.onClick = { [unowned self] in onHeaderClick?(spec.id) }
            header.onDrag = { [unowned self] point, done in drag(spec.id, to: point, done: done) }
            headers[spec.id] = header
            return PaneFrame(header: header, content: v)
        case .split(let axis, let ratio, let a, let b):
            let s = DividerSplitView()
            s.color = color
            s.isVertical = (axis == .horizontal)
            s.dividerStyle = .thin
            s.delegate = self
            paths[ObjectIdentifier(s)] = path
            splits.append((s, ratio))
            s.addArrangedSubview(build(a, path: path + [false], color: color))
            s.addArrangedSubview(build(b, path: path + [true], color: color))
            return s
        }
    }

    private func applyRatios() {
        let was = isApplyingRatios
        isApplyingRatios = true
        defer { isApplyingRatios = was }
        for (s, ratio) in splits {
            s.layoutSubtreeIfNeeded()
            let total = s.isVertical ? s.bounds.width : s.bounds.height
            s.setPosition(CGFloat(ratio) * total, ofDividerAt: 0)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // A window resize (often during a mouse drag) must not be recorded as a divider drag.
        let was = isApplyingRatios
        isApplyingRatios = true
        defer { isApplyingRatios = was }
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        rootView?.frame = bounds
        if changed, rootView != nil {
            layoutSubtreeIfNeeded()
            applyRatios()
        }
    }

    override func layout() {
        super.layout()
        rootView?.frame = bounds
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingRatios,
              let s = notification.object as? NSSplitView,
              let path = paths[ObjectIdentifier(s)],
              let root,
              let type = NSApp.currentEvent?.type,
              type == .leftMouseDragged || type == .leftMouseUp,
              let first = s.arrangedSubviews.first else { return }
        let total = s.isVertical ? s.bounds.width : s.bounds.height
        guard total > 0 else { return }
        let size = s.isVertical ? first.frame.width : first.frame.height
        let ratio = min(0.95, max(0.05, Double(size / total)))
        let newRoot = Self.setRatio(root, path: path[...], ratio)
        self.root = newRoot
        for i in splits.indices where splits[i].0 === s { splits[i].1 = ratio }
        onRatiosChanged?(newRoot)
    }

    private static func setRatio(_ node: SplitNode, path: ArraySlice<Bool>, _ ratio: Double) -> SplitNode {
        guard case .split(let axis, let r, let a, let b) = node else { return node }
        guard let step = path.first else { return .split(axis: axis, ratio: ratio, a: a, b: b) }
        let rest = path.dropFirst()
        return step
            ? .split(axis: axis, ratio: r, a: a, b: setRatio(b, path: rest, ratio))
            : .split(axis: axis, ratio: r, a: setRatio(a, path: rest, ratio), b: b)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + 60
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - 60
    }

    /// Header titles, status dots and colours; cheap to call on every title change (only differences are applied).
    func updateHeaders(focused: PaneID?, theme: Theme, status: (PaneID) -> PaneStatus, title: (PaneID) -> String) {
        for (id, h) in headers {
            let t = title(id), isFocused = id == focused
            if h.label.stringValue != t { h.label.stringValue = t; h.needsLayout = true }
            if h.dot.isHidden != (status(id) == .idle) { h.needsLayout = true }
            styleStatusDot(h.dot, status(id), theme: theme)
            h.label.textColor = isFocused ? .labelColor : .secondaryLabelColor
            h.pill.contentView?.wantsLayer = true
            h.pill.contentView?.layer?.cornerRadius = h.pill.cornerRadius
            h.pill.contentView?.layer?.backgroundColor = isFocused ? theme.color("foreground").withAlphaComponent(0.15).cgColor : nil
            h.pill.alphaValue = isFocused ? 1 : 0.8
            // The terminal's own background, not the tab bar's: the strip reads as part of its pane.
            h.layer?.backgroundColor = theme.color("background").cgColor
        }
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = theme.color("primary").withAlphaComponent(0.2).cgColor
        dropIndicator.layer?.borderColor = theme.color("primary").cgColor
        dropIndicator.layer?.borderWidth = 1
    }

    /// Header drag in progress (window point): shows where the pane would land; on release, moves it there.
    private func drag(_ id: PaneID, to point: NSPoint, done: Bool) {
        let target = dropTarget(at: convert(point, from: nil), excluding: id)
        if done {
            dropIndicator.removeFromSuperview()
            if let target { onMove?(id, target.pane, target.edge) }
        } else if let target {
            if dropIndicator.superview == nil { addSubview(dropIndicator) }
            dropIndicator.frame = target.area
        } else {
            dropIndicator.removeFromSuperview()
        }
    }

    /// The pane under `p` (tree coordinates) and its edge nearest to `p`, with the half it would give up.
    private func dropTarget(at p: NSPoint, excluding id: PaneID) -> (pane: PaneID, edge: FocusDirection, area: NSRect)? {
        for (pid, h) in headers where pid != id {
            guard let frame = h.superview else { continue }
            let r = convert(frame.bounds, from: frame)
            guard r.contains(p) else { continue }
            let x = (p.x - r.minX) / r.width
            let fromTop = isFlipped ? (p.y - r.minY) / r.height : (r.maxY - p.y) / r.height
            let edge = [(FocusDirection.left, x), (.right, 1 - x), (.up, fromTop), (.down, 1 - fromTop)].min { $0.1 < $1.1 }!.0
            let (top, bottom) = r.divided(atDistance: r.height / 2, from: isFlipped ? .minYEdge : .maxYEdge)
            let area: NSRect = switch edge {
            case .left: r.divided(atDistance: r.width / 2, from: .minXEdge).slice
            case .right: r.divided(atDistance: r.width / 2, from: .maxXEdge).slice
            case .up: top
            case .down: bottom
            }
            return (pid, edge, area)
        }
        return nil
    }

    func neighbor(of id: PaneID, _ direction: FocusDirection) -> PaneID? {
        guard let root else { return nil }
        let centers: [(PaneID, CGPoint)] = root.leaves.map { spec in
            let v = provider(spec)
            let r = convert(v.bounds, from: v)
            return (spec.id, CGPoint(x: r.midX, y: r.midY))
        }
        guard let me = centers.first(where: { $0.0 == id })?.1 else { return nil }
        var best: (PaneID, CGFloat, CGFloat)?
        for (pid, c) in centers where pid != id {
            let primary: CGFloat, perp: CGFloat
            switch direction {
            case .left: primary = me.x - c.x; perp = abs(c.y - me.y)
            case .right: primary = c.x - me.x; perp = abs(c.y - me.y)
            case .up: primary = c.y - me.y; perp = abs(c.x - me.x)
            case .down: primary = me.y - c.y; perp = abs(c.x - me.x)
            }
            guard primary > 0 else { continue }
            if best == nil || primary < best!.1 || (primary == best!.1 && perp < best!.2) {
                best = (pid, primary, perp)
            }
        }
        return best?.0
    }
}
