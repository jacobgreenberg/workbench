import AppKit
import Markdown

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
    init(_ t: Theme) {
        body = RGBA(t.color("foreground")); heading = RGBA(t.color("cardForeground"))
        codeBackground = RGBA(t.color("popover")); link = RGBA(t.color("primary"))
        inlineCode = RGBA(t.color("chart4")); muted = RGBA(t.color("mutedForeground"))
        border = RGBA(t.color("border")); background = RGBA(t.color("background"))
    }
}

private struct Renderer: Sendable {
    let markdown: String
    let baseDir: URL
    let palette: Palette

    func render() -> NSAttributedString {
        var w = Walker(palette: palette, baseDir: baseDir)
        w.visit(Document(parsing: markdown))
        return w.out
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
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
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
            add(c.code.trimmingCharacters(in: .newlines) + "\n", [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: p.body.ns,
                .backgroundColor: p.codeBackground.ns,
                .paragraphStyle: s,
            ])
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
            let bold = NSFontManager.shared.convert(mono, toHaveTrait: .boldFontMask)
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

@MainActor final class MarkdownPaneView: NSView {
    let paneID: PaneID
    private let path: String
    private var palette: Palette
    private let scrollView = NSScrollView()
    private let textView = NSTextView(usingTextLayoutManager: true)
    private var generation = 0
    private var closed = false
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileInode: ino_t = 0
    private var pending: DispatchWorkItem?

    init(id: PaneID, path: String, theme: Theme) {
        paneID = id
        self.path = path
        palette = Palette(theme)
        super.init(frame: .zero)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        addSubview(scrollView)
        apply(theme: theme)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: Theme) {
        palette = Palette(theme)
        scrollView.backgroundColor = theme.color("background")
        textView.backgroundColor = theme.color("background")
        textView.linkTextAttributes = [.foregroundColor: theme.color("primary")]
        reload()
    }

    func close() {
        closed = true
        pending?.cancel(); pending = nil
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
    }

    private func reload() {
        generation += 1
        let gen = generation, path = path, palette = palette
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Cannot read \(path)"
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            let result = Renderer(markdown: text, baseDir: dir, palette: palette).render()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, !self.closed else { return }
                    let clip = self.scrollView.contentView
                    let origin = clip.bounds.origin
                    self.textView.textStorage?.setAttributedString(result)
                    self.textView.layoutSubtreeIfNeeded()
                    clip.scroll(to: origin)
                    self.scrollView.reflectScrolledClipView(clip)
                }
            }
        }
        rewatchFileIfNeeded()
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

    private func watch() {
        dirSource = makeSource(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        fileSource = makeSource(path)
        fileInode = inode()
    }

    private func rewatchFileIfNeeded() {
        let ino = inode()
        if fileSource == nil || ino != fileInode {
            fileSource?.cancel()
            fileSource = makeSource(path)
            fileInode = ino
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
