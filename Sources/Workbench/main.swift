import AppKit
@preconcurrency import GhosttyKit

#if DEBUG
if CommandLine.arguments.contains("--selfcheck") {
    MainActor.assumeIsolated { modelSelfCheck() }
    themeSelfCheck()
    controlSelfCheck()
    agentsSelfCheck()
    print("selfcheck ok")
    exit(0)
}
if CommandLine.arguments.contains("--agents") {   // what quit would record for each pane's running agent
    Agents.loadLaunchers()
    for (pane, cmd) in Agents.running() { print(pane, cmd) }
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
