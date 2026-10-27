import AppKit
@preconcurrency import GhosttyKit

#if DEBUG
if CommandLine.arguments.contains("--selfcheck") {
    MainActor.assumeIsolated { modelSelfCheck(); backupSelfCheck(); FileIcons.selfCheck(); filePaneSelfCheck() }
    themeSelfCheck()
    fileTreeSelfCheck()
    controlSelfCheck()
    agentsSelfCheck()
    transcriptSelfCheck()
    gitCloneSelfCheck()
    print("selfcheck ok")
    exit(0)
}
if CommandLine.arguments.contains("--agents") {   // what quit would record for each pane's running agent
    Agents.loadLaunchers()
    let t0 = Date()
    let runningAgents = Agents.running()
    let working = Agents.backgroundWork(for: Set(runningAgents.keys))
    for (pane, cmd) in runningAgents { print(pane, cmd ?? "(id not known yet; keeps saved command)", Agents.transcript(for: pane)?.path ?? "(no transcript)", working.contains(pane) ? "(background work)" : "") }
    FileHandle.standardError.write(Data("scan: \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".utf8))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--clonewatch"), i + 1 < CommandLine.arguments.count {   // --clonewatch <file>: what a clone pane's output (e.g. `script` of git clone) reports
    let w = CloneWatch()
    let data = FileManager.default.contents(atPath: CommandLine.arguments[i + 1]) ?? Data()
    let chunk = i + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 2]) ?? data.count : data.count   // as the pty delivers it
    for start in stride(from: 0, to: data.count, by: max(1, chunk)) {
        for e in data[start..<min(data.count, start + chunk)].withUnsafeBytes({ w.scan($0) }) { print(e) }
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--transcript"), i + 2 < CommandLine.arguments.count {   // --transcript <file> <query>: parse + search timing
    let t0 = Date()
    let index = TranscriptIndex(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    index.update()
    let t1 = Date()
    let m = TranscriptParser.matches(in: index.entries, CommandLine.arguments[i + 2])
    print("\(index.entries.count) entries, \(m.count) matches; parse \(Int(t1.timeIntervalSince(t0) * 1000)) ms, search \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
    exit(0)
}
#endif

if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "pane" {
    exit(ControlClient.run(Array(CommandLine.arguments.dropFirst())))
}

// One instance per state directory: the lock holder owns the socket and layout.json. The fd stays open for the
// process lifetime; O_CLOEXEC keeps terminal children from inheriting (and outliving us with) the lock.
try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
let instanceLock = open(Store.directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    let me = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .first { $0.processIdentifier != me }?.activate()
    exit(0)
}

// Launched from inside an agent (`open` in a Claude/Codex shell), we inherit that session's markers, and every pane
// would too: a Claude started there believes it is a child session and stops saving its transcript.
for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("CODEX_") {
    unsetenv(key)
}

if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
