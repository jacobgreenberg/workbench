import Foundation
import SQLite3
import Synchronization

/// Finds the Claude Code / Codex process running in each pane, however it was started (preset, `cc2`, plain
/// `claude`), and turns it into the command that resumes it through the same launcher.
///
/// A pane's processes inherit its PANE_ID, so agents are found by reading process environments; the agent is the
/// one whose parent is the pane's shell (Codex's background daemons are reparented to launchd and so excluded).
/// The launcher (`cc1`, `cc2`, `gpt1`…) is recovered from the profile directory the agent runs with, matched against
/// the user's shell functions that set it.
enum Agents {
    /// "claude:<config dir>" / "codex:<codex home>" → launcher function name. Filled once at launch.
    private static let launchers = Mutex<[String: String]>([:])

    static let claudeHookArgs = #"--settings "$PANE_CLAUDE_SETTINGS""#
    static let codexHookArgs = #"-c "notify=[\"$PANE_BIN\",\"hook\",\"done\"]""#

    // MARK: launcher discovery

    static func discoverLaunchers() {
        DispatchQueue.global(qos: .utility).async { loadLaunchers() }
    }

    static func loadLaunchers() {
        do {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard shell.hasSuffix("zsh") else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-ic", #"for f in ${(ko)functions}; do print -r -- "$f"$'\t'"${functions[$f]//$'\n'/ }"; done"#]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let killer = DispatchWorkItem { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            killer.cancel()
            let found = parseLaunchers(out, home: NSHomeDirectory())
            launchers.withLock { $0 = found }
        }
    }

