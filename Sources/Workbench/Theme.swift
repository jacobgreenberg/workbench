import AppKit

extension Notification.Name {
    /// Posted by applyTheme and whenever the theme list changes (Theme menu and Settings refresh on it).
    static let themeChanged = Notification.Name("WorkbenchThemeChanged")
}

struct Theme: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let ui: [String: String]
    let terminal: [String: String]
}

extension Theme {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                            "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
    /// Every key the app reads; a custom theme must provide all of them (extra keys are ignored).
    static let requiredUI = ["background", "foreground", "cardForeground", "popover", "primary", "mutedForeground", "border", "chart2", "chart3", "chart4"]
    static let requiredTerminal = ["background", "foreground", "cursor", "cursorAccent", "selectionBackground"] + ansiNames

    /// Dark / Light (Apple's themes). The rest are custom: bundled (read-only) or user.
    var isSystem: Bool { id.hasPrefix("system-") }
    /// The window appearance follows the theme's type.
    var appearance: NSAppearance? { NSAppearance(named: type == "light" ? .aqua : .darkAqua) }

    /// System + bundled + user themes, sorted by name. Cached; `reload()` rescans.
    @MainActor static func all() -> [Theme] { cache }
    @MainActor private static var cache = scan()
    /// id → file, for the themes loaded from Store.directory/themes (the editable ones).
    @MainActor private(set) static var userFiles: [String: URL] = [:]
    @MainActor static var userDirectory: URL { Store.directory.appendingPathComponent("themes") }
    @MainActor static func reload() { cache = scan() }

