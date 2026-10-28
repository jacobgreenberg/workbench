import AppKit
import Markdown
import Synchronization

private struct RGBA: Sendable {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        r = s.redComponent; g = s.greenComponent; b = s.blueComponent; a = s.alphaComponent
    }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

private struct Palette: Sendable {
    let body, heading, codeBackground, link, inlineCode, muted, border, background: RGBA
    let syntax: [(prefix: String, color: RGBA)]
    init(_ t: Theme) {
        body = RGBA(t.color("foreground")); heading = RGBA(t.color("cardForeground"))
        codeBackground = RGBA(t.color("popover")); link = RGBA(t.color("primary"))
        inlineCode = RGBA(t.color("chart4")); muted = RGBA(t.color("mutedForeground"))
        border = RGBA(t.color("border")); background = RGBA(t.color("background"))
        // Capture names → the theme's ANSI palette, so code reads like agents' diffs in the terminal. First match wins,
        // so more specific prefixes come first.
        syntax = [
            ("comment", "brightBlack"), ("string.escape", "cyan"), ("string.regex", "cyan"), ("string.special", "cyan"),
            ("escape", "cyan"), ("string", "green"), ("character", "green"), ("keyword", "magenta"),
            ("conditional", "magenta"), ("repeat", "magenta"), ("include", "magenta"), ("import", "magenta"),
            ("exception", "magenta"), ("preproc", "magenta"), ("function", "blue"), ("method", "blue"),
            ("constructor", "yellow"), ("type", "yellow"), ("module", "yellow"), ("namespace", "yellow"),
            ("attribute", "yellow"), ("tag", "red"), ("number", "red"), ("float", "red"), ("boolean", "red"),
            ("constant", "red"), ("variable.builtin", "red"), ("label", "cyan"), ("property", "cyan"),
            ("field", "cyan"), ("operator", "cyan"), ("punctuation", "white"),
        ].map { ($0.0, RGBA(t.terminalColor($0.1))) }
    }

    func color(capture: String) -> RGBA? {
        syntax.first { capture == $0.prefix || capture.hasPrefix($0.prefix + ".") }?.color
    }
}

/// Colors `text` (already in `out` at `offset`) by its tree-sitter highlights; later, more specific captures win.
private func highlight(_ out: NSMutableAttributedString, at offset: Int, _ text: String, key: String, _ p: Palette) {
    guard text.utf16.count <= 2 << 20, let spans = Syntax.highlights(text, key: key) else { return }   // ponytail: big files stay plain
    var colors: [String: NSColor?] = [:]   // a file has thousands of spans but a few dozen distinct capture names
    for s in spans {
        let c: NSColor?
        if let hit = colors[s.name] { c = hit } else { c = p.color(capture: s.name)?.ns; colors[s.name] = c }
        guard let c, NSMaxRange(s.range) <= text.utf16.count else { continue }
        out.addAttribute(.foregroundColor, value: c, range: NSRange(location: offset + s.range.location, length: s.range.length))
    }
}

private struct Renderer: Sendable {
    let text: String
    let path: String
    let palette: Palette
    let zoom: CGFloat