    /// Lines of "name<TAB>body". A function is a Claude launcher if it runs `claude`, a Codex launcher if it runs
    /// `codex` (and not `claude`); its profile is the CLAUDE_CONFIG_DIR / CODEX_HOME it sets, else the default.
    static func parseLaunchers(_ out: String, home: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            let name = String(parts[0]), body = String(parts[1])
            let key: String
            if body.contains(runsClaude) {
                key = "claude:" + (value(of: "CLAUDE_CONFIG_DIR", in: body, home: home) ?? home + "/.claude")
            } else if body.contains(runsCodex) {
                key = "codex:" + (value(of: "CODEX_HOME", in: body, home: home) ?? home + "/.codex")
            } else { continue }
            if map[key] == nil || name.count < map[key]!.count { map[key] = name }   // shortest name wins (cc1 over cc1-debug)
        }
        return map
    }

    // Compiled once; a large zsh setup has hundreds of functions.
    nonisolated(unsafe) private static let runsClaude = try! Regex(#"(^|[\s;|&(])claude(\s|$)"#)
    nonisolated(unsafe) private static let runsCodex = try! Regex(#"(^|[\s;|&(])codex(\s|$)"#)
    nonisolated(unsafe) private static let assignment = [
        "CLAUDE_CONFIG_DIR": try! Regex(#"CLAUDE_CONFIG_DIR=("[^"]*"|'[^']*'|[^\s;]+)"#),
        "CODEX_HOME": try! Regex(#"CODEX_HOME=("[^"]*"|'[^']*'|[^\s;]+)"#),
    ]

    private static func value(of variable: String, in body: String, home: String) -> String? {
        guard let m = body.firstMatch(of: assignment[variable]!) else { return nil }
        var v = String(body[m.range].dropFirst(variable.count + 1))
        if v.first == "\"" || v.first == "'" { v = String(v.dropFirst().dropLast()) }
        v = v.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if v.hasPrefix("~") { v = home + v.dropFirst() }
        return (v as NSString).standardizingPath
    }

    // MARK: process scan

    /// An agent found in a pane: its resume command (nil when the session id can't be read yet), the profile dir it
    /// runs with, and the Claude session id / Codex thread id (nil = not known).
    struct Session { let cmd: String?; let claude: Bool; let home: String; let id: String? }

    /// Every pane with an agent running in it → its resume command; nil when the session id can't be read yet (Claude
    /// writes it shortly after starting), so the pane's saved command, typically the exact resume it launched with, stands.
    static func running() -> [PaneID: String?] { sessions().mapValues { $0.cmd } }

    /// The pane's session transcript (Claude `projects/*/<session>.jsonl`, Codex `sessions/Y/M/D/rollout-*-<thread>.jsonl`),
    /// nil if no agent runs there or the file can't be found. Scans processes and the disk: call off the main thread.
    static func transcript(for pane: PaneID) -> URL? {
        guard let s = sessions()[pane], let id = s.id?.lowercased() else { return nil }
        let fm = FileManager.default
        if s.claude {   // the folder is a slug of the cwd; find the file by name instead
            let root = s.home + "/projects"
            return ((try? fm.contentsOfDirectory(atPath: root)) ?? []).map { URL(fileURLWithPath: "\(root)/\($0)/\(id).jsonl") }
                .first { fm.fileExists(atPath: $0.path) }
        }
        func newestFirst(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for y in newestFirst(URL(fileURLWithPath: s.home + "/sessions").resolvingSymlinksInPath()) {
            for m in newestFirst(y) { for d in newestFirst(m) {
                if let f = newestFirst(d).first(where: { $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.lowercased().hasSuffix("-\(id).jsonl") }) { return f }
            } }
        }
        return nil
    }

    private static func sessions() -> [PaneID: Session] {
        let map = launchers.withLock { $0 }
        let home = NSHomeDirectory()
        var result: [PaneID: Session] = [:]
        var unresolved: [(pane: PaneID, cmd: String, home: String, cwd: String, started: Int)] = []
        var claimed: Set<String> = []
        for pid in allPIDs() {
            // Identify by argv, not process name: Claude's binary is a versioned file ("2.1.301") behind a symlink.
            guard let ppid = parentPID(pid), ["zsh", "bash", "fish", "sh", "dash"].contains(processName(ppid)),
                  let (argv, env) = processArgs(pid),
                  let pane = env["PANE_ID"].flatMap(UUID.init(uuidString:))
            else { continue }
            let words = argv.prefix(2).map { ($0 as NSString).lastPathComponent }
            // One-shot runs (`claude -p`, `codex exec`) are not sessions to resume.
            if argv.contains("-p") || argv.contains("--print") || argv.contains("exec") || argv.contains("e") { continue }
            if words.first == "claude" {
                let dir = env["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).standardizingPath } ?? home + "/.claude"
                var cmd = map["claude:" + dir] ?? (env["CLAUDE_CONFIG_DIR"] == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(Runtime.shellEscape(dir)) claude")
                if argv.contains(where: { $0.hasSuffix("/claude-hooks.json") }) { cmd += " " + claudeHookArgs }
                let session = sessionID(claudeDir: dir, pid: pid)
                result[pane] = Session(cmd: session.map { cmd + " --resume \($0)" }, claude: true, home: dir, id: session)
            } else if words.contains("codex") {
                let dir = env["CODEX_HOME"].map { ($0 as NSString).standardizingPath } ?? home + "/.codex"
                var cmd = map["codex:" + dir] ?? (env["CODEX_HOME"] == nil ? "codex" : "CODEX_HOME=\(Runtime.shellEscape(dir)) codex")
                if argv.contains(where: { $0.hasPrefix("notify=") && $0.contains("hook") }) { cmd += " " + codexHookArgs }
                // A thread resumed by id names itself in argv. Otherwise a running Codex does not expose its thread,
                // so it gets one from the state db below; `resume --last` would send every pane in a folder to the
                // same thread, which Codex then refuses as open elsewhere.
                if let i = argv.firstIndex(of: "resume"), i + 1 < argv.count, UUID(uuidString: argv[i + 1]) != nil {
                    claimed.insert(argv[i + 1].lowercased())
                    result[pane] = Session(cmd: cmd + " resume " + argv[i + 1], claude: false, home: dir, id: argv[i + 1])
                } else if let cwd = processCwd(pid) {
                    unresolved.append((pane, cmd, dir, cwd, startTime(pid)))
                }
            }
        }
        // ponytail: newest process gets the most recently active unclaimed thread of its folder; two unresumed Codex
        // panes in one folder can swap conversations, never share one. Exact ids need Codex's SessionStart hook.
        for group in Dictionary(grouping: unresolved, by: { $0.home + "\0" + $0.cwd }).values {
            var threads = recentThreads(codexHome: group[0].home, cwd: group[0].cwd).filter { !claimed.contains($0) }.makeIterator()
            for p in group.sorted(by: { $0.started > $1.started }) {
                let thread = threads.next()
                result[p.pane] = Session(cmd: thread.map { p.cmd + " resume " + $0 } ?? p.cmd, claude: false, home: p.home, id: thread)
            }
        }
        return result
    }

    /// Top-level CLI threads for a folder, most recently active first (subagent and IDE threads excluded).
    static func recentThreads(codexHome: String, cwd: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: codexHome)) ?? []
        // state_5.sqlite today; take the highest schema version present.
        guard let name = files.filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") })
            .max(by: { $0.localizedStandardCompare($1) == .orderedAscending }) else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(codexHome + "/" + name, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "select id from threads where cwd = ?1 and source = 'cli' and archived = 0 order by updated_at_ms desc limit 32"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, cwd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c).lowercased()) }
        return ids
    }

    private static func processCwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func startTime(_ pid: pid_t) -> Int {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? Int(info.pbi_start_tvsec) : 0
    }

    private static func sessionID(claudeDir: String, pid: pid_t) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(claudeDir)/sessions/\(pid).json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sessionId"] as? String
    }

    private static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = Int(proc_name(pid, &buf, UInt32(buf.count)))
        return n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : ""
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }

    private static func processArgs(_ pid: pid_t) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// KERN_PROCARGS2 layout: Int32 argc, exec path, NUL padding, argc argument strings, then environment strings
    /// up to an empty one.
    static func parseProcArgs(_ b: [UInt8]) -> (argv: [String], env: [String: String])? {
        guard b.count > 4 else { return nil }
        let argc = Int(b.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }        // exec path
        while i < b.count, b[i] == 0 { i += 1 }        // padding
        func next() -> String? {
            guard i < b.count else { return nil }
            let start = i
            while i < b.count, b[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        var argv: [String] = []
        for _ in 0..<argc { guard let s = next() else { return nil }; argv.append(s) }
        var env: [String: String] = [:]
        while let s = next(), !s.isEmpty {
            if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
        }
        return (argv, env)
    }
}

#if DEBUG
func agentsSelfCheck() {
    let home = "/Users/u"
    let out = """
    cc1\t~/.claude-shared/cc-sync.sh "$HOME/.claude-me" ; CLAUDE_CONFIG_DIR="$HOME/.claude-me" CODEX_HOME="$HOME/.codex-1" claude --chrome "$@"
    cc2\tCLAUDE_CONFIG_DIR="$HOME/.claude-me2" claude "$@"
    gpt1\t"$HOME/.codex-shared/codex-sync.sh" || [[ $? -eq 75 ]] ; CODEX_HOME="$HOME/.codex-1" codex $CODEX_YOLO "$@"
    wrap\tcc1 --model x
    junk line from zshrc
    """
    let m = Agents.parseLaunchers(out, home: home)
    assert(m["claude:/Users/u/.claude-me"] == "cc1" && m["claude:/Users/u/.claude-me2"] == "cc2")
    assert(m["codex:/Users/u/.codex-1"] == "gpt1" && m.count == 3)

    var b: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
    for s in ["/bin/claude", "", "", "claude", "", "--resume", "A=1", "PANE_ID=x", ""] { b += Array(s.utf8) + [0] }
    let parsed = Agents.parseProcArgs(b)
    assert(parsed?.argv == ["claude", "", "--resume"] && parsed?.env == ["A": "1", "PANE_ID": "x"])

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var db: OpaquePointer?
    sqlite3_open(dir + "/state_5.sqlite", &db)
    sqlite3_exec(db, """
        create table threads (id text, cwd text, source text, archived int, updated_at_ms int);
        insert into threads values ('A', '/p', 'cli', 0, 1), ('B', '/p', 'cli', 0, 3), ('C', '/p', '{"subagent":1}', 0, 9),
            ('D', '/p', 'cli', 1, 9), ('E', '/q', 'cli', 0, 9);
        """, nil, nil, nil)
    sqlite3_close(db)
    assert(Agents.recentThreads(codexHome: dir, cwd: "/p") == ["b", "a"])
}
#endif
