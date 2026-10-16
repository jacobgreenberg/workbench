import AppKit
@preconcurrency import GhosttyKit

#if DEBUG
if CommandLine.arguments.contains("--selfcheck") {
    MainActor.assumeIsolated { modelSelfCheck() }
    themeSelfCheck()
    controlSelfCheck()
    print("selfcheck ok")
    exit(0)
}
#endif

if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "pane" {
    exit(ControlClient.run(Array(CommandLine.arguments.dropFirst())))
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