    /// Markdown is previewed; anything else is shown as code, highlighted when its language is known.
    func render() -> NSAttributedString {
        let url = URL(fileURLWithPath: path)
        guard !["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            var w = Walker(palette: palette, baseDir: url.deletingLastPathComponent(), z: zoom)
            w.visit(Document(parsing: text))
            return w.out
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5 * zoom, weight: .regular),
            .foregroundColor: palette.body.ns,
            .paragraphStyle: style,
        ])
        if let key = Syntax.key(for: path) { highlight(out, at: 0, text, key: key, palette) }
        return out
    }

    struct Walker: MarkupWalker {
        let out = NSMutableAttributedString()
        let p: Palette
        let baseDir: URL
        let z: CGFloat   // zoom: every font size and indent scales by it
        var heading = 0, bold = false, italic = false, strike = false
        var quote = 0, listDepth = 0
        var link: URL?

        init(palette: Palette, baseDir: URL, z: CGFloat) { p = palette; self.baseDir = baseDir; self.z = z }

        func font(size: CGFloat? = nil) -> NSFont {
            let sizes: [CGFloat] = [14, 26, 22, 18, 16, 14, 14]
            var f = NSFont.systemFont(ofSize: (size ?? sizes[heading]) * z, weight: heading > 0 || bold ? .bold : .regular)
            if italic { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: 0) ?? f }   // NSFontManager is main-thread only
            return f
        }

        func style(indent: CGFloat = 0, centered: Bool = false) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.lineSpacing = 4; s.paragraphSpacing = 10
            if heading > 0 { s.paragraphSpacingBefore = 14 }
            let level = (CGFloat(listDepth) * 20 + CGFloat(quote) * 16 + indent) * z
            s.headIndent = level
            s.firstLineHeadIndent = listDepth > 0 ? level - 20 * z : level
            if listDepth > 0 { s.tabStops = [NSTextTab(textAlignment: .left, location: level)] }
            if centered { s.alignment = .center }
            return s
        }

        func attrs() -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [
                .font: font(),
                .foregroundColor: (heading > 0 ? p.heading : quote > 0 ? p.muted : p.body).ns,
                .paragraphStyle: style(),
            ]
            if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link { a[.link] = link; a[.foregroundColor] = p.link.ns }
            return a
        }

        func add(_ s: String, _ a: [NSAttributedString.Key: Any]? = nil) {
            out.append(NSAttributedString(string: s, attributes: a ?? attrs()))
        }

        mutating func visitText(_ text: Text) { add(text.string) }
        mutating func visitSoftBreak(_ softBreak: SoftBreak) { add(" ") }
        mutating func visitLineBreak(_ lineBreak: LineBreak) { add("\n") }
        mutating func visitParagraph(_ paragraph: Paragraph) { descendInto(paragraph); add("\n") }
        mutating func visitHeading(_ h: Heading) { heading = h.level; descendInto(h); heading = 0; add("\n") }
        mutating func visitStrong(_ m: Strong) { let o = bold; bold = true; descendInto(m); bold = o }
        mutating func visitEmphasis(_ m: Emphasis) { let o = italic; italic = true; descendInto(m); italic = o }
        mutating func visitStrikethrough(_ m: Strikethrough) { let o = strike; strike = true; descendInto(m); strike = o }
        mutating func visitBlockQuote(_ q: BlockQuote) { quote += 1; descendInto(q); quote -= 1 }

        mutating func visitInlineCode(_ c: InlineCode) {
            var a = attrs()
            a[.font] = NSFont.monospacedSystemFont(ofSize: 13 * z, weight: .regular)
            a[.foregroundColor] = p.inlineCode.ns
            a[.backgroundColor] = p.codeBackground.ns
            add(c.code, a)
        }

        mutating func visitCodeBlock(_ c: CodeBlock) {
            let s = NSMutableParagraphStyle()
            s.lineSpacing = 2; s.paragraphSpacing = 0
            s.headIndent = 12 * z; s.firstLineHeadIndent = 12 * z; s.tailIndent = -12 * z
            let code = c.code.trimmingCharacters(in: .newlines)
            let start = out.length
            add(code + "\n", [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5 * z, weight: .regular),
                .foregroundColor: p.body.ns,
                .backgroundColor: p.codeBackground.ns,
                .paragraphStyle: s,
            ])
            if let key = c.language.flatMap(Syntax.key(fence:)) { highlight(out, at: start, code, key: key, p) }
            add("\n", [.font: NSFont.systemFont(ofSize: 6 * z)])
        }

        mutating func visitLink(_ l: Markdown.Link) {
            let o = link
            if let d = l.destination, let u = URL(string: d, relativeTo: baseDir)?.absoluteURL { link = u }
            descendInto(l)
            link = o
        }

        mutating func visitImage(_ i: Markdown.Image) {
            var a = attrs()
            a[.foregroundColor] = p.muted.ns
            add(i.plainText, a)
        }

        mutating func visitUnorderedList(_ l: UnorderedList) {
            listDepth += 1
            for item in l.listItems { add("•\t"); descendInto(item) }
            listDepth -= 1
        }

        mutating func visitOrderedList(_ l: OrderedList) {
            listDepth += 1
            for (i, item) in l.listItems.enumerated() { add("\(Int(l.startIndex) + i).\t"); descendInto(item) }
            listDepth -= 1
        }

        mutating func visitThematicBreak(_ t: ThematicBreak) {
            var a = attrs()
            a[.foregroundColor] = p.muted.ns
            a[.paragraphStyle] = style(centered: true)
            add("———\n", a)
        }

        mutating func visitTable(_ t: Markdown.Table) {
            let mono = NSFont.monospacedSystemFont(ofSize: 12.5 * z, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: 12.5 * z, weight: .bold)
            func row(_ cells: [String], _ f: NSFont) {
                var a = attrs()
                a[.font] = f
                add(cells.joined(separator: "\t│\t") + "\n", a)
            }
            row(t.head.cells.map { $0.plainText }, bold)
            for r in t.body.rows { row(r.cells.map { $0.plainText }, mono) }
        }
    }
}