    @MainActor private static func scan() -> [Theme] {
        var dirs: [(URL, Bool)] = [(userDirectory, true)]
        if let r = Bundle.main.resourceURL { dirs.insert((r.appendingPathComponent("themes"), false), at: 0) }
        var byID: [String: Theme] = [:]
        for t in [system(dark: true), system(dark: false)] { byID[t.id] = t }
        var user: [String: URL] = [:]
        for (dir, isUser) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                guard let data = readFile(f, cap: 1 << 20),
                      let t = try? JSONDecoder().decode(Theme.self, from: data), !t.isSystem else { continue }
                byID[t.id] = t
                user[t.id] = isUser ? f : nil
            }
        }
        userFiles = user
        return byID.values.sorted { $0.name < $1.name }
    }

    @MainActor static func named(_ id: String) -> Theme {
        let list = all()
        return list.first { $0.id == id }
            ?? list.first { $0.id == "oceanic-v2" }
            ?? list.first
            ?? Theme(id: "oceanic-v2", name: "Oceanic v2", type: "dark", ui: [:], terminal: [:])
    }

    /// Apple's themes: terminal colors modeled on Terminal.app's "Basic" profile; accents from system colors,
    /// resolved (and flattened over the background) under the fixed appearance so they flow through plain hex strings.
    @MainActor static func system(dark: Bool) -> Theme {
        let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let bg = dark ? "#1E1E1E" : "#F6F6F6", fg = dark ? "#D9D9D9" : "#000000"
        let b = parse(bg)!
        func css(_ color: NSColor) -> String {
            var out = bg
            ap.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB) ?? color, a = c.alphaComponent
                let v = [(c.redComponent, b.r), (c.greenComponent, b.g), (c.blueComponent, b.b)]
                    .map { Int(max(0, min(255, $0.0 * 255 * a + $0.1 * (1 - a))).rounded()) }
                out = String(format: "#%02X%02X%02X", v[0], v[1], v[2])
            }
            return out
        }
        var term = ["background": bg, "foreground": fg, "cursor": fg, "cursorAccent": bg, "selectionBackground": css(.selectedTextBackgroundColor)]
        let ansi = ["#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
                    "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5"]
        for (n, v) in zip(ansiNames, ansi) { term[n] = v }
        let ui = ["background": bg, "foreground": fg, "cardForeground": fg, "popover": css(.windowBackgroundColor),
                  "primary": css(.controlAccentColor), "mutedForeground": css(.secondaryLabelColor), "border": css(.separatorColor),
                  "chart2": css(.systemGreen), "chart3": css(.systemOrange), "chart4": css(.systemPurple)]
        return Theme(id: dark ? "system-dark" : "system-light", name: dark ? "Dark" : "Light", type: dark ? "dark" : "light", ui: ui, terminal: term)
    }

    // MARK: - Custom themes: template, validation, saving

    struct Invalid: Error { let message: String }

    /// A complete theme file for the user to edit, seeded with this theme's colors.
    func template(id: String = "my-theme", name: String = "My Theme") -> String {
        func q(_ s: String) -> String {
            let d = (try? JSONEncoder().encode([s])) ?? Data()
            return String(decoding: d.dropFirst().dropLast(), as: UTF8.self)
        }
        func block(_ keys: [String], _ primary: [String: String], _ other: [String: String]) -> String {
            keys.map { "    \(q($0)): \(q(primary[$0] ?? other[$0] ?? "#808080"))" }.joined(separator: ",\n")
        }
        return """
        {
          "id": \(q(id)),
          "name": \(q(name)),
          "type": \(q(type)),
          "ui": {
        \(block(Theme.requiredUI, ui, terminal))
          },
          "terminal": {
        \(block(Theme.requiredTerminal, terminal, ui))
          }
        }

        """
    }

    /// Parses and checks a theme file; the failure message is meant for the user.
    static func validate(_ text: String) -> Result<Theme, Invalid> {
        func fail(_ m: String) -> Result<Theme, Invalid> { .failure(Invalid(message: m)) }
        let root: [String: Any]
        do {
            guard let r = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return fail("The top level must be a JSON object { ... }.")
            }
            root = r
        } catch {
            let why = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return fail("Not valid JSON: \(why)")
        }
        guard let id = root["id"] as? String, !id.isEmpty else { return fail("\"id\" is required (letters, digits, - _ .).") }
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            return fail("\"id\" becomes the file name: use letters, digits, - _ . only (max 64, starting with a letter or digit).")
        }
        if id.hasPrefix("system-") { return fail("\"id\" can't start with \"system-\" (reserved for Dark and Light).") }
        guard let name = root["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return fail("\"name\" is required.") }
        guard let type = root["type"] as? String, type == "dark" || type == "light" else { return fail("\"type\" must be \"dark\" or \"light\".") }
        var sections: [[String: String]] = []
        for (key, required) in [("ui", requiredUI), ("terminal", requiredTerminal)] {
            guard let obj = root[key] as? [String: Any] else { return fail("\"\(key)\" is required and must be an object.") }
            let missing = required.filter { obj[$0] == nil }
            if !missing.isEmpty { return fail("Missing in \"\(key)\": \(missing.joined(separator: ", "))") }
            var strings: [String: String] = [:]
            for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
                guard let s = v as? String, parse(s) != nil else { return fail("\(key).\(k): \(v) is not a color. Use #RRGGBB or rgba(r, g, b, a).") }
                strings[k] = s
            }
            sections.append(strings)
        }
        return .success(Theme(id: id, name: name, type: type, ui: sections[0], terminal: sections[1]))
    }

    /// Writes Store.directory/themes/<id>.json atomically.
    @MainActor static func save(_ t: Theme, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let url = userDirectory.appendingPathComponent("\(t.id).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func parse(_ s: String) -> RGBA? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            let h = t.dropFirst()
            guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
            if h.count == 6 {
                return (Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255), 1)
            }
            return (Double((v >> 24) & 255), Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255) / 255)
        }
        guard t.hasPrefix("rgb"), let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"), open < close else { return nil }
        let parts = t[t.index(after: open)..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 || parts.count == 4, !parts.contains(where: { $0 == nil }) else { return nil }
        let n = parts.map { $0! }
        guard n.prefix(3).allSatisfy({ (0...255).contains($0) }), n.count == 3 || (0...1).contains(n[3]) else { return nil }
        return (n[0], n[1], n[2], n.count == 4 ? n[3] : 1)
    }

    func color(_ key: String) -> NSColor {
        guard let s = ui[key], let c = Theme.parse(s) else { return .magenta }
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: c.a)
    }

    /// terminal[key] (the ANSI palette: "red", "brightBlack", ...); the UI foreground if missing.
    func terminalColor(_ key: String) -> NSColor {
        guard let s = terminal[key], let c = Theme.parse(s) else { return color("foreground") }
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: c.a)
    }

    private static func hex(_ c: RGBA) -> String {
        func b(_ x: Double) -> Int { max(0, min(255, Int(x.rounded()))) }
        return String(format: "#%02x%02x%02x", b(c.r), b(c.g), b(c.b))
    }

    private func hex(_ d: [String: String], _ key: String) -> String? {
        guard let s = d[key], let c = Theme.parse(s) else { return nil }
        return Theme.hex(c)
    }

    var ghosttyConfig: String {
        var lines: [String] = []
        func add(_ k: String, _ v: String?) { if let v { lines.append("\(k) = \(v)") } }
        add("background", hex(terminal, "background"))
        add("foreground", hex(terminal, "foreground"))
        add("cursor-color", hex(terminal, "cursor"))
        add("cursor-text", hex(terminal, "cursorAccent"))
        if let s = terminal["selectionBackground"], let fg = Theme.parse(s) {
            if fg.a < 1, let bg = terminal["background"].flatMap(Theme.parse) {
                let a = fg.a
                add("selection-background", Theme.hex((fg.r * a + bg.r * (1 - a), fg.g * a + bg.g * (1 - a), fg.b * a + bg.b * (1 - a), 1)))
            } else {
                add("selection-background", Theme.hex(fg))
            }
        }
        for (i, n) in Theme.ansiNames.enumerated() { add("palette", hex(terminal, n).map { "\(i)=\($0)" }) }
        add("split-divider-color", hex(ui, "border"))
        return lines.joined(separator: "\n") + "\n"
    }
}

