import AppKit

/// `image` is an absolute path (already cropped and downscaled), `emoji` a single character; the icon is the image,
/// else the emoji on a tint, else a monogram. `status` is the busiest pane of the workspace's projects.
struct WorkspaceItem: Equatable, Sendable {
    let id: UUID; let name: String; let image: String?; let emoji: String?; let color: Int?; let status: PaneStatus
}

/// A workspace's monogram: a short all-caps word as is (KWI), else the first letters of the first two words
/// (Side Projects → SP), else the first letter (Personal → P).
func monogram(_ name: String) -> String {
    let words = name.split { !$0.isLetter && !$0.isNumber }
    guard let first = words.first else { return "?" }
    if words.count == 1, first.count <= 3, first == first.uppercased() { return String(first) }
    return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
}

/// The workspace palette: a name and a top/bottom gradient pair. A workspace without a chosen color takes one from its
/// id, stable across launches.
private let tints: [(name: String, top: NSColor, bottom: NSColor)] = [
    ("Blue", NSColor(srgbRed: 0.43, green: 0.61, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.24, green: 0.39, blue: 0.79, alpha: 1)),
    ("Teal", NSColor(srgbRed: 0.18, green: 0.83, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.06, green: 0.46, blue: 0.43, alpha: 1)),
    ("Purple", NSColor(srgbRed: 0.78, green: 0.57, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.49, green: 0.34, blue: 0.76, alpha: 1)),
    ("Orange", NSColor(srgbRed: 0.94, green: 0.64, blue: 0.37, alpha: 1), NSColor(srgbRed: 0.77, green: 0.40, blue: 0.23, alpha: 1)),
    ("Pink", NSColor(srgbRed: 0.97, green: 0.47, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.75, green: 0.22, blue: 0.33, alpha: 1)),
    ("Green", NSColor(srgbRed: 0.76, green: 0.91, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.36, green: 0.60, blue: 0.27, alpha: 1)),
]

@MainActor private final class WorkspaceIcon: NSView {
    static let size: CGFloat = 40
    let tile = CAGradientLayer()
    let picture = CALayer()
    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    var onClick: (() -> Void)?
    var item: WorkspaceItem?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        tile.cornerRadius = 12
        tile.cornerCurve = .continuous
        tile.masksToBounds = true
        tile.startPoint = CGPoint(x: 0.2, y: 1)
        tile.endPoint = CGPoint(x: 0.8, y: 0)
        picture.contentsGravity = .resizeAspectFill
        tile.addSublayer(picture)
        layer?.addSublayer(tile)
        label.alignment = .center
        label.textColor = .white
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        for v in [label, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            dot.centerYAnchor.constraint(equalTo: topAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tile.frame = bounds
        picture.frame = bounds
    }

    func show(_ w: WorkspaceItem, theme: Theme) {
        if w.image != item?.image {   // decode the file only when it changes
            picture.contents = w.image.flatMap { NSImage(contentsOfFile: $0) }
        }
        item = w
        toolTip = w.name
        setAccessibilityLabel(w.name)
        let (_, top, bottom) = tints[abs(w.color ?? Int(w.id.uuid.0)) % tints.count]
        let alpha: CGFloat = w.emoji == nil ? 1 : 0.28   // an emoji sits on a soft tint of the color
        tile.colors = [top.withAlphaComponent(alpha).cgColor, bottom.withAlphaComponent(alpha).cgColor]
        picture.isHidden = w.image == nil
        label.isHidden = w.image != nil
        if let e = w.emoji {
            label.stringValue = e
            label.font = .systemFont(ofSize: 22)
        } else {
            let m = monogram(w.name)
            label.stringValue = m
            let base = NSFont.systemFont(ofSize: [17, 17, 15, 12.5][min(m.count, 3)], weight: .bold)
            label.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 0) } ?? base
        }
        styleStatusDot(dot, w.status, theme: theme)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The sidebar's leading rail of workspaces, Slack-style: one icon each (selected one marked by a bar at the rail's
/// edge), a status badge for the busiest pane inside, then a New Workspace button. Right-click an icon to rename it,
/// give it an emoji or image, or delete it.
@MainActor final class WorkspaceRail: NSView, NSMenuDelegate {
    var onSelect: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((Int) -> Void)?
    var onChooseEmoji: ((Int) -> Void)?
    var onChooseImage: ((Int) -> Void)?
    var onChooseColor: ((Int, Int) -> Void)?   // workspace index, palette index
    var onClearIcon: ((Int) -> Void)?   // back to the monogram
    var onDelete: ((Int) -> Void)?

