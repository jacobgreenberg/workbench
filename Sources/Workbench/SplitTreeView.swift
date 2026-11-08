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
    /// Read Aloud for this pane and the shared speed, in a second capsule right of the pill (terminal panes only).
    let controls = NSGlassEffectView()
    let speakButton = HandButton(title: "", target: nil, action: nil)
    let speedButton = HandButton(title: "1×", target: nil, action: nil)
    private let controlRow = NSStackView()
    var speakSymbol = ""
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint, _ done: Bool) -> Void)?   // window point; done = mouse released
    var onSpeak: (() -> Void)?
    var onSpeed: (() -> Void)?

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

        for b in [speakButton, speedButton] {
            b.isBordered = false
            b.refusesFirstResponder = true
            b.target = self
            b.firstMouse = true
        }
        speakButton.action = #selector(speak)
        speakButton.imagePosition = .imageOnly
        speakButton.toolTip = "Read Aloud (⌥⌘S)"
        speedButton.action = #selector(speed)
        speedButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speedButton.toolTip = "Read Aloud speed"
        controlRow.spacing = 4
        controlRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        controlRow.setViews([speakButton, speedButton], in: .leading)
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        let controlInner = NSView()
        controlInner.addSubview(controlRow)
        NSLayoutConstraint.activate([
            controlRow.leadingAnchor.constraint(equalTo: controlInner.leadingAnchor),
            controlRow.trailingAnchor.constraint(equalTo: controlInner.trailingAnchor),
            controlRow.centerYAnchor.constraint(equalTo: controlInner.centerYAnchor),
        ])
        controls.contentView = controlInner
        controls.cornerRadius = Self.pillHeight / 2
        addSubview(controls)
    }

    @objc private func speak() { onSpeak?() }
    @objc private func speed() { onSpeed?() }

    required init?(coder: NSCoder) { fatalError() }

    /// The pill hugs its content, up to the strip width minus the insets.
    override func layout() {
        super.layout()
        let y = (bounds.height - Self.pillHeight) / 2, gap: CGFloat = 6
        let cw = controls.isHidden ? 0 : controlRow.fittingSize.width
        let w = min(row.fittingSize.width, max(0, bounds.width - 2 * Self.inset - (cw > 0 ? cw + gap : 0)))
        pill.frame = NSRect(x: Self.inset, y: y, width: w, height: Self.pillHeight)
        controls.frame = NSRect(x: pill.frame.maxX + gap, y: y, width: cw, height: Self.pillHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        return v is NSButton ? v : self   // the strip and pill drag; the Read Aloud buttons click
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        trackDrag(from: event, in: window) { [weak self] p, done in self?.onDrag?(p, done) }
    }
}

/// The dragged pane's title, lifted off its header: a glass capsule with a shadow, following the pointer.
@MainActor private final class DragGhost: NSView {
    private let glass = NSGlassEffectView()

    init(title: String, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = 14
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSView()
        inner.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
        ])
        glass.contentView = inner
        glass.cornerRadius = frame.height / 2
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lifted: a deep shadow; landed: none (call inside an animation group to ease it).
    func lift(_ up: Bool) {
        let a = CABasicAnimation(keyPath: "shadowOpacity")
        a.fromValue = layer?.presentation()?.shadowOpacity ?? layer?.shadowOpacity
        a.duration = NSAnimationContext.current.duration
        layer?.add(a, forKey: "lift")
        layer?.shadowOpacity = up ? 0.35 : 0
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

    /// Placed on every resize, not left to autoresizing: that would first stretch the pane by the frame's change (from
    /// zero when the tree is rebuilt) and hand its terminal that size.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let h = PaneHeader.height
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
    }
}

extension SplitNode {
    /// Divider ratios, depth-first with a split before its children: the order `SplitTreeView.build` creates its splits in.
    fileprivate var ratios: [Double] {
        guard case .split(_, let r, let a, let b) = self else { return [] }
        return [r] + a.ratios + b.ratios
    }

