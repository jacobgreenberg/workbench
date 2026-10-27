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
    for s in spans {
        guard let c = p.color(capture: s.name), NSMaxRange(s.range) <= text.utf16.count else { continue }
        out.addAttribute(.foregroundColor, value: c.ns, range: NSRange(location: offset + s.range.location, length: s.range.length))
    }
}

private struct Renderer: Sendable {
    let text: String
    let path: String
    let palette: Palette

    /// Markdown is previewed; anything else is shown as code, highlighted when its language is known.
    func render() -> NSAttributedString {
        let url = URL(fileURLWithPath: path)
        guard !["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            var w = Walker(palette: palette, baseDir: url.deletingLastPathComponent())
            w.visit(Document(parsing: text))
            return w.out
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
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
        var heading = 0, bold = false, italic = false, strike = false
        var quote = 0, listDepth = 0
        var link: URL?

        init(palette: Palette, baseDir: URL) { p = palette; self.baseDir = baseDir }

        func font(size: CGFloat? = nil) -> NSFont {
            let sizes: [CGFloat] = [14, 26, 22, 18, 16, 14, 14]
            var f = NSFont.systemFont(ofSize: size ?? sizes[heading], weight: heading > 0 || bold ? .bold : .regular)
            if italic { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: 0) ?? f }   // NSFontManager is main-thread only
            return f
        }

        func style(indent: CGFloat = 0, centered: Bool = false) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.lineSpacing = 4; s.paragraphSpacing = 10
            if heading > 0 { s.paragraphSpacingBefore = 14 }
            let level = CGFloat(listDepth) * 20 + CGFloat(quote) * 16 + indent
            s.headIndent = level
            s.firstLineHeadIndent = listDepth > 0 ? level - 20 : level
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
            a[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            a[.foregroundColor] = p.inlineCode.ns
            a[.backgroundColor] = p.codeBackground.ns
            add(c.code, a)
        }

        mutating func visitCodeBlock(_ c: CodeBlock) {
            let s = NSMutableParagraphStyle()
            s.lineSpacing = 2; s.paragraphSpacing = 0
            s.headIndent = 12; s.firstLineHeadIndent = 12; s.tailIndent = -12
            let code = c.code.trimmingCharacters(in: .newlines)
            let start = out.length
            add(code + "\n", [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: p.body.ns,
                .backgroundColor: p.codeBackground.ns,
                .paragraphStyle: s,
            ])
            if let key = c.language.flatMap(Syntax.key(fence:)) { highlight(out, at: start, code, key: key, p) }
            add("\n", [.font: NSFont.systemFont(ofSize: 6)])
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
            let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
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
    private let path: String
    private var palette: Palette
    private let scrollView = NSScrollView()
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
    private let renderQueue = DispatchQueue(label: "pane.file", qos: .userInitiated)   // one render in flight per pane

    init(id: PaneID, path: String, theme: Theme) {
        paneID = id
        self.path = path
        palette = Palette(theme)
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
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(textView) ?? false }

    func apply(theme: Theme) {
        palette = Palette(theme)
        textView.linkTextAttributes = [.foregroundColor: theme.color("primary")]
        reload()
    }

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
        latest.value.store(generation, ordering: .relaxed)
        let gen = generation, path = path, palette = palette, latest = latest
        renderQueue.async { [weak self] in
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let text = Self.load(path)
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let result = Renderer(text: text, path: path, palette: palette).render()
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, !self.closed else { return }
                    let clip = self.scrollView.contentView
                    let origin = clip.bounds.origin
                    let ranges = self.textView.selectedRanges
                    self.textView.textStorage?.setAttributedString(result)
                    let len = (self.textView.string as NSString).length
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
                }
            }
        }
        rewatchFileIfNeeded()
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

    private func changed() {
        guard !closed else { return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: w)
    }
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
    pane.removeFromSuperview()
    pane.close()
}