    static let width: CGFloat = 60
    private let stack = NSStackView()
    private let marker = NSView()
    private var markerY: NSLayoutConstraint?
    private var icons: [WorkspaceIcon] = []
    private var items: [WorkspaceItem] = []
    private var selected = -1
    private var menuTarget = -1
    private var themeID = ""

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Darker strip; a light sidebar needs far less to read as one, or it turns muddy grey.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.16 : 0.05).cgColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        viewDidChangeEffectiveAppearance()
        stack.orientation = .vertical
        stack.spacing = 12
        let add = HandButton.glass("plus", "New Workspace")
        add.target = self
        add.action = #selector(newTapped)
        add.toolTip = "New Workspace"
        stack.addArrangedSubview(add)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 2
        marker.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        for v in [stack, marker] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 4),
            marker.heightAnchor.constraint(equalToConstant: 22),
        ])
        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTapped() { onNew?() }

    func update(_ items: [WorkspaceItem], selected: Int, theme: Theme) {
        guard items != self.items || selected != self.selected || theme.id != themeID else { return }
        self.items = items
        self.selected = selected
        themeID = theme.id
        while icons.count < items.count {
            let icon = WorkspaceIcon()
            let i = icons.count
            icon.onClick = { [unowned self] in onSelect?(i) }
            stack.insertArrangedSubview(icon, at: i)
            icons.append(icon)
        }
        while icons.count > items.count { icons.removeLast().removeFromSuperview() }
        for (icon, w) in zip(icons, items) { icon.show(w, theme: theme) }
        marker.layer?.backgroundColor = NSColor.labelColor.cgColor
        markerY?.isActive = false
        marker.isHidden = !icons.indices.contains(selected)
        if !marker.isHidden {
            markerY = marker.centerYAnchor.constraint(equalTo: icons[selected].centerYAnchor)
            markerY?.isActive = true
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menuTarget = icons.firstIndex { $0.frame.insetBy(dx: -6, dy: -6).contains(stack.convert(p, from: self)) } ?? -1
        guard items.indices.contains(menuTarget) else {
            menu.addItem(NSMenuItem(title: "New Workspace…", action: #selector(newTapped), keyEquivalent: ""))
            menu.items.forEach { $0.target = self }
            return
        }
        let w = items[menuTarget]
        menu.addItem(NSMenuItem(title: "Rename…", action: #selector(renameTapped), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Emoji…", action: #selector(emojiTapped), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Image…", action: #selector(imageTapped), keyEquivalent: ""))
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let current = abs(w.color ?? Int(w.id.uuid.0)) % tints.count
        for (n, t) in tints.enumerated() {
            let c = NSMenuItem(title: t.name, action: #selector(colorTapped(_:)), keyEquivalent: "")
            c.tag = n
            c.target = self
            c.state = n == current ? .on : .off
            c.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                t.top.setFill()
                NSBezierPath(ovalIn: r).fill()
                return true
            }
            colorMenu.addItem(c)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        if w.image != nil || w.emoji != nil {
            menu.addItem(NSMenuItem(title: "Use Monogram", action: #selector(clearTapped), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Workspace…", action: items.count > 1 ? #selector(deleteTapped) : nil, keyEquivalent: "")
        menu.addItem(delete)
        menu.items.forEach { $0.target = self }
    }

    @objc private func renameTapped() { onRename?(menuTarget) }
    @objc private func emojiTapped() { onChooseEmoji?(menuTarget) }
    @objc private func imageTapped() { onChooseImage?(menuTarget) }
    @objc private func colorTapped(_ sender: NSMenuItem) { onChooseColor?(menuTarget, sender.tag) }
    @objc private func clearTapped() { onClearIcon?(menuTarget) }
    @objc private func deleteTapped() { onDelete?(menuTarget) }
}

/// The chosen picture as a workspace icon: center-cropped to a square and downscaled to `px` pixels, PNG. A
/// multi-megabyte photo becomes a few kilobytes and the rail never decodes the original again.
func workspaceIconPNG(_ url: URL, px: Int = 128) -> Data? {
    guard let data = readFile(url, cap: 64 << 20), let src = NSImage(data: data), src.size.width > 0, src.size.height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    let side = CGFloat(px), s = src.size, scale = max(side / s.width, side / s.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: NSRect(x: (side - s.width * scale) / 2, y: (side - s.height * scale) / 2, width: s.width * scale, height: s.height * scale),
             from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
