import AppKit

/// Tracks a press until release; past a 4 pt threshold it is a drag: the closed-hand cursor shows and `onDrag` gets each
/// window point (done = released). A press released before the threshold is a plain click and reports nothing.
@MainActor func trackDrag(from event: NSEvent, in window: NSWindow?, _ onDrag: @escaping (NSPoint, _ done: Bool) -> Void) {
    guard let window else { return }
    let start = event.locationInWindow
    var dragging = false
    window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { e, stop in
        guard let e else { return }
        let up = e.type == .leftMouseUp
        if up { stop.pointee = true }
        if !dragging, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 4 { return }
        if !dragging { dragging = true; NSCursor.closedHand.push() }
        onDrag(e.locationInWindow, up)
        if up { NSCursor.pop() }
    }
}

/// Pick up, drag and snap for a row or column of sibling views (tabs, sidebar projects). The dragged view follows the
/// pointer, lifted; the others slide aside to open the slot it would drop into; on release it snaps there. Everything
/// moves by layer transforms, so autolayout never runs mid-drag. Then `commit(from, to)` reorders for real, with
/// actions disabled and before the transforms reset, so nothing jumps.
@MainActor final class Reorder {
    enum Axis { case x, y }   // y: index grows with frame.minY (a flipped superview, like a table)
    private let axis: Axis
    private var slot: Int?

    init(_ axis: Axis) { self.axis = axis }

    private func lo(_ v: NSView) -> CGFloat { axis == .x ? v.frame.minX : v.frame.minY }
    private func hi(_ v: NSView) -> CGFloat { axis == .x ? v.frame.maxX : v.frame.maxY }
    private func mid(_ v: NSView) -> CGFloat { (lo(v) + hi(v)) / 2 }

    /// `offset`: pointer movement since the press along the axis, in the views' superview coordinates.
    func drag(_ views: [NSView], _ from: Int, by offset: CGFloat, done: Bool, commit: @escaping (Int, Int) -> Void) {
        guard views.indices.contains(from), let first = views.first, let last = views.last else { return }
        let b = views[from]
        let d = min(max(offset, lo(first) - lo(b)), hi(last) - hi(b))   // the view stays within the row
        let to = views.filter { $0 !== b && mid($0) < mid(b) + offset }.count   // the pointer, unclamped: the end slots stay reachable
        if to != slot {
            slot = to
            let gap = views.count > 1 ? lo(views[1]) - hi(views[0]) : 0
            let step = hi(b) - lo(b) + gap
            for (i, v) in views.enumerated() where v !== b {
                shift(v, i > from && i <= to ? -step : i < from && i >= to ? step : 0, animated: true)
            }
        }
        if !done { lift(b, true); shift(b, d, animated: false); return }
        slot = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lift(b, false)
            if to != from { commit(from, to) }
            views.forEach { shift($0, 0, animated: false) }
            CATransaction.commit()
        }
        shift(b, to > from ? hi(views[to]) - hi(b) : to < from ? lo(views[to]) - lo(b) : 0, animated: true)
        CATransaction.commit()
    }

    private func shift(_ v: NSView, _ d: CGFloat, animated: Bool) {
        guard let l = v.layer else { return }
        let t = axis == .x ? CATransform3DMakeTranslation(d, 0, 0) : CATransform3DMakeTranslation(0, d, 0)
        if animated {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = l.presentation()?.transform ?? l.transform
            a.duration = 0.16
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(a, forKey: "shift")
        } else {
            l.removeAnimation(forKey: "shift")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.transform = t
        CATransaction.commit()
    }

    private func lift(_ v: NSView, _ up: Bool) {
        guard let l = v.layer else { return }
        l.zPosition = up ? 1 : 0
        l.shadowOpacity = up ? 0.4 : 0
        l.shadowRadius = 8
        l.shadowOffset = CGSize(width: 0, height: -2)
    }
}
