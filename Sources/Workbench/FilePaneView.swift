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
    var source = false

    /// Markdown is previewed; anything else is shown as code, highlighted when its language is known.
    func render() -> NSAttributedString {
        let url = URL(fileURLWithPath: path)
        guard !["md", "markdown"].contains(url.pathExtension.lowercased()) || source else {
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

private final class CodeTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else { return super.insertNewline(sender) }
        let ns = string as NSString
        let loc = selectedRange().location
        var i = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        let start = i
        while i < loc, [0x20, 0x09].contains(ns.character(at: i)) { i += 1 }
        insertText("\n" + ns.substring(with: NSRange(location: start, length: i - start)), replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return super.insertTab(sender) }
        insertText("    ", replacementRange: selectedRange())
    }
}

@MainActor final class FilePaneView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let paneID: PaneID
    private let path: String
    private var palette: Palette
    private let scrollView = NSScrollView()
    private let textView = CodeTextView(usingTextLayoutManager: true)
    private var generation = 0
    /// Newest requested generation, readable off main: queued renders that are already stale skip the read and parse.
    private final class Latest: Sendable { let value = Atomic<Int>(0) }
    private let latest = Latest()
    private var closed = false
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileInode: ino_t = 0
    private var pending: DispatchWorkItem?
    var onOpenLink: ((URL) -> Void)?
    var onDirtyChange: ((Bool) -> Void)?
    private(set) var isDirty = false { didSet { if oldValue != isDirty { onDirtyChange?(isDirty) } } }
    private(set) var isEditable = false
    private var diskText: String?
    private var sourceMode = false
    private let toggle = NSButton()
    private let undoButton = NSButton(), redoButton = NSButton()
    private let undo = UndoManager()   // per file, not the window's: undo never reaches a terminal or another file
    private var highlightGen = 0
    private var highlightWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var isMarkdown: Bool { ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    private let renderQueue = DispatchQueue(label: "pane.file", qos: .userInitiated)   // one render in flight per pane

    init(id: PaneID, path: String, theme: Theme) {
        paneID = id
        self.path = path
        palette = Palette(theme)
        super.init(frame: .zero)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false   // the pane or the preview's glass behind it shows through
        textView.drawsBackground = false
        textView.isEditable = false
        textView.delegate = self
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        addSubview(scrollView)
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 12)
        toggle.isHidden = true
        toggle.target = self
        toggle.action = #selector(toggleMode(_:))
        for (b, symbol, tip, sel) in [(undoButton, "arrow.uturn.backward", "Undo", #selector(undoEdit(_:))),
                                      (redoButton, "arrow.uturn.forward", "Redo", #selector(redoEdit(_:)))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.target = self
            b.action = sel
            b.isHidden = true
        }
        let controls = NSStackView(views: [undoButton, redoButton, toggle])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosave() }
            })
        }
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: Theme) {
        palette = Palette(theme)
        textView.linkTextAttributes = [.foregroundColor: theme.color("primary")]
        if isDirty { setTypingAttributes(); scheduleHighlight() } else { reload() }
    }

    private func setTypingAttributes() {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: palette.body.ns,
            .paragraphStyle: style,
        ]
    }

    @objc private func toggleMode(_ sender: Any?) {
        save()
        guard !isDirty else { return }
        sourceMode.toggle()
        reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(saveDocument(_:)) ? isDirty || isEditable : true
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
        scheduleHighlight()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateUndoButtons() } }   // after the typing group closes
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    @objc private func undoEdit(_ sender: Any?) { window?.makeFirstResponder(textView); textView.undoManager?.undo() }
    @objc private func redoEdit(_ sender: Any?) { window?.makeFirstResponder(textView); textView.undoManager?.redo() }

    private func updateUndoButtons() {
        undoButton.isHidden = !isEditable
        redoButton.isHidden = !isEditable
        undoButton.isEnabled = textView.undoManager?.canUndo ?? false
        redoButton.isEnabled = textView.undoManager?.canRedo ?? false
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runHighlight() }
        }
        highlightWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: w)
    }

    private func runHighlight() {
        guard !closed, isEditable, let key = Syntax.key(for: path) else { return }
        let text = textView.string, palette = palette
        guard text.utf16.count <= 2 << 20 else { return }
        highlightGen += 1
        let gen = highlightGen
        renderQueue.async { [weak self] in
            let spans = Syntax.highlights(text, key: key)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let spans, gen == self.highlightGen, !self.closed,
                          self.textView.string == text, let ts = self.textView.textStorage else { return }
                    ts.beginEditing()
                    ts.addAttribute(.foregroundColor, value: palette.body.ns, range: NSRange(location: 0, length: ts.length))
                    for s in spans {
                        guard let c = palette.color(capture: s.name), NSMaxRange(s.range) <= ts.length else { continue }
                        ts.addAttribute(.foregroundColor, value: c.ns, range: s.range)
                    }
                    ts.endEditing()
                }
            }
        }
    }

    private func conflicted() -> Bool { Self.loadText(path) != diskText }

    @discardableResult private func write(alert: Bool) -> Bool {
        let text = textView.string
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            if alert { NSAlert(error: error).runModal() }
            return false
        }
        diskText = text
        isDirty = false
        return true
    }

    @objc func saveDocument(_ sender: Any?) { save() }

    func save() {
        guard isDirty, isEditable else { return }
        guard conflicted() else { write(alert: true); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "“\(URL(fileURLWithPath: path).lastPathComponent)” changed on disk"
        a.informativeText = "Another program changed this file after you started editing."
        a.addButton(withTitle: "Overwrite")
        a.addButton(withTitle: "Reload from Disk")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: write(alert: true)
        case .alertSecondButtonReturn: isDirty = false; reload()
        default: break
        }
    }

    func autosave() {
        guard isDirty, isEditable, !conflicted() else { return }
        write(alert: false)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { onOpenLink?(url) }
        return true
    }

    func close() {
        autosave()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        highlightWork?.cancel()
        closed = true
        latest.value.store(-1, ordering: .relaxed)   // queued renders for this pane exit before any work
        pending?.cancel(); pending = nil
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
    }

    private func reload() {
        generation += 1
        latest.value.store(generation, ordering: .relaxed)
        let gen = generation, path = path, palette = palette, latest = latest
        let asSource = sourceMode
        renderQueue.async { [weak self] in
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let loaded = Self.loadText(path)
            let text = loaded ?? Self.load(path)
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            let result = Renderer(text: text, path: path, palette: palette, source: asSource).render()
            guard latest.value.load(ordering: .relaxed) == gen else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, !self.closed else { return }
                    let clip = self.scrollView.contentView
                    let origin = clip.bounds.origin
                    let ranges = self.textView.selectedRanges
                    self.highlightWork?.cancel()
                    self.highlightGen += 1
                    self.diskText = loaded
                    self.isEditable = loaded != nil && (!self.isMarkdown || asSource)
                    self.textView.isEditable = self.isEditable
                    self.toggle.isHidden = !(self.isMarkdown && loaded != nil)
                    self.toggle.title = asSource ? "Done" : "Edit"
                    self.textView.textStorage?.setAttributedString(result)
                    self.isDirty = false
                    if self.isEditable {
                        self.setTypingAttributes()
                        self.textView.allowsUndo = true
                        self.textView.isAutomaticQuoteSubstitutionEnabled = false
                        self.textView.isAutomaticDashSubstitutionEnabled = false
                        self.textView.isAutomaticTextReplacementEnabled = false
                        self.textView.inlinePredictionType = .no
                        self.textView.writingToolsBehavior = .none
                        self.textView.isAutomaticSpellingCorrectionEnabled = false
                        self.textView.isContinuousSpellCheckingEnabled = false
                        self.textView.isGrammarCheckingEnabled = false
                        self.textView.smartInsertDeleteEnabled = false
                        self.textView.usesFindBar = true
                        self.textView.isIncrementalSearchingEnabled = true
                        self.textView.undoManager?.removeAllActions()
                    }
                    self.updateUndoButtons()
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

    nonisolated static func loadText(_ path: String) -> String? {
        readFile(URL(fileURLWithPath: path), cap: 10 << 20).flatMap { String(data: $0, encoding: .utf8) }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                if let disk = Self.loadText(self.path), self.isEditable, disk == self.textView.string {
                    self.diskText = disk
                    self.rewatchFileIfNeeded()
                } else if self.isDirty {
                    self.rewatchFileIfNeeded()
                } else {
                    self.reload()
                }
            }
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
    let dir = FileManager.default.temporaryDirectory
    let good = dir.appendingPathComponent("\(UUID().uuidString).swift")
    let bad = dir.appendingPathComponent("\(UUID().uuidString).bin")
    try? "let a = 1\n".write(to: good, atomically: true, encoding: .utf8)
    try? Data([0xff, 0xfe, 0x00]).write(to: bad)
    defer { try? FileManager.default.removeItem(at: good); try? FileManager.default.removeItem(at: bad) }
    let v = FilePaneView(id: UUID(), path: good.path, theme: Theme.all().first!)
    assert(FilePaneView.loadText(good.path) == "let a = 1\n")
    assert(FilePaneView.loadText(bad.path) == nil)
    v.close()
}