#if DEBUG
func themeSelfCheck() {
    let p = Theme.parse("#1E272C")
    assert(p?.r == 30 && p?.g == 39 && p?.b == 44 && p?.a == 1)
    let q = Theme.parse("rgba(84, 110, 122, 0.5)")
    assert(q?.r == 84 && q?.g == 110 && q?.b == 122 && q?.a == 0.5)
    assert(WorkspaceController.displayTitle("⠏ Fix entry | aur") == "Fix entry | aur")
    assert(WorkspaceController.displayTitle("✳ Claude Code") == "Claude Code")
    assert(WorkspaceController.displayTitle("◐ Claude Code") == "Claude Code")
    assert(WorkspaceController.isSpinning("◐ Fix") && WorkspaceController.isSpinning("◒ Fix") && WorkspaceController.isSpinning("⠙ run"))
    assert(!WorkspaceController.isSpinning("✳ Claude Code") && !WorkspaceController.isSpinning("run"))
    assert(WorkspaceController.displayTitle("~/Documents") == "Documents")
    assert(WorkspaceController.displayTitle("jg@mac:/tmp/wbt/proj") == "proj")
    assert(WorkspaceController.displayTitle("jg@mac:~") == "~")
    assert(WorkspaceController.displayTitle("ssh jg@host: uptime") == "ssh jg@host: uptime")
    assert(WorkspaceController.displayTitle("vim notes.md") == "vim notes.md")
    assert(Runtime.shellEscape("/tmp/shot-1.png") == "/tmp/shot-1.png")
    assert(Runtime.shellEscape("/a b/c'd.png") == "'/a b/c'\\''d.png'")
    assert(Runtime.shellEscape("/x\nrm -rf ~") == "$'/x\\x0arm -rf ~'")
    assert(Runtime.shellEscape("/a'\u{1b}[2J\u{85}\\b") == "$'/a\\x27\\x1b[2J\\xc2\\x85\\x5cb'")
    assert(Theme.parse("rgb(1e100, 0, 0)") == nil && Theme.parse("rgba(1, 2, 3, 2)") == nil)
    let t = Theme(id: "x", name: "x", type: "dark", ui: [:], terminal: [
        "background": "#1E272C", "selectionBackground": "rgba(84, 110, 122, 0.5)", "black": "#546E7A",
    ])
    assert(t.ghosttyConfig.contains("selection-background = #394b53"))
    assert(t.ghosttyConfig.contains("palette = 0=#546e7a"))

    // Custom theme validation: the template passes; a missing key, bad color, unsafe id, bad type, bad JSON fail.
    let tpl = t.template()
    guard case .success(let ok) = Theme.validate(tpl), ok.id == "my-theme", ok.terminal["brightWhite"] != nil else { fatalError("template rejected") }
    guard case .failure(let e1) = Theme.validate(tpl.replacingOccurrences(of: "\"border\"", with: "\"borderX\"")), e1.message.contains("border") else { fatalError("missing key accepted") }
    guard case .failure(let e2) = Theme.validate(tpl.replacingOccurrences(of: "\"cursor\": \"#808080\"", with: "\"cursor\": \"red\"")), e2.message.contains("cursor") else { fatalError("bad color accepted") }
    guard case .failure = Theme.validate(tpl.replacingOccurrences(of: "my-theme", with: "../evil")) else { fatalError("unsafe id accepted") }
    guard case .failure = Theme.validate(tpl.replacingOccurrences(of: "\"dark\"", with: "\"blue\"")) else { fatalError("bad type accepted") }
    guard case .failure = Theme.validate("{") else { fatalError("bad JSON accepted") }
    // The system themes carry every required key as a parseable color, so their template is a valid theme too.
    for dark in [true, false] {
        let s = MainActor.assumeIsolated { Theme.system(dark: dark) }
        guard case .success = Theme.validate(s.template()), s.isSystem, s.type == (dark ? "dark" : "light") else { fatalError("system theme invalid") }
    }
}
#endif