/// Reports first-responder status, so clicking into a file pane focuses it like a terminal.
private final class FocusTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

@MainActor final class FilePaneView: NSView, NSTextViewDelegate {
    let paneID: PaneID
    private var path: String
    private var palette: Palette
    fileprivate let scrollView = NSScrollView()   // fileprivate: the self-check scrolls it
    private let textView = FocusTextView(usingTextLayoutManager: true)
    private(set) var generation = 0
    private var stale = false   // a render was skipped while hidden; the next window attach renders
    /// Newest requested generation, readable off main: queued renders that are already stale skip the read and parse.
    private final class Latest: Sendable { let value = Atomic<Int>(0) }
    private let latest = Latest()
    private var closed = false
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileInode: ino_t = 0
    private var pending: DispatchWorkItem?
    var onOpenLink: ((URL) -> Void)?
    var onFocus: ((PaneID) -> Void)?
    var onZoom: ((CGFloat) -> Void)?   // the user changed this pane's zoom
    private(set) var zoom: CGFloat
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3
    private let zoomBar = ZoomBar()
    private var scrollScale: CGFloat = 1   // the next render restores the scroll offset scaled by this (zoom changed)
    private var renderInFlight = false   // the newest reload's render has not landed: a file change never supersedes it, it marks `dirty` instead
    private var dirty = false             // the file changed while a render was in flight; one more reload when it lands
    /// Shared by every pane: at most one render in flight, and a superseded pane (or one whose file was swapped under it) skips its read and parse.
    private static let renderQueue = DispatchQueue(label: "pane.file", qos: .userInitiated)

