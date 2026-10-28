import Foundation
import Synchronization

/// One searchable piece of an agent's session transcript.
struct TranscriptEntry: Sendable, Equatable {
    enum Kind: Sendable { case user, assistant, toolCall, toolOutput }
    let kind: Kind
    let text: String
    let time: Date?
}

/// One occurrence of the query: entry index + UTF-16 range in its text.
struct TranscriptMatch: Sendable, Equatable {
    let entry: Int
    let range: NSRange
}

/// Claude Code / Codex session jsonl → entries. Everything that isn't conversation text or tool traffic is skipped.
enum TranscriptParser {
    private static let claudeTypes = [Data(#""type":"user""#.utf8), Data(#""type":"assistant""#.utf8)]
    private static let codexType = Data(#""type":"response_item""#.utf8)
    private static let injected = ["<environment_context>", "<user_instructions>", "# AGENTS.md"]
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func entries(_ line: Data, codex: Bool) -> [TranscriptEntry] {
        // Cheap byte test first: most lines (attachments, snapshots, reasoning, token counts) are not worth a JSON parse.
        guard codex ? line.range(of: codexType) != nil : claudeTypes.contains(where: { line.range(of: $0) != nil }),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let time = (o["timestamp"] as? String).flatMap { fractional.date(from: $0) }
        var out: [TranscriptEntry] = []
        func add(_ kind: TranscriptEntry.Kind, _ text: String) { if !text.isEmpty { out.append(.init(kind: kind, text: text, time: time)) } }
        if codex {
            guard o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any] else { return [] }
            func call(_ args: Any?) -> String { [p["name"] as? String, args as? String].compactMap { $0 }.joined(separator: " ") }
            switch p["type"] as? String {
            case "message":
                let role = p["role"] as? String
                guard role == "user" || role == "assistant" else { return [] }
                for b in p["content"] as? [[String: Any]] ?? [] {
                    guard let t = b["text"] as? String, !(role == "user" && injected.contains { t.hasPrefix($0) }) else { continue }
                    add(role == "user" ? .user : .assistant, t)
                }
            case "function_call": add(.toolCall, call(p["arguments"]))
            case "custom_tool_call": add(.toolCall, call(p["input"]))
            case "function_call_output", "custom_tool_call_output": add(.toolOutput, text(p["output"]))
            default: break
            }
        } else {
            let user = o["type"] as? String == "user"
            guard o["isMeta"] as? Bool != true, let msg = o["message"] as? [String: Any] else { return [] }
            if let s = msg["content"] as? String { add(user ? .user : .assistant, s) }
            for b in msg["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text": add(user ? .user : .assistant, b["text"] as? String ?? "")
                case "tool_result" where user: add(.toolOutput, text(b["content"]))
                case "tool_use" where !user:
                    let input = b["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
                    add(.toolCall, [b["name"] as? String, input.map { String(decoding: $0, as: UTF8.self) }].compactMap { $0 }.joined(separator: " "))
                default: break
                }
            }
        }
        return out
    }

    /// A tool result's content: a string, or an array of text blocks.
    private static func text(_ v: Any?) -> String {
        if let s = v as? String { return s }
        return (v as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Case- and diacritic-insensitive substring search; every occurrence is a match.
    static func matches(in entries: [TranscriptEntry], _ query: String) -> [TranscriptMatch] {
        var out: [TranscriptMatch] = []
        forEachMatch(in: entries, query) { out.append(.init(entry: $0, range: $1)) }
        return out
    }

    /// How many matches there are; a short query on a big session has millions, which `matches` would materialize.
    static func count(in entries: [TranscriptEntry], _ query: String) -> Int {
        var n = 0
        forEachMatch(in: entries, query) { _, _ in n += 1 }
        return n
    }

    private static func forEachMatch(in entries: [TranscriptEntry], _ query: String, _ body: (Int, NSRange) -> Void) {
        guard !query.isEmpty else { return }
        for (i, e) in entries.enumerated() {
            let s = e.text as NSString
            var r = NSRange(location: 0, length: s.length)
            while r.length > 0 {
                let f = s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: r)
                guard f.location != NSNotFound, f.length > 0 else { break }
                body(i, f)
                r = NSRange(location: NSMaxRange(f), length: s.length - NSMaxRange(f))
            }
        }
    }
}

/// One transcript file, parsed incrementally: entries so far and the byte offset up to the last complete line.
/// Touched only on `TranscriptSearch.queue`.
final class TranscriptIndex: @unchecked Sendable {
    let url: URL
    private let codex: Bool
    private(set) var entries: [TranscriptEntry] = []
    private var offset: UInt64 = 0

    init(_ url: URL) { self.url = url; codex = url.lastPathComponent.hasPrefix("rollout-") }

    /// Reads only what was appended since last time, whole lines only (a half-written last line waits).
    func update() {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        if let size = try? h.seekToEnd(), size < offset { entries = []; offset = 0 }   // rewritten: start over
        guard (try? h.seek(toOffset: offset)) != nil else { return }
        var buf = Data()
        var more = true
        while more {
            // One pool per chunk: Foundation's read buffers and JSON graphs are autoreleased, and this whole parse is a
            // single work item, so without it a big session holds about twice its size until the item ends.
            autoreleasepool {
                guard let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty else { more = false; return }
                buf.append(chunk)
                guard let nl = buf.lastIndex(of: 10) else { return }
                let end = nl - buf.startIndex
                for line in buf.prefix(end).split(separator: 10) { entries += TranscriptParser.entries(Data(line), codex: codex) }
                offset += UInt64(end + 1)
                buf.removeSubrange(buf.startIndex...nl)
            }
        }
    }
}

/// Background side of transcript Find. A newer call supersedes older ones (their work is skipped or their result dropped).
enum TranscriptSearch {
    private static let queue = DispatchQueue(label: "workbench.transcript", qos: .userInitiated)
    nonisolated(unsafe) private static var current: TranscriptIndex?   // queue-confined: the one parsed file kept
    private static let generation = Mutex(0)
    private static let activity = Mutex(0)   // bumped by every use of the index; a release only fires if it is still the latest
    /// How long the parsed file stays after Find closes, so closing and reopening it is instant.
    static let keepAfterClose: TimeInterval = 60

    /// Supersedes any search in flight.
    static func cancel() { generation.withLock { $0 += 1 } }

    /// Find is done with the parsed transcript: drop it after `keepAfterClose`, unless Find is used again meanwhile.
    static func release(after delay: TimeInterval = keepAfterClose) {
        let mine = activity.withLock { $0 += 1; return $0 }
        queue.asyncAfter(deadline: .now() + delay) {
            if activity.withLock({ $0 }) == mine { current = nil }
        }
    }

    private static func index(for url: URL) -> TranscriptIndex {
        activity.withLock { $0 += 1 }
        if let c = current, c.url == url { return c }
        let index = TranscriptIndex(url)
        current = index
        return index
    }

    /// The pane's transcript, if an agent runs there. The parse starts right away, so it overlaps the typing that follows.
    static func locate(_ pane: PaneID, done: @escaping @Sendable @MainActor (URL?) -> Void) {
        queue.async {
            let url = Agents.transcript(for: pane)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(url) } }
            if let url { index(for: url).update() }
        }
    }

    private static func count(_ url: URL, _ query: String) -> Int {
        let index = index(for: url)
        if !query.isEmpty { index.update() }
        return TranscriptParser.count(in: index.entries, query)
    }

    #if DEBUG
    static func cachedURL() -> URL? { queue.sync { current?.url } }
    static func countNow(_ url: URL, _ query: String) -> Int { queue.sync { count(url, query) } }
    #endif

    /// How many times `query` occurs in the transcript.
    static func search(_ url: URL, _ query: String, done: @escaping @Sendable @MainActor (Int) -> Void) {
        let mine = generation.withLock { $0 += 1; return $0 }
        queue.async {
            guard generation.withLock({ $0 }) == mine else { return }
            let total = count(url, query)
            DispatchQueue.main.async {
                guard generation.withLock({ $0 }) == mine else { return }
                MainActor.assumeIsolated { done(total) }
            }
        }
    }
}

#if DEBUG
func transcriptSelfCheck() {
    func parse(_ lines: [String], codex: Bool) -> [TranscriptEntry] { lines.flatMap { TranscriptParser.entries(Data($0.utf8), codex: codex) } }
    let claude = parse([
        #"{"type":"user","timestamp":"2026-09-22T16:55:51.850Z","message":{"role":"user","content":"Hello wörld"}}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<caveat>"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"out A"},{"type":"text","text":"out B"}]},{"type":"text","text":"more"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Sure"},{"type":"tool_use","name":"Bash","input":{"command":"ls /tmp"}}]}}"#,
        #"{"type":"attachment","message":{"content":"user"}}"#,
        #"{"type":"system","message":{"content":"x"}}"#,
        "not json",
    ], codex: false)
    assert(claude.map(\.kind) == [.user, .toolOutput, .user, .assistant, .toolCall], "\(claude.map(\.kind))")
    assert(claude.map(\.text) == ["Hello wörld", "out A\nout B", "more", "Sure", #"Bash {"command":"ls /tmp"}"#])
    assert(claude[0].time != nil && claude[1].time == nil)

    let codex = parse([
        #"{"timestamp":"2026-10-05T14:21:06.234Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix it"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","output":"files"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(1)"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"type":"input_text","text":"1"}]}}"#,
        #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
    ], codex: true)
    assert(codex.map(\.kind) == [.user, .assistant, .toolCall, .toolOutput, .toolCall, .toolOutput], "\(codex.map(\.kind))")
    assert(codex.map(\.text) == ["fix it", "done", #"shell {"cmd":"ls"}"#, "files", "exec text(1)", "1"])

    // Case/diacritic-insensitive; every occurrence counts.
    let m = TranscriptParser.matches(in: claude, "O")
    assert(m.map(\.entry) == [0, 0, 1, 1, 2, 4] && m.map(\.range.location) == [4, 7, 0, 6, 1, 8], "\(m)")   // "wörld" matches "o"
    assert(TranscriptParser.matches(in: claude, "ÖUT B").map(\.entry) == [1] && TranscriptParser.matches(in: claude, "").isEmpty)
    assert(TranscriptParser.count(in: claude, "O") == m.count && TranscriptParser.count(in: claude, "ÖUT B") == 1 && TranscriptParser.count(in: claude, "") == 0)

    // Incremental read: a half-written last line is left for the next update.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let l1 = #"{"type":"user","message":{"content":"one"}}"# + "\n", l2 = #"{"type":"user","message":{"content":"two"}}"#
    try! Data((l1 + l2.prefix(20)).utf8).write(to: url)
    let index = TranscriptIndex(url)
    index.update()
    assert(index.entries.map(\.text) == ["one"])
    let h = try! FileHandle(forWritingTo: url)
    try! h.seekToEnd(); try! h.write(contentsOf: Data((l2.dropFirst(20) + "\n").utf8)); try! h.close()
    index.update()
    assert(index.entries.map(\.text) == ["one", "two"])
    transcriptCacheSelfCheck(url)
    transcriptMemorySelfCheck()
}

/// The parsed file is kept across Find sessions for a while, then dropped; any use in between keeps it.
private func transcriptCacheSelfCheck(_ url: URL) {
    func count(_ q: String) -> Int { TranscriptSearch.countNow(url, q) }   // done is delivered on the main queue, which is blocked here
    assert(count("o") == 2 && count("zzz") == 0 && count("T") == 1)
    assert(TranscriptSearch.cachedURL() == url)
    TranscriptSearch.release(after: 0.1)
    Thread.sleep(forTimeInterval: 0.4)
    assert(TranscriptSearch.cachedURL() == nil, "dropped after close")
    assert(count("one") == 1 && TranscriptSearch.cachedURL() == url)   // reparsed on demand
    TranscriptSearch.release(after: 0.3)
    Thread.sleep(forTimeInterval: 0.1)
    assert(count("two") == 1)   // Find reopened before the delay ran out
    Thread.sleep(forTimeInterval: 0.5)
    assert(TranscriptSearch.cachedURL() == url, "a release superseded by later use must not drop the index")
    TranscriptSearch.release(after: 0.05)
    Thread.sleep(forTimeInterval: 0.3)
    assert(TranscriptSearch.cachedURL() == nil)
}

/// A big transcript parsed in one work item must not leave Foundation's per-chunk garbage (read buffers, JSON graphs)
/// behind until the item ends: footprint after the parse stays near the size of the entries kept.
private func transcriptMemorySelfCheck() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = String(repeating: "lorem ipsum dolor sit amet ", count: 150)   // ~4 KB of text per line
    let line = #"{"type":"user","message":{"content":"\#(text)"}}"# + "\n"
    let chunk = Data(String(repeating: line, count: 2000).utf8)   // ~8 MB
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try! FileHandle(forWritingTo: url)
    for _ in 0..<12 { try! h.write(contentsOf: chunk) }
    try! h.close()
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return Int(info.phys_footprint)
    }
    nonisolated(unsafe) var grown = 0, kept = 0
    // A fresh queue, like the real one: no pool is drained until the work item ends.
    DispatchQueue(label: "selfcheck.transcript", qos: .userInitiated).sync {
        let before = footprint()
        let index = TranscriptIndex(url)
        index.update()
        grown = footprint() - before
        kept = index.entries.reduce(0) { $0 + $1.text.utf8.count }
        assert(index.entries.count == 24000)
    }
    assert(grown < kept * 3 / 2, "parse left \(grown >> 20) MB for \(kept >> 20) MB of entries")
}
#endif
