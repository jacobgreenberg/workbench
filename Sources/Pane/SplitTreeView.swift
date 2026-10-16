import AppKit

enum FocusDirection: Sendable { case left, right, up, down }

private final class DividerSplitView: NSSplitView {
    var color: NSColor = .separatorColor
    override var dividerColor: NSColor { color }
    override var dividerThickness: CGFloat { 1 }
}

@MainActor final class SplitTreeView: NSView, NSSplitViewDelegate {
    var onRatiosChanged: ((SplitNode) -> Void)?
    private let provider: (PaneSpec) -> NSView
    private var root: SplitNode?
    private var paths: [ObjectIdentifier: [Bool]] = [:]
    private var splits: [(NSSplitView, Double)] = []
    private var rootView: NSView?
    private var isApplyingRatios = false

    init(provider: @escaping (PaneSpec) -> NSView) {
        self.provider = provider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(_ root: SplitNode, dividerColor: NSColor) {
        isApplyingRatios = true
        defer { isApplyingRatios = false }
        subviews.forEach { $0.removeFromSuperview() }
        paths = [:]
        splits = []
        self.root = root
        let view = build(root, path: [], color: dividerColor)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
        rootView = view
        layoutSubtreeIfNeeded()
        applyRatios()
    }

    private func build(_ node: SplitNode, path: [Bool], color: NSColor) -> NSView {
        switch node {
        case .leaf(let spec):
            let v = provider(spec)
            v.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = [.width, .height]
            return v
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
