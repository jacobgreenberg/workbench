import Foundation
import SQLite3
import Synchronization

/// Finds the Claude Code / Codex process running in each pane, however it was started (`cc1`, `cc2`, plain
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
    static let codexBypass = "--dangerously-bypass-approvals-and-sandbox"
    static let codexHookArgs = #"-c "notify=[\"$PANE_BIN\",\"hook\",\"done\"]""#

    // MARK: launcher discovery

    static func discoverLaunchers() {
        DispatchQueue.global(qos: .utility).async { loadLaunchers() }
    }

    static func loadLaunchers() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasSuffix("zsh") else { return }
        let script = #"for f in ${(ko)functions}; do print -r -- "$f"$'\t'"${functions[$f]//$'\n'/ }"; done"#
        guard let out = capture(shell, ["-ic", script], timeout: 10) else { return }
        let found = parseLaunchers(out, home: NSHomeDirectory())
        launchers.withLock { $0 = found }
    }

    /// Runs a program and returns its stdout, ending at the program's exit or after `timeout` seconds, whichever is
    /// first (nil if it cannot start). Not at EOF: a `.zshrc` that leaves something running with stdout inherited keeps
    /// the pipe open forever. The child leads its own process group, so the timeout's SIGKILL (an interactive zsh
    /// ignores SIGTERM) takes down its children too.
    static func capture(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (rd, wr) = (fds[0], fds[1])
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, wr, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var pid: pid_t = 0
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(wr)
        guard rc == 0 else { close(rd); return nil }
        defer { close(rd); var st: Int32 = 0; waitpid(pid, &st, 0) }

        let kq = kqueue()
        defer { close(kq) }
        var changes = [kevent(ident: UInt(rd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
                       kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)]
        _ = fcntl(rd, F_SETFL, fcntl(rd, F_GETFL) | O_NONBLOCK)
        var out = Data()
        func drain() -> Bool {   // false at EOF
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = read(rd, &buf, buf.count)
                if n > 0 { out.append(contentsOf: buf[..<n]) } else { return n < 0 && errno == EAGAIN }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { kill(-pid, SIGKILL); break }
            var ts = timespec(tv_sec: Int(left), tv_nsec: Int((left - floor(left)) * 1e9))
            var ev = kevent()
            let n = kevent(kq, changes, Int32(changes.count), &ev, 1, &ts)
            changes = []
            if n < 0 && errno != EINTR { kill(-pid, SIGKILL); break }
            guard n > 0 else { continue }
            if ev.filter == Int16(EVFILT_PROC) { break }   // exited; stragglers may still hold the pipe
            if !drain() {   // EOF: stop watching the pipe, still wait for the exit
                changes = [kevent(ident: UInt(rd), filter: Int16(EVFILT_READ), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)]
            }
        }
        _ = drain()
        return String(decoding: out, as: UTF8.self)
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
    struct Session { let cmd: String?; let claude: Bool; let home: String; let id: String?; var pid: pid_t = 0 }

    /// Every pane with an agent running in it → its resume command; nil when the session id can't be read yet (Claude
    /// writes it shortly after starting), so the pane's saved command, typically the exact resume it launched with, stands.
    static func running() -> [PaneID: String?] { sessions().mapValues { $0.cmd } }

    /// The pane's session transcript (Claude `projects/*/<session>.jsonl`, Codex `sessions/Y/M/D/rollout-*-<thread>.jsonl`),
    /// nil if no agent runs there or the file can't be found. Scans processes and the disk: call off the main thread.
    static func transcript(for pane: PaneID) -> URL? { sessions()[pane].flatMap(transcript) }

    /// session id → its jsonl; that never changes, but finding it lists every project folder (hundreds).
    private static let claudeTranscripts = Mutex<[String: URL]>([:])

    /// The folder is a slug of the cwd; find the file by name instead. A remembered path that is gone is searched again.
    static func claudeTranscript(id: String, root: String) -> URL? {
        let fm = FileManager.default, key = "\(root)/\(id)"
        if let url = claudeTranscripts.withLock({ $0[key] }), fm.fileExists(atPath: url.path) { return url }
        let url = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).map { URL(fileURLWithPath: "\(root)/\($0)/\(id).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
        if let url { claudeTranscripts.withLock { $0[key] = url } }
        return url
    }

    private static func transcript(_ s: Session) -> URL? {
        guard let id = s.id?.lowercased() else { return nil }
        let fm = FileManager.default
        if s.claude { return claudeTranscript(id: id, root: s.home + "/projects") }
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

    /// Whether the pane's Claude agent still has work going after its turn ended: background subagents not marked
    /// finished, or background shells / Monitors it started still running, unless they only serve something (see
    /// the rule below). One process scan and at most one 1 s CPU sample for the whole batch; call off the main thread.
    static func backgroundWork(for panes: Set<PaneID>) -> Set<PaneID> {
        let all = sessions()
        var result: Set<PaneID> = []
        var agents: [PaneID: pid_t] = [:]
        for pane in panes {
            guard let s = all[pane], s.claude else { continue }
            if let t = transcript(s), t.pathExtension == "jsonl",
               subagentsRunning(in: t.deletingPathExtension().appendingPathComponent("subagents")) { result.insert(pane) }
            else { agents[pane] = s.pid }
        }
        guard !agents.isEmpty else { return result }
        var children: [pid_t: [pid_t]] = [:]
        for p in allPIDs() { if let pp = parentPID(p) { children[pp, default: []].append(p) } }
        var trees: [PaneID: [[pid_t]]] = [:]
        for (pane, agent) in agents {
            for sh in children[agent] ?? [] where processArgs(sh)?.argv.contains(where: { $0.contains("/shell-snapshots/snapshot-") }) == true {
                var tree = [sh], i = 0
                while i < tree.count { tree += children[tree[i]] ?? []; i += 1 }
                trees[pane, default: []].append(tree)
            }
        }
        let listening = Set(trees.values.joined().joined().filter(listens))
        let sampled = trees.values.joined().filter { $0.contains(where: listening.contains) }.joined()
        var before: [pid_t: UInt64] = [:], after: [pid_t: UInt64] = [:]
        if !sampled.isEmpty {
            before = cpuNanos(Array(sampled))
            Thread.sleep(forTimeInterval: 1)
            after = cpuNanos(Array(sampled))
        }
        return result.union(working(trees: trees, listening: listening, before: before, after: after))
    }

    /// The decision, apart from the process scan: a pane works if any of its shell trees has no listener, or a listening
    /// one used over 20 ms of CPU between the samples. Per process, and only those alive at both samples: one exiting
    /// in between must not count as negative time.
    static func working(trees: [PaneID: [[pid_t]]], listening: Set<pid_t>, before: [pid_t: UInt64], after: [pid_t: UInt64]) -> Set<PaneID> {
        var result: Set<PaneID> = []
        for (pane, list) in trees {
            for tree in list {
                guard tree.contains(where: listening.contains) else { result.insert(pane); break }
                let used = tree.reduce(UInt64(0)) { sum, p in
                    guard let a = after[p] else { return sum }
                    return sum + (a - min(a, before[p] ?? a))
                }
                if used > 20_000_000 { result.insert(pane); break }
            }
        }
        return result
    }

    /// Each subagent leaves `<session>/subagents/agent-*.meta.json`, marked "finished" when it ends; an unfinished one
    /// whose log hasn't moved in 15 min is an orphan of a killed session.
    static func subagentsRunning(in dir: URL) -> Bool {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".meta.json") {
            guard let data = fm.contents(atPath: dir.appendingPathComponent(name).path),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any], meta["finished"] as? Bool != true,
                  let moved = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name.replacingOccurrences(of: ".meta.json", with: ".jsonl")).path)[.modificationDate] as? Date,
                  -moved.timeIntervalSinceNow < 900
            else { continue }
            return true
        }
        return false
    }

    private static func sessions() -> [PaneID: Session] {
        let map = launchers.withLock { $0 }
        let home = NSHomeDirectory()
        var result: [PaneID: Session] = [:]
        var unresolved: [(pane: PaneID, cmd: String, home: String, cwd: String, started: Int)] = []
        var claimed: Set<String> = []
        let sock = Store.directory.appendingPathComponent("pane.sock").path
        for pid in allPIDs() {
            // Identify by argv, not process name: Claude's binary is a versioned file ("2.1.301") behind a symlink.
            guard let ppid = parentPID(pid), ["zsh", "bash", "fish", "sh", "dash"].contains(processName(ppid)),
                  let (argv, env) = processArgs(pid),
                  let pane = env["PANE_ID"].flatMap(UUID.init(uuidString:)),
                  env["PANE_SOCK"] == sock   // another instance (a test copy of the same layout) reuses our pane ids
            else { continue }
            let words = argv.prefix(2).map { ($0 as NSString).lastPathComponent }
            // One-shot runs (`claude -p`, `codex exec`) are not sessions to resume.
            if argv.contains("-p") || argv.contains("--print") || argv.contains("exec") || argv.contains("e") { continue }
            if words.first == "claude" {
                let dir = env["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).standardizingPath } ?? home + "/.claude"
                var cmd = map["claude:" + dir] ?? (env["CLAUDE_CONFIG_DIR"] == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(Runtime.shellEscape(dir)) claude")
                if argv.contains(where: { $0.hasSuffix("/claude-hooks.json") }) { cmd += " " + claudeHookArgs }
                let session = sessionID(claudeDir: dir, pid: pid)
                result[pane] = Session(cmd: session.map { cmd + " --resume \($0)" }, claude: true, home: dir, id: session, pid: pid)
            } else if words.contains("codex") {
                let dir = env["CODEX_HOME"].map { ($0 as NSString).standardizingPath } ?? home + "/.codex"
                // Launchers (gpt1…) pass the bypass flag themselves and Codex rejects it twice; a bare codex gets it here.
                var cmd = map["codex:" + dir] ?? (env["CODEX_HOME"] == nil ? "codex" : "CODEX_HOME=\(Runtime.shellEscape(dir)) codex") + " " + codexBypass
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

    /// Top-level terminal threads for a folder, most recently active first (subagent, Desktop and extension threads excluded).
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
        // Terminal threads: originator codex-tui (`source` became "vscode" for them in newer Codex), not a subagent.
        let sql = "select id from threads where cwd = ?1 and originator = 'codex-tui' and thread_source = 'user' and archived = 0 order by updated_at_ms desc limit 32"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, cwd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c).lowercased()) }
        return ids
    }

    /// Claude runs Bash and Monitor commands as `zsh -c source <config>/shell-snapshots/snapshot-… && eval '…'`, children
    /// of the agent; after a turn ends only background ones remain. A shell counts as work unless its process tree
    /// listens on TCP and used under 2% of a core over 1 s: a dev server waiting for requests, not a job.
    /// ponytail: a quiet watcher with no port (tsc --watch) still counts as work; match commands if that bites.
    private static func listens(_ pid: pid_t) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)) / MemoryLayout<proc_fdinfo>.stride
        for fd in fds.prefix(max(got, 0)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
               info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN { return true }
        }
        return false
    }

    /// CPU time used so far by each pid still alive.
    private static func cpuNanos(_ pids: [pid_t]) -> [pid_t: UInt64] {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        var result: [pid_t: UInt64] = [:]
        for pid in pids {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            result[pid] = (info.pti_total_user + info.pti_total_system) * UInt64(tb.numer) / UInt64(tb.denom)
        }
        return result
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
    let sub = URL(fileURLWithPath: dir + "/subagents")
    try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    func agent(_ name: String, finished: Bool, age: TimeInterval) {
        try! Data(finished ? #"{"finished":true}"#.utf8 : #"{"agentType":"x"}"#.utf8).write(to: sub.appendingPathComponent(name + ".meta.json"))
        let log = sub.appendingPathComponent(name + ".jsonl").path
        FileManager.default.createFile(atPath: log, contents: Data())
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: log)
    }
    agent("agent-a", finished: true, age: 0)
    agent("agent-b", finished: false, age: 3600)   // orphan of a killed session
    assert(!Agents.subagentsRunning(in: sub))
    agent("agent-c", finished: false, age: 10)
    assert(Agents.subagentsRunning(in: sub))
    var db: OpaquePointer?
    sqlite3_open(dir + "/state_5.sqlite", &db)
    sqlite3_exec(db, """
        create table threads (id text, cwd text, originator text, thread_source text, archived int, updated_at_ms int);
        insert into threads values ('A', '/p', 'codex-tui', 'user', 0, 1), ('B', '/p', 'codex-tui', 'user', 0, 3),
            ('C', '/p', 'codex-tui', 'subagent', 0, 9), ('D', '/p', 'codex-tui', 'user', 1, 9), ('E', '/q', 'codex-tui', 'user', 0, 9),
            ('F', '/p', 'Codex Desktop', 'user', 0, 9), ('G', '/p', 'codex_exec', 'user', 0, 9);
        """, nil, nil, nil)
    sqlite3_close(db)
    assert(Agents.recentThreads(codexHome: dir, cwd: "/p") == ["b", "a"])
    let p1 = UUID(), p2 = UUID()
    func w(_ trees: [PaneID: [[pid_t]]], _ l: Set<pid_t>, _ b: [pid_t: UInt64], _ a: [pid_t: UInt64]) -> Set<PaneID> {
        Agents.working(trees: trees, listening: l, before: b, after: a)
    }
    assert(w([p1: [[1, 2]]], [], [:], [:]) == [p1])   // no listener
    assert(w([p1: [[1, 2]]], [2], [1: 0, 2: 0], [1: 10_000_000, 2: 20_000_000]) == [p1])   // 30 ms
    assert(w([p1: [[1, 2]]], [2], [1: 0, 2: 0], [1: 2_000_000, 2: 3_000_000]).isEmpty)   // 5 ms
    assert(w([p1: [[1, 2]]], [2], [1: 0, 2: 100], [1: 1_000_000]).isEmpty)   // pid 2 vanished: not negative, not counted
    assert(w([p1: [[1, 2]], p2: [[3]]], [2, 3], [1: 0, 2: 0, 3: 0], [1: 30_000_000, 2: 0, 3: 1_000_000]) == [p1])   // independent
    assert(w([p1: [[1], [2]]], [1], [1: 0], [1: 0]) == [p1])   // any tree without a listener

    // Claude transcript lookup: found by name in any project folder; remembered; searched again once the file moves.
    let root = dir + "/projects"
    let id = UUID().uuidString.lowercased()
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    for f in ["-a", "-b"] { try! FileManager.default.createDirectory(atPath: root + "/" + f, withIntermediateDirectories: true) }
    let first = URL(fileURLWithPath: "\(root)/-a/\(id).jsonl")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    assert(Agents.claudeTranscript(id: id, root: root) == first)
    chmod(root, 0o100)   // searchable but not listable: only a remembered path can still be found
    assert(Agents.claudeTranscript(id: id, root: root) == first, "second lookup must not list the folders again")
    chmod(root, 0o700)
    let moved = URL(fileURLWithPath: "\(root)/-b/\(id).jsonl")
    try! FileManager.default.moveItem(at: first, to: moved)
    assert(Agents.claudeTranscript(id: id, root: root) == moved)
    assert(Agents.claudeTranscript(id: UUID().uuidString, root: root) == nil)

    // Launcher discovery's capture ends at the child's exit, not at EOF, and never waits on a hung or stubborn child.
    func timed(_ script: String, timeout: TimeInterval) -> (String?, TimeInterval) {
        let t0 = Date()
        return (Agents.capture("/bin/sh", ["-c", script], timeout: timeout), Date().timeIntervalSince(t0))
    }
    var r = timed("echo one; echo two", timeout: 10)
    assert(r.0 == "one\ntwo\n" && r.1 < 5, "\(r)")
    r = timed("echo hi; sleep 6 &", timeout: 10)   // the sleep inherits stdout and keeps the pipe open
    assert(r.0 == "hi\n" && r.1 < 4, "exit, not EOF: \(r)")
    r = timed("echo partial; trap '' TERM; sleep 30", timeout: 1)   // ignores SIGTERM
    assert(r.0 == "partial\n" && r.1 < 4, "killed at the timeout: \(r)")
    assert(Agents.capture("/nonexistent/zsh", [], timeout: 1) == nil)
}
#endif