    init(id: PaneID, path: String, theme: Theme, zoom: CGFloat = 1) {
        paneID = id
        self.path = path
        palette = Palette(theme)
        self.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        super.init(frame: .zero)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false   // the pane behind it shows through
        textView.drawsBackground = false
        textView.isEditable = false
        textView.delegate = self
        textView.onFocus = { [unowned self] in onFocus?(paneID) }
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        addSubview(scrollView)
        zoomBar.onStep = { [unowned self] in setZoom($0 == 0 ? 1 : self.zoom + 0.1 * CGFloat($0)) }
        zoomBar.set(self.zoom)
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomBar)
        NSLayoutConstraint.activate([
            zoomBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            zoomBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),   // clear of the scroller
        ])
        apply(theme: theme)
    }

    /// Clamped to zoomRange and rounded to 10% steps; re-renders only on a change.
    func setZoom(_ z: CGFloat) {
        let z = (min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) * 10).rounded() / 10
        guard z != zoom else { return }
        scrollScale *= z / zoom
        zoom = z
        zoomBar.set(z)
        onZoom?(z)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(textView) ?? false }

    func apply(theme: Theme) {
        palette = Palette(theme)
        textView.linkTextAttributes = [.foregroundColor: theme.color("primary")]
        reload()
    }

    /// Shows another file in this same view: scroll and selection start over, zoom stays, the watch moves to the new file.
    func retarget(path newPath: String) {
        guard newPath != path else { return }
        path = newPath
        pending?.cancel(); pending = nil
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
        textView.selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
        scrollView.contentView.scroll(to: .zero)   // now, not in a render: a reload that supersedes this one must not bring back the old file's offset
        scrollView.reflectScrolledClipView(scrollView.contentView)
        reload()
    }

    var shownText: String { textView.string }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { onOpenLink?(url) }
        return true
    }

    func close() {
        closed = true
        latest.value.store(-1, ordering: .relaxed)   // queued renders for this pane exit before any work
        pending?.cancel(); pending = nil
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && stale && !closed { stale = false; reload() }
    }

    private func reload() {
        guard window != nil else { stale = true; return }   // hidden panes leave the window: don't read or parse until shown
        generation += 1
        renderInFlight = true; dirty = false   // this render reads the file afresh; older renders are superseded and never land
        latest.value.store(generation, ordering: .relaxed)
        let gen = generation, path = path, palette = palette, latest = latest, zoom = zoom, scale = scrollScale
        scrollScale = 1
        Self.renderQueue.async { [weak self] in
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let text = Self.load(path)
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let result = Renderer(text: text, path: path, palette: palette, zoom: zoom).render()
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, !self.closed else { return }
                    self.renderInFlight = false
                    let clip = self.scrollView.contentView
                    let origin = NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y * scale)   // text height scales with zoom
                    let ranges = self.textView.selectedRanges
                    Self.replace(self.textView.textStorage!, with: result)
                    let len = result.length
                    self.textView.selectedRanges = ranges.map { v in
                        let r = v.rangeValue
                        let l = min(r.location, len)
                        return NSValue(range: NSRange(location: l, length: min(r.length, len - l)))
                    }
                    // Restoring a scroll offset needs the document laid out that far; at the top (the common case)
                    // TextKit lays out lazily instead of the whole file on main.
                    if origin.y > 0 { self.textView.layoutSubtreeIfNeeded() }
                    clip.scroll(to: origin)
                    self.scrollView.reflectScrolledClipView(clip)
                    if self.dirty { self.changed() }
                }
            }
        }
        rewatchFileIfNeeded()
    }

    /// Swapping a full storage for another is quadratic in attribute runs; emptying it first in the same edit is not (and does not flash).
    static func replace(_ storage: NSTextStorage, with text: NSAttributedString) {
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString())
        storage.setAttributedString(text)
        storage.endEditing()
    }

    /// Regular files only (a FIFO or device would block or never end), read once up to the preview cap.
    nonisolated static func load(_ path: String) -> String {
        readFile(URL(fileURLWithPath: path), cap: 10 << 20).map { String(decoding: $0, as: UTF8.self) }
            ?? "Cannot preview \(path): unreadable, not a regular file, or over 10 MB"
    }

    private func makeSource(_ target: String) -> DispatchSourceFileSystemObject? {
        let fd = open(target, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        s.setCancelHandler { Darwin.close(fd) }
        s.resume()
        return s
    }

    private func inode() -> ino_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : 0
    }

    private func rewatchFileIfNeeded() {
        let ino = inode()
        if fileSource == nil || ino != fileInode {
            fileSource?.cancel()
            fileSource = makeSource(path)
            fileInode = ino
        }
        // Watch the directory only while the file is missing, to catch it reappearing; otherwise sibling
        // saves would wake and reparse every preview in that folder.
        if fileSource == nil {
            if dirSource == nil { dirSource = makeSource(URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        } else {
            dirSource?.cancel(); dirSource = nil
        }
    }

    /// A file change never supersedes a render that is running (a file written continuously, or a render slower than the
    /// throttle, would then never land): it waits for that render, then reloads. Otherwise at most one reload per 100 ms.
    private func changed() {
        guard !closed else { return }
        if renderInFlight { dirty = true; return }
        guard pending == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                if self.renderInFlight { self.dirty = true } else { self.reload() }   // an explicit reload started meanwhile
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
    }
}

/// The preview's own zoom controls: a glass capsule with −, the percentage (click resets) and +.
@MainActor private final class ZoomBar: NSView {
    var onStep: ((Int) -> Void)?   // -1 out, +1 in, 0 reset
    private let percent = HandButton(title: "100%", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let out = HandButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Zoom Out")!, target: self, action: #selector(zoomOut))
        let into = HandButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Zoom In")!, target: self, action: #selector(zoomIn))
        percent.target = self
        percent.action = #selector(reset)
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percent.toolTip = "Actual Size"
        for b in [out, percent, into] {
            b.isBordered = false
            b.refusesFirstResponder = true
            b.contentTintColor = .secondaryLabelColor
        }
        out.toolTip = "Zoom Out"; into.toolTip = "Zoom In"
        let stack = NSStackView(views: [out, percent, into])
        stack.spacing = 0   // the buttons tile the capsule: the whole bar is clickable, not just the glyphs
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            out.widthAnchor.constraint(equalToConstant: 28), into.widthAnchor.constraint(equalToConstant: 28),
            percent.widthAnchor.constraint(equalToConstant: 44),
        ] + [out, percent, into].map { $0.heightAnchor.constraint(equalTo: heightAnchor) })
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ zoom: CGFloat) { percent.title = "\(Int((zoom * 100).rounded()))%" }

    @objc private func zoomOut() { onStep?(-1) }
    @objc private func zoomIn() { onStep?(1) }
    @objc private func reset() { onStep?(0) }
}

