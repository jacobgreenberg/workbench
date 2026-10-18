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

struct TranscriptResult: Sendable {
    let entries: [TranscriptEntry]
    let matches: [TranscriptMatch]
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
        guard !query.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        for (i, e) in entries.enumerated() {
            let s = e.text as NSString
            var r = NSRange(location: 0, length: s.length)
            while r.length > 0 {
                let f = s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: r)
                guard f.location != NSNotFound, f.length > 0 else { break }
                out.append(.init(entry: i, range: f))
                r = NSRange(location: NSMaxRange(f), length: s.length - NSMaxRange(f))
            }
        }
        return out
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
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            buf.append(chunk)
            guard let nl = buf.lastIndex(of: 10) else { continue }
            let end = nl - buf.startIndex
            for line in buf.prefix(end).split(separator: 10) { entries += TranscriptParser.entries(Data(line), codex: codex) }
            offset += UInt64(end + 1)
            buf = Data(buf.dropFirst(end + 1))
        }
    }
}

/// Background side of transcript Find. A newer call supersedes older ones (their work is skipped or their result dropped).
enum TranscriptSearch {
    private static let queue = DispatchQueue(label: "workbench.transcript", qos: .userInitiated)
    nonisolated(unsafe) private static var indexes: [URL: TranscriptIndex] = [:]   // queue-confined
    private static let generation = Mutex(0)

    /// Supersedes any search in flight.
    static func cancel() { generation.withLock { $0 += 1 } }

    /// The pane's transcript, if an agent runs there.
    static func locate(_ pane: PaneID, done: @escaping @Sendable @MainActor (URL?) -> Void) {
        queue.async {
            let url = Agents.transcript(for: pane)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(url) } }
        }
    }

    static func search(_ url: URL, _ query: String, done: @escaping @Sendable @MainActor (TranscriptResult) -> Void) {
        let mine = generation.withLock { $0 += 1; return $0 }
        queue.async {
            guard generation.withLock({ $0 }) == mine else { return }
            if indexes.count > 3 { indexes = indexes.filter { $0.key == url } }   // ponytail: keeps a few parsed files
            let index = indexes[url] ?? TranscriptIndex(url)
            indexes[url] = index
            if !query.isEmpty { index.update() }
            guard generation.withLock({ $0 }) == mine else { return }
            let result = TranscriptResult(entries: index.entries, matches: TranscriptParser.matches(in: index.entries, query))
            DispatchQueue.main.async {
                guard generation.withLock({ $0 }) == mine else { return }
                MainActor.assumeIsolated { done(result) }
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
}
#endif