    /// Same splits (axes) and the same panes in the same places; ratios, cwds, launches and file paths may differ.
    fileprivate func sameArrangement(as other: SplitNode) -> Bool {
        switch (self, other) {
        case (.leaf(let x), .leaf(let y)): x.id == y.id
        case (.split(let ax, _, let a1, let b1), .split(let ay, _, let a2, let b2)):
            ax == ay && a1.sameArrangement(as: a2) && b1.sameArrangement(as: b2)
        default: false
        }
    }
}

@MainActor final class SplitTreeView: NSView, NSSplitViewDelegate {
    var onRatiosChanged: ((SplitNode) -> Void)?
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    var onSpeak: ((PaneID) -> Void)?   // a header's speaker button
    var onSpeed: (() -> Void)?         // a header's speed button (one speed for all panes)
    private var headers: [PaneID: PaneHeader] = [:]
    private let dropIndicator = NSView()
    private var dragGhost: DragGhost?
    private var dragGrab = NSPoint.zero   // pointer offset inside the ghost
    private let provider: (PaneSpec) -> NSView
    private var root: SplitNode?
    private var paths: [ObjectIdentifier: [Bool]] = [:]
    private var splits: [(NSSplitView, Double)] = []
    private var rootView: NSView?
    private var leafViews: [PaneID: NSView] = [:]   // the pane view each leaf had at the last build
    private var isApplyingRatios = false
    private var dividerColor: NSColor?

