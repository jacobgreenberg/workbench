import AppKit

struct Theme: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let ui: [String: String]
    let terminal: [String: String]
}

extension Theme {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    /// Read once: the Theme menu is built at launch, so the set is fixed for the run.
    static func all() -> [Theme] { cache }
    private static let cache = scan()

    private static func scan() -> [Theme] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("themes")) }
        if let s = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(s.appendingPathComponent("Workbench/themes"))
        }
        var byID: [String: Theme] = [:]
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                guard let data = readFile(f, cap: 1 << 20),
                      let t = try? JSONDecoder().decode(Theme.self, from: data) else { continue }
                byID[t.id] = t
            }
        }
        return byID.values.sorted { $0.name < $1.name }
    }

    static func named(_ id: String) -> Theme {
        let list = all()
        return list.first { $0.id == id }
            ?? list.first { $0.id == "oceanic-v2" }
            ?? list.first
            ?? Theme(id: "oceanic-v2", name: "Oceanic v2", type: "dark", ui: [:], terminal: [:])
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
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
        for (i, n) in names.enumerated() { add("palette", hex(terminal, n).map { "\(i)=\($0)" }) }
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
    assert(WorkspaceController.stripStatusGlyphs("⠏ Fix entry | aur") == "Fix entry | aur")
    assert(WorkspaceController.stripStatusGlyphs("✳ Claude Code") == "Claude Code")
    assert(WorkspaceController.stripStatusGlyphs("~/Documents") == "~/Documents")
    assert(Runtime.shellEscape("/tmp/shot-1.png") == "/tmp/shot-1.png")
    assert(Runtime.shellEscape("/a b/c'd.png") == "'/a b/c'\\''d.png'")
    assert(Runtime.shellEscape("/x\nrm -rf ~") == "'/x\nrm -rf ~'")
    assert(Theme.parse("rgb(1e100, 0, 0)") == nil && Theme.parse("rgba(1, 2, 3, 2)") == nil)
    let t = Theme(id: "x", name: "x", type: "dark", ui: [:], terminal: [
        "background": "#1E272C", "selectionBackground": "rgba(84, 110, 122, 0.5)", "black": "#546E7A",
    ])
    assert(t.ghosttyConfig.contains("selection-background = #394b53"))
    assert(t.ghosttyConfig.contains("palette = 0=#546e7a"))
}
#endif