@MainActor func filePaneSelfCheck() {
    let sniff = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: sniff, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sniff) }
    try! Data("KEY=value\n".utf8).write(to: sniff.appendingPathComponent(".env"))
    try! Data([0x89, 0x50, 0x00, 0x01]).write(to: sniff.appendingPathComponent("blob"))
    assert(WorkspaceController.looksLikeText(sniff.appendingPathComponent(".env")))
    assert(!WorkspaceController.looksLikeText(sniff.appendingPathComponent("blob")))
    mkfifo(sniff.appendingPathComponent("fifo").path, 0o600)
    assert(!WorkspaceController.looksLikeText(sniff.appendingPathComponent("fifo")))   // returns, doesn't block
    let dir = FileManager.default.temporaryDirectory
    let good = dir.appendingPathComponent("\(UUID().uuidString).swift")
    try? "let a = 1\n".write(to: good, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: good) }
    let pane = FilePaneView(id: UUID(), path: good.path, theme: Theme.all().first!)
    assert(pane.generation == 0)   // windowless: nothing rendered
    pane.apply(theme: Theme.all().first!)
    assert(pane.generation == 0)
    let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    win.contentView?.addSubview(pane)
    assert(pane.generation == 1)   // shown: exactly one render
    pane.setZoom(1.04)
    assert(pane.zoom == 1 && pane.generation == 1)   // rounds to the same 10% step: no re-render
    pane.setZoom(9)
    assert(pane.zoom == 3 && pane.generation == 2)   // clamped, rendered once
    let small = Renderer(text: "# T\n\nbody `c`", path: "a.md", palette: Palette(Theme.all().first!), zoom: 1).render()
    let big = Renderer(text: "# T\n\nbody `c`", path: "a.md", palette: Palette(Theme.all().first!), zoom: 2).render()
    let size = { (s: NSAttributedString, i: Int) in (s.attribute(.font, at: i, effectiveRange: nil) as! NSFont).pointSize }
    assert(size(big, 0) == 2 * size(small, 0) && size(big, big.length - 2) == 2 * size(small, small.length - 2))   // heading and inline code scale
    pane.removeFromSuperview()
    pane.close()

    // Spins the main run loop so renders and file events land, as in the app.
    func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    let theme = Theme.all().first!
    let one = dir.appendingPathComponent("\(UUID().uuidString).txt"), two = dir.appendingPathComponent("\(UUID().uuidString).txt")
    try? "first file\n".write(to: one, atomically: true, encoding: .utf8)
    try? "second file\n".write(to: two, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
    let live = FilePaneView(id: UUID(), path: one.path, theme: theme, zoom: 1.5)
    let host = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    host.contentView?.addSubview(live)
    spin(5) { live.shownText == "first file\n" }
    assert(live.shownText == "first file\n")
    // retarget: same view, new file, zoom kept, and the new file is the one watched
    let g = live.generation
    live.retarget(path: two.path)
    assert(live.generation == g + 1 && live.zoom == 1.5)
    spin(5) { live.shownText == "second file\n" }
    assert(live.shownText == "second file\n")
    try? "edited\n".write(to: two, atomically: false, encoding: .utf8)
    spin(5) { live.shownText == "edited\n" }
    assert(live.shownText == "edited\n")
    let unwatched = live.generation
    try? "old file changed\n".write(to: one, atomically: false, encoding: .utf8)
    spin(0.5)
    assert(live.generation == unwatched)   // the old file is no longer watched: a reload from its watcher would bump the generation
    // throttle: a file written more often than the debounce delay still refreshes while the writer is going
    let before = live.generation
    let handle = try! FileHandle(forWritingTo: two)
    for i in 0..<15 {
        handle.write(Data("line \(i)\n".utf8))
        spin(0.03)
    }
    assert(live.generation >= before + 2)
    try? handle.close()
    spin(5) { live.shownText.hasSuffix("line 14\n") }
    assert(live.shownText.hasSuffix("line 14\n"))
    live.close()
    host.contentView?.subviews.forEach { $0.removeFromSuperview() }

    // starvation: a file that grows into renders slower than the throttle, written continuously, must still show renders while
    // it is written (a change that superseded the running render would leave the old text on screen until the writer stopped)
    let slow = dir.appendingPathComponent("\(UUID().uuidString).swift")
    let body = String((0..<20_000).map { "let value\($0) = \($0) + 42 // comment\n" }.joined())
    let t1 = Date()
    _ = Renderer(text: body, path: slow.path, palette: Palette(theme), zoom: 1).render()
    let renderTime = Date().timeIntervalSince(t1)
    assert(renderTime > 0.15, "the starvation check needs renders slower than the 100 ms throttle: \(renderTime) s")
    try? "let small = 1\n".write(to: slow, atomically: true, encoding: .utf8)   // renders fast: the throttle stays at 100 ms
    defer { try? FileManager.default.removeItem(at: slow) }
    let busy = FilePaneView(id: UUID(), path: slow.path, theme: theme)
    host.contentView?.addSubview(busy)
    spin(10) { busy.shownText == "let small = 1\n" }
    assert(busy.shownText == "let small = 1\n")
    let writer = try! FileHandle(forWritingTo: slow)
    try? writer.truncate(atOffset: 0)
    writer.write(Data(body.utf8))
    var seen = Set([busy.shownText.utf16.count]), written = body.utf16.count
    for i in 0..<Int((renderTime * 8 / 0.02).rounded(.up)) {   // keeps writing for ~8 renders
        let line = "let extra\(i) = 1\n"
        writer.write(Data(line.utf8)); written += line.utf16.count
        spin(0.02)
        seen.insert(busy.shownText.utf16.count)
    }
    assert(seen.count >= 3, "renders must keep landing while the file is written: saw \(seen.count) distinct texts")
    try? writer.close()
    spin(10) { busy.shownText.utf16.count == written }
    assert(busy.shownText.utf16.count == written)   // the last write is shown
    busy.close()
    host.contentView?.subviews.forEach { $0.removeFromSuperview() }

    // retarget resets the scroll at once, and a reload racing the retarget render must not bring the old offset back
    let longA = dir.appendingPathComponent("\(UUID().uuidString).txt"), longB = dir.appendingPathComponent("\(UUID().uuidString).txt")
    try? String((0..<400).map { "a line \($0)\n" }.joined()).write(to: longA, atomically: true, encoding: .utf8)
    try? String((0..<400).map { "b line \($0)\n" }.joined()).write(to: longB, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: longA); try? FileManager.default.removeItem(at: longB) }
    let scrolled = FilePaneView(id: UUID(), path: longA.path, theme: theme)
    scrolled.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    host.contentView?.addSubview(scrolled)
    spin(5) { scrolled.shownText.hasPrefix("a line 0\n") }
    scrolled.layoutSubtreeIfNeeded()
    scrolled.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2000))
    assert(scrolled.scrollView.contentView.bounds.origin.y > 0)
    scrolled.retarget(path: longB.path)
    assert(scrolled.scrollView.contentView.bounds.origin.y == 0)   // before any render lands
    scrolled.apply(theme: theme)   // a second reload supersedes the retarget's render
    spin(5) { scrolled.shownText.hasPrefix("b line 0\n") }
    assert(scrolled.shownText.hasPrefix("b line 0\n"))
    spin(0.3)
    assert(scrolled.scrollView.contentView.bounds.origin.y == 0)
    scrolled.close()
    host.contentView?.subviews.forEach { $0.removeFromSuperview() }

    // highlight colors are memoized per capture name: keywords still get the palette's keyword color, plain text the body color
    let swift = Renderer(text: "let a = 1\nlet b = 2\n", path: "x.swift", palette: Palette(theme), zoom: 1).render()
    let colorAt = { (i: Int) in swift.attribute(.foregroundColor, at: i, effectiveRange: nil) as! NSColor }
    assert(colorAt(0) == colorAt(10) && colorAt(0) != colorAt(4))   // both `let`s alike, and unlike the identifier

    // replacing a full, many-run storage must not be quadratic in its size
    let runs = NSMutableAttributedString(string: String(repeating: "let value = 42\n", count: 12_000))
    for i in stride(from: 0, to: runs.length - 4, by: 7) {
        runs.addAttribute(.foregroundColor, value: i % 2 == 0 ? NSColor.red : NSColor.blue, range: NSRange(location: i, length: 4))
    }
    let tv = NSTextView(usingTextLayoutManager: true)
    FilePaneView.replace(tv.textStorage!, with: runs)
    let t0 = Date()
    FilePaneView.replace(tv.textStorage!, with: runs)
    assert(Date().timeIntervalSince(t0) < 0.25, "re-setting a highlighted document took \(Date().timeIntervalSince(t0)) s")
    assert(tv.string.utf16.count == runs.length)
}
