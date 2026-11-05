import Foundation

/// Turns an agent transcript into words for text-to-speech. Callable from any thread.
enum SpeechText {
    /// Entries of the last `bytes` of a session jsonl (a partial first line is dropped).
    static func tail(_ url: URL, bytes: Int = 4 << 20) -> [TranscriptEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return [] }
        var data = Data()
        if size > UInt64(bytes) {
            guard (try? h.seek(toOffset: size - UInt64(bytes))) != nil, let d = try? h.readToEnd() else { return [] }
            data = d
            if let nl = data.firstIndex(of: 10) { data = data.subdata(in: (nl + 1)..<data.endIndex) } else { data = Data() }
        } else {
            guard (try? h.seek(toOffset: 0)) != nil, let d = try? h.readToEnd() else { return [] }
            data = d
        }
        let codex = url.lastPathComponent.hasPrefix("rollout-")
        var out: [TranscriptEntry] = []
        for line in data.split(separator: 10) where !line.isEmpty {
            out += TranscriptParser.entries(Data(line), codex: codex)
        }
        return out
    }

    /// What to say for this transcript, reading only the last 256 KB unless that holds nothing to say.
    static func latest(_ url: URL) -> String? {
        if let u = utterance(tail(url, bytes: 256 << 10)) { return u }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 256 << 10 ? utterance(tail(url)) : nil
    }

    /// What to say for the current state: a pending question or plan, else the last assistant message.
    static func utterance(_ entries: [TranscriptEntry]) -> String? {
        var result: String?
        if let q = entries.lastIndex(where: { $0.kind == .toolCall && ($0.text.hasPrefix("AskUserQuestion ") || $0.text.hasPrefix("ExitPlanMode ")) }),
           !entries[(q + 1)...].contains(where: { $0.kind == .toolOutput || $0.kind == .user }),
           let speech = questionSpeech(entries[q].text) {
            let u = entries[..<q].lastIndex(where: { $0.kind == .user }) ?? -1
            let pre = entries[(u + 1)..<q].last(where: { $0.kind == .assistant })
            result = (pre.map { clean($0.text) + " " } ?? "") + speech
        } else if let a = entries.last(where: { $0.kind == .assistant }) {
            result = clean(a.text)
        }
        guard let r = result?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        return r
    }

    private static func questionSpeech(_ text: String) -> String? {
        guard let sp = text.firstIndex(of: " "),
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: sp)...].utf8))) as? [String: Any] else { return nil }
        if text.hasPrefix("ExitPlanMode") {
            var s = "Claude has a plan ready."
            if let plan = obj["plan"] as? String, !plan.isEmpty { s += " " + clean(plan) }
            return s
        }
        guard let qs = obj["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        func body(_ q: [String: Any]) -> String {
            var s = (q["multiSelect"] as? Bool) == true ? " Pick any that apply." : ""
            let opts = q["options"] as? [[String: Any]] ?? []
            for (i, o) in opts.enumerated() {
                s += " Option \(i < words.count ? words[i] : "\(i + 1)"), " + clean(o["label"] as? String ?? "")
            }
            return s
        }
        if qs.count == 1 { return "Claude is asking: " + clean(qs[0]["question"] as? String ?? "") + body(qs[0]) }
        var s = "Claude is asking \(qs.count) questions."
        for (k, q) in qs.enumerated() { s += " Question \(k + 1): " + clean(q["question"] as? String ?? "") + body(q) }
        return s
    }

    nonisolated(unsafe) private static let hr = try! NSRegularExpression(pattern: #"^([-*_])(\s*\1){2,}\s*$"#)
    nonisolated(unsafe) private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    nonisolated(unsafe) private static let quote = try! NSRegularExpression(pattern: #"^>\s?"#)
    nonisolated(unsafe) private static let bullet = try! NSRegularExpression(pattern: #"^([-*+•]|\d+[.)])\s+"#)
    nonisolated(unsafe) private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)
    nonisolated(unsafe) private static let url = try! NSRegularExpression(pattern: #"https?://(?:www\.)?([^/\s)]+)\S*"#)
    nonisolated(unsafe) private static let path = try! NSRegularExpression(pattern: #"(?<![\w/])[~.]{0,2}[\w.@+-]*(?:/[\w.@+-]+)+"#)
    nonisolated(unsafe) private static let lineRef = try! NSRegularExpression(pattern: #"([\w-]+\.[A-Za-z]\w*):(\d+)(?::\d+)?"#)
    nonisolated(unsafe) private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    private static func sub(_ r: NSRegularExpression, _ s: String, _ t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    /// Markdown to plain speakable sentences: code, tables, links, paths and line refs reduced.
    static func clean(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            var l = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if l.hasPrefix("```") || l.hasPrefix("~~~") {
                let marker = String(l.prefix(3))
                while i < lines.count {
                    let closes = lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker)
                    i += 1
                    if closes { break }
                }
                l = "(code omitted)"
            } else {
                if l.isEmpty { continue }
                if hr.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { continue }
                if l.hasPrefix("|") {
                    if l.allSatisfy({ "|-: ".contains($0) }) { continue }
                    l = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
                }
                l = sub(heading, l, "")
                while quote.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { l = sub(quote, l, "") }
                l = sub(bullet, l, "")
            }
            l = sub(link, l, "$1")
            l = sub(url, l, "$1")
            l = l.replacingOccurrences(of: "`", with: "")
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "*", with: "")
            l = shortenPaths(l)
            l = sub(lineRef, l, "$1, line $2")
            l = sub(spaces, l, " ").trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if !".!?:;,".contains(l.last!) { l += "." }
            out.append(l)
        }
        return out.joined(separator: " ")
    }

    nonisolated(unsafe) private static let listItem = try! NSRegularExpression(pattern: #"^([-*+•]|\d+[.)]|#{1,6})\s"#)

    /// Text selected in a terminal, for the ear: TUI glyphs (⏺ ⎿ ✻, box drawing) dropped, hard-wrapped lines rejoined
    /// (a blank line, list item or heading starts a new one), then `clean`.
    static func selection(_ text: String) -> String {
        var lines: [String] = []
        var joining = false
        for raw in text.components(separatedBy: .newlines) {
            let l = String(raw.unicodeScalars.filter { !(0x2500...0x259F).contains($0.value) && !"⏺⎿✻✶✢✳⏵".unicodeScalars.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            if l.isEmpty { joining = false; continue }
            if joining, listItem.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) == nil, !l.hasPrefix("```") {
                lines[lines.count - 1] += " " + l
            } else {
                lines.append(l)
            }
            joining = !l.hasPrefix("```")
        }
        return clean(lines.joined(separator: "\n"))
    }

    private static func shortenPaths(_ s: String) -> String {
        let ms = NSMutableString(string: s)
        for m in path.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let t = (s as NSString).substring(with: m.range)
            let last = t.split(separator: "/").last.map(String.init) ?? t
            let hasExt = last.range(of: #"\.[A-Za-z]"#, options: .regularExpression) != nil
            let rooted = ["/", "~/", "./", "../"].contains { t.hasPrefix($0) }
            if t.filter({ $0 == "/" }).count >= 2 || rooted || hasExt { ms.replaceCharacters(in: m.range, with: last) }
        }
        return ms as String
    }

    /// Sentences packed into pieces of at most `limit` characters.
    static func chunks(_ text: String, limit: Int = 400) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return [] }
        var sentences: [String] = []
        var cur = ""
        let cs = Array(t)
        var i = 0
        while i < cs.count {
            cur.append(cs[i])
            if ".!?".contains(cs[i]), i + 1 == cs.count || cs[i + 1].isWhitespace {
                sentences.append(cur)
                cur = ""
                while i + 1 < cs.count, cs[i + 1].isWhitespace { i += 1 }
            }
            i += 1
        }
        if !cur.isEmpty { sentences.append(cur) }
        var pieces: [String] = []
        for s in sentences {
            let a = Array(s)
            var start = 0
            while a.count - start > limit {
                var sp = start + limit
                while sp > start, a[sp] != " " { sp -= 1 }
                if sp > start {
                    pieces.append(String(a[start..<sp]))
                    start = sp + 1
                } else {
                    pieces.append(String(a[start..<(start + limit)]))
                    start += limit
                }
            }
            if start < a.count { pieces.append(String(a[start...])) }
        }
        var out: [String] = []
        var lens: [Int] = []
        for p in pieces {
            let n = p.count
            if let l = lens.last, l + 1 + n <= limit { out[out.count - 1] += " " + p; lens[lens.count - 1] = l + 1 + n } else { out.append(p); lens.append(n) }
        }
        return out
    }
}

#if DEBUG
func speechTextSelfCheck() {
    func eq(_ a: String, _ b: String) { assert(a == b, "\(a)") }
    eq(SpeechText.clean("## Summary\nI changed `Sources/Workbench/Speaker.swift:42` and fixed it."), "Summary. I changed Speaker.swift, line 42 and fixed it.")
    eq(SpeechText.clean("Run this:\n```bash\nswift build\n```\nThen restart."), "Run this: (code omitted). Then restart.")
    eq(SpeechText.clean("- **Fast**: 0.8 s\n- See https://www.example.com/a/b?c=1 for more"), "Fast: 0.8 s. See example.com for more.")
    eq(SpeechText.clean("| Model | Speed |\n|---|---|\n| Voxtral | 0.8 s |"), "Model, Speed. Voxtral, 0.8 s.")
    eq(SpeechText.clean("Use [the docs](https://docs.x.io/p) and/or ask."), "Use the docs and/or ask.")
    eq(SpeechText.clean("Edit src/main.rs then ~/Library/Logs/app.log."), "Edit main.rs then app.log.")
    eq(SpeechText.clean("---\n> Note: done"), "Note: done.")
    eq(SpeechText.clean("1. First\n2. Second"), "First. Second.")
    eq(SpeechText.clean("Call read_db now"), "Call read_db now.")
    eq(SpeechText.clean("```\nunclosed"), "(code omitted).")

    eq(SpeechText.selection("⏺ The crash was in the tab\n  bar, and I fixed\n  it.\n\n  - first item\n  - second\n╭──────╮\n│ Done │"),
       "The crash was in the tab bar, and I fixed it. first item. second. Done.")
    eq(SpeechText.selection("  ⎿  Read Speaker.swift"), "Read Speaker.swift.")

    assert(SpeechText.chunks("One. Two! Three?", limit: 9) == ["One. Two!", "Three?"], "\(SpeechText.chunks("One. Two! Three?", limit: 9))")
    assert(SpeechText.chunks("Hi.") == ["Hi."], "Hi")
    assert(SpeechText.chunks("") == [], "empty")
    assert(SpeechText.chunks("  \n ") == [], "blank")
    let long = (0..<150).map { "w\($0)" }.joined(separator: " ") + "."
    let c = SpeechText.chunks(long, limit: 400)
    assert(c.count >= 2, "\(c.count)")
    assert(c.allSatisfy { $0.count <= 400 }, "chunk over limit")
    assert(c.joined(separator: " ") == long, "chunks lose text")

    let big = String(repeating: "word ", count: 200_000)
    let t0 = Date()
    let bc = SpeechText.chunks(big)
    let dt = Date().timeIntervalSince(t0)
    assert(dt < 0.5, "chunks 1M took \(dt)")
    assert(bc.allSatisfy { $0.count <= 400 } && bc.joined(separator: " ") == big.trimmingCharacters(in: .whitespaces), "big chunks")
    let ab = String(repeating: "ab ", count: 1000) + "."
    let ac = SpeechText.chunks(ab)
    assert(ac.allSatisfy { $0.count <= 400 } && ac.joined(separator: " ") == ab, "ab chunks")
    assert(ac.dropLast().allSatisfy { $0.hasSuffix("ab") && $0.count >= 398 }, "ab splits \(ac.map { $0.count })")

    do {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("speech-latest-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        func line(_ s: String) -> Data { Data((s + "\n").utf8) }
        func asst(_ t: String) -> Data { line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(t)"}]}}"#) }
        let pad = line(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"\#(String(repeating: "x", count: 1000))"}]}}"#)
        var d = asst("Far back.")
        for _ in 0..<300 { d.append(pad) }
        try? d.write(to: f)
        assert(SpeechText.latest(f) == "Far back.", "latest far \(String(describing: SpeechText.latest(f)))")
        if let h = try? FileHandle(forWritingTo: f) { _ = try? h.seekToEnd(); try? h.write(contentsOf: asst("Near.")); try? h.close() }
        assert(SpeechText.latest(f) == "Near.", "latest near")
    }

    func e(_ k: TranscriptEntry.Kind, _ t: String) -> TranscriptEntry { .init(kind: k, text: t, time: nil) }
    let ask = #"AskUserQuestion {"questions":[{"header":"Voice","multiSelect":false,"options":[{"description":"d1","label":"OpenAI TTS (Recommended)"},{"description":"d2","label":"Local neural"}],"question":"Which voice engine?"}]}"#
    func u(_ es: [TranscriptEntry], _ want: String?) {
        let got = SpeechText.utterance(es)
        assert(got == want, "\(String(describing: got))")
    }
    u([e(.user, "hi"), e(.assistant, "Working on it."), e(.toolCall, #"Bash {"command":"ls"}"#), e(.toolOutput, "x"), e(.assistant, "All done. Tests pass.")], "All done. Tests pass.")
    u([e(.user, "q"), e(.assistant, "Here's what I found."), e(.toolCall, ask)], "Here's what I found. Claude is asking: Which voice engine? Option one, OpenAI TTS (Recommended). Option two, Local neural.")
    u([e(.user, "q"), e(.assistant, "Here's what I found."), e(.toolCall, ask), e(.toolOutput, "answered"), e(.assistant, "Got it.")], "Got it.")
    u([e(.user, "q"), e(.assistant, "Here's what I found."), e(.toolCall, ask), e(.toolOutput, "answered")], "Here's what I found.")
    u([e(.assistant, "Old text."), e(.user, "go"), e(.toolCall, ##"ExitPlanMode {"plan":"# Plan\n- Add a button"}"##)], "Claude has a plan ready. Plan. Add a button.")
    u([e(.user, "q"), e(.toolCall, #"AskUserQuestion {"questions":[{"multiSelect":true,"options":[{"label":"x"}],"question":"A?"},{"options":[{"label":"y"},{"label":"z"}],"question":"B?"}]}"#)], "Claude is asking 2 questions. Question 1: A? Pick any that apply. Option one, x. Question 2: B? Option one, y. Option two, z.")
    u([], nil)
    u([e(.user, "hi")], nil)

    let L1 = #"{"type":"user","message":{"role":"user","content":"first question"}}"#
    let L2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"middle"}]}}"#
    let L3 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"last"}]}}"#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try? Data((L1 + "\n" + L2 + "\n" + L3 + "\n").utf8).write(to: url)
    let all = SpeechText.tail(url).map(\.text)
    assert(all == ["first question", "middle", "last"], "\(all)")
    let part = SpeechText.tail(url, bytes: L2.utf8.count + L3.utf8.count + 2 + 5).map(\.text)
    assert(part == ["middle", "last"], "\(part)")
}
#endif