    init(provider: @escaping (PaneSpec) -> NSView) {
        self.provider = provider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Rebuilds the split hierarchy; returns false (without re-parenting anything) when the arrangement is unchanged: same
    /// splits, same panes in the same places and the same view for each. A pane's cwd or file path is not part of it, and
    /// divider ratios are moved in place.
    @discardableResult func render(_ root: SplitNode, dividerColor: NSColor) -> Bool {
        if let old = self.root, rootView != nil, dividerColor == self.dividerColor, old.sameArrangement(as: root),
           root.leaves.allSatisfy({ leafViews[$0.id] === provider($0) }) {
            self.root = root
            let ratios = root.ratios
            if ratios != splits.map(\.1) {
                for i in splits.indices { splits[i].1 = ratios[i] }
                applyRatios()
            }
            return false
        }
        self.dividerColor = dividerColor
        isApplyingRatios = true
        defer { isApplyingRatios = false }
        subviews.forEach { $0.removeFromSuperview() }
        paths = [:]
        splits = []
        headers = [:]
        leafViews = [:]
        self.root = root
        let view = build(root, path: [], color: dividerColor)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        rootView = view
        // Dividers placed before the tree joins the window: a pane sized there would hand its terminal the whole tree's size
        // first, and a fullscreen agent (alternate screen, no SIGWINCH at an unchanged pty) is left clipped.
        applyRatios()
        addSubview(view)
        return true
    }

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        paths = [:]
        headers = [:]
        leafViews = [:]
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
            leafViews[spec.id] = v
            let header = PaneHeader(id: spec.id)   // a lone pane too: it holds the Read Aloud controls
            header.onClick = { [unowned self] in onHeaderClick?(spec.id) }
            header.onSpeak = { [unowned self] in onSpeak?(spec.id) }
            header.onSpeed = { [unowned self] in onSpeed?() }
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
    #if DEBUG
    /// Test harness: a header button's centre in window coordinates (speed button, else speaker); nil = no such header.
    func headerButtonCenter(_ id: PaneID, speed: Bool) -> NSPoint? {
        guard let h = headers[id], !h.controls.isHidden else { return nil }
        let b = speed ? h.speedButton : h.speakButton
        return b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    }
    #endif

    /// `speech`: the speaker button's symbol, nil = no Read Aloud controls (file and web panes); `speed`: the speed button's title.
    func updateHeaders(focused: PaneID?, theme: Theme, status: (PaneID) -> PaneStatus, speech: (PaneID) -> String?, speed: String,
                       title: (PaneID) -> String) {
        for (id, h) in headers {
            let t = title(id), isFocused = id == focused
            let symbol = speech(id)
            if h.controls.isHidden != (symbol == nil) { h.controls.isHidden = symbol == nil; h.needsLayout = true }
            if let symbol, h.speakSymbol != symbol {
                h.speakSymbol = symbol
                h.speakButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "speaker.wave.2" ? "Read Aloud" : "Stop Reading")?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
                h.needsLayout = true
            }
            if h.speedButton.title != speed { h.speedButton.title = speed; h.needsLayout = true }
            h.controls.alphaValue = isFocused ? 1 : 0.8
            for b in [h.speakButton, h.speedButton] { b.contentTintColor = isFocused ? .labelColor : .secondaryLabelColor }
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
        dropIndicator.layer?.cornerRadius = 10
        dropIndicator.layer?.cornerCurve = .continuous
        dropIndicator.layer?.backgroundColor = theme.color("primary").withAlphaComponent(0.16).cgColor
        dropIndicator.layer?.borderColor = theme.color("primary").withAlphaComponent(0.9).cgColor
        dropIndicator.layer?.borderWidth = 1.5
    }

    /// Header drag in progress (window point): the pane's title lifts off as a glass capsule that follows the pointer, the
    /// pane dims, and the half it would take glides between targets; on release it moves there and the capsule flies to the
    /// pane's new header (or back home when dropped nowhere). All transient: render() may rebuild underneath, so the
    /// overlays are re-added on top each step.
    private func drag(_ id: PaneID, to point: NSPoint, done: Bool) {
        let p = convert(point, from: nil)
        let target = dropTarget(at: p, excluding: id)
        if dragGhost == nil, let h = headers[id] {
            let pill = convert(h.pill.frame, from: h)
            let ghost = DragGhost(title: h.label.stringValue, frame: pill)
            dragGhost = ghost
            dragGrab = NSPoint(x: p.x - pill.minX, y: p.y - pill.minY)
            addSubview(ghost)
            animate(0.18) { ghost.lift(true) }
        }
        let source = headers[id]?.superview
        if let ghost = dragGhost {
            if ghost.superview !== self { addSubview(ghost) }   // stay on top of the indicator and of any rebuild
            ghost.setFrameOrigin(NSPoint(x: p.x - dragGrab.x, y: p.y - dragGrab.y))
        }
        if !done {
            if source?.alphaValue == 1 { animate(0.18) { source?.animator().alphaValue = 0.45 } }
            showIndicator(target)
            return
        }
        let ghost = dragGhost
        dragGhost = nil
        if let target {
            onMove?(id, target.pane, target.edge)   // re-renders synchronously: the views are rebuilt
            let moved = headers[id]?.superview
            moved?.alphaValue = 0.45
            if let ghost, ghost.superview !== self { addSubview(ghost) }
            if dropIndicator.superview !== self { addSubview(dropIndicator, positioned: .below, relativeTo: ghost) }
            let home = headers[id].map { convert($0.pill.frame, from: $0) }
            let landed = moved.map { convert($0.bounds, from: $0) }
            animate(0.32) {
                moved?.animator().alphaValue = 1
                if let landed { dropIndicator.animator().frame = landed.insetBy(dx: 2, dy: 2) }
                dropIndicator.animator().alphaValue = 0
                if let home { ghost?.animator().frame = home }
                ghost?.lift(false)
                ghost?.animator().alphaValue = 0
            } done: { [weak self, weak ghost] in
                ghost?.removeFromSuperview()
                if let self, dropIndicator.alphaValue == 0 { dropIndicator.removeFromSuperview() }
            }
        } else {
            showIndicator(nil)
            let home = headers[id].map { convert($0.pill.frame, from: $0) }
            animate(0.28) {
                source?.animator().alphaValue = 1
                if let home { ghost?.animator().frame = home }
                ghost?.lift(false)
                ghost?.animator().alphaValue = 0
            } done: { [weak ghost] in ghost?.removeFromSuperview() }
        }
    }

    /// Glides the drop highlight to `target`'s half, growing out of the whole pane when it first appears; fades it when nil.
    private func showIndicator(_ target: (pane: PaneID, edge: FocusDirection, area: NSRect)?) {
        guard let target else {
            guard dropIndicator.superview != nil, dropIndicator.alphaValue > 0 else { return }
            animate(0.15) { dropIndicator.animator().alphaValue = 0 } done: { [weak self] in
                if let self, dropIndicator.alphaValue == 0 { dropIndicator.removeFromSuperview() }
            }
            return
        }
        let area = target.area.insetBy(dx: 6, dy: 6)
        if dropIndicator.superview !== self || dropIndicator.alphaValue == 0 {
            if dropIndicator.superview !== self { addSubview(dropIndicator, positioned: .below, relativeTo: dragGhost) }
            if let pane = headers[target.pane]?.superview { dropIndicator.frame = convert(pane.bounds, from: pane).insetBy(dx: 6, dy: 6) }
            dropIndicator.alphaValue = 0
        }
        guard dropIndicator.frame != area || dropIndicator.alphaValue == 0 else { return }
        animate(0.22) {
            dropIndicator.animator().frame = area
            dropIndicator.animator().alphaValue = 1
        }
    }

    private func animate(_ duration: TimeInterval, _ changes: () -> Void, done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)   // quick start, soft landing
            ctx.allowsImplicitAnimation = true
            changes()
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
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

#if DEBUG
/// Chrome self-checks (split tree, tab bar, sidebar); wired from main.swift's --selfcheck.
@MainActor func chromeSelfCheck() {
    splitTreeSelfCheck()
    tabBarSelfCheck()
    sidebarSelfCheck()
}

@MainActor func splitTreeSelfCheck() {
    let a = UUID(), b = UUID(), c = UUID()
    var views: [PaneID: NSView] = [a: NSView(), b: NSView(), c: NSView()]
    let tree = SplitTreeView { views[$0.id]! }
    tree.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let win = NSWindow(contentRect: tree.frame, styleMask: [.titled], backing: .buffered, defer: true)
    win.contentView?.addSubview(tree)
    func leaf(_ id: PaneID, _ cwd: String) -> SplitNode { .leaf(PaneSpec(id: id, kind: .terminal(cwd: cwd, launch: nil))) }
    func pair(_ ratio: Double, cwd: String, second: PaneID = b) -> SplitNode { .split(axis: .horizontal, ratio: ratio, a: leaf(a, cwd), b: leaf(second, "/")) }
    let color = NSColor.red
    assert(tree.render(pair(0.5, cwd: "/x"), dividerColor: color))
    let frameA = views[a]!.superview, frameB = views[b]!.superview
    assert(frameA is NSView && frameA !== tree && frameB !== frameA)
    assert(!tree.render(pair(0.5, cwd: "/x"), dividerColor: color))
    assert(!tree.render(pair(0.5, cwd: "/elsewhere"), dividerColor: color))   // a cd changes nothing on screen
    assert(views[a]!.superview === frameA && views[b]!.superview === frameB)   // nobody was re-parented
    assert(!tree.render(pair(0.25, cwd: "/elsewhere"), dividerColor: color))   // ratios move in place
    assert(views[a]!.superview === frameA)
    assert(abs(frameA!.frame.width - 200) < 2, "ratio applied in place: \(frameA!.frame.width)")
    assert(tree.render(pair(0.25, cwd: "/elsewhere"), dividerColor: .blue))   // divider colour change rebuilds
    assert(tree.render(pair(0.25, cwd: "/elsewhere", second: c), dividerColor: .blue))   // another pane
    views[a] = NSView()
    assert(tree.render(pair(0.25, cwd: "/elsewhere", second: c), dividerColor: .blue))   // a different view for a leaf
    assert(views[a]!.superview != nil)
    tree.clear()
}
#endif
