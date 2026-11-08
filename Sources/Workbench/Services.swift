import Foundation

/// A project's dashboard server (Project.dashboardCommand), run behind the scenes while its dashboard is open: no pane,
/// no tab. It runs in a WorkbenchHost session keyed by the project's id, like a pane's shell, so it has the same file
/// access (~/Documents, external drives) and survives a Workbench crash or Restart (reattached at launch). Output goes
/// to Store.directory/services/<project id>.log, emptied at each start. Whatever ends it (exit, crash, kill) starts it
/// again after 1 s, unless it ran under 10 s: a server that cannot start (port taken, bad command) stays down, and its
/// log says why, until the command changes or the dashboard is opened again.
@MainActor final class Services {
    struct Want: Equatable { let command: String; let cwd: String }

    /// The servers that should run: projects with a server command whose dashboard is open in any of their tabs.
    nonisolated static func wanted(_ layout: Layout) -> [UUID: Want] {
        var out: [UUID: Want] = [:]
        for p in layout.projects {
            guard let command = p.dashboardCommand, let url = p.dashboard,
                  p.tabs.contains(where: { $0.root.leaves.contains { $0.kind == .web(url: url) } }) else { continue }
            out[p.id] = Want(command: command, cwd: p.path)
        }
        return out
    }

    nonisolated static var logs: URL { Store.directory.appendingPathComponent("services") }

    private var running: [UUID: (want: Want, session: Session, started: Date)] = [:]
    private var gaveUp: [UUID: Want] = [:]
    private var wanted: [UUID: Want] = [:]

    func sync(_ wanted: [UUID: Want]) {
        self.wanted = wanted
        gaveUp = gaveUp.filter { wanted[$0.key] == $0.value }   // closed, or command changed: may try again
        for (id, r) in running where wanted[id] != r.want { running[id] = nil; r.session.kill() }
        for (id, w) in wanted where running[id] == nil && gaveUp[id] == nil { start(id, w) }
    }

    /// Quit ends every server; Restart (Session.keepOnClose) leaves them running for the next launch to reattach.
    func closeAll() {
        for r in running.values { Session.keepOnClose ? r.session.detach() : r.session.kill() }
        running = [:]
    }

    private func start(_ id: UUID, _ want: Want) {
        try? FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
        let log = Self.logs.appendingPathComponent(id.uuidString + ".log")
        let attached = Session.attach(id)
        if attached == nil { FileManager.default.createFile(atPath: log.path, contents: nil) }
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = want.cwd
        env["TERM"] = "dumb"
        let shell = env["SHELL"] ?? "/bin/zsh"
        guard let session = attached ?? Session.spawn(id, cwd: want.cwd, argv: [shell, "-lc", want.command], env: env, cols: 200, rows: 50),
              let out = try? FileHandle(forWritingTo: log) else { return NSLog("Workbench: dashboard server for \(id) did not start") }
        out.seekToEndOfFile()
        running[id] = (want, session, Date())
        session.start(output: { out.write(Data($0)) }, ended: {
            try? out.close()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id, session) } }
        })
    }

    private func ended(_ id: UUID, _ session: Session) {
        guard let r = running[id], r.session === session else { return }   // stopped on purpose
        running[id] = nil
        if Date().timeIntervalSince(r.started) < 10 {
            gaveUp[id] = r.want
            NSLog("Workbench: dashboard server for \(id) ended within 10 s; not restarting (see its log)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in sync(wanted) }
    }
}

func servicesSelfCheck() {
    let url = "http://127.0.0.1:4747/"
    let web = PaneSpec(id: PaneID(), kind: .web(url: url)), term = PaneSpec(id: PaneID(), kind: .terminal(cwd: "/", launch: nil))
    var p = Project(id: UUID(), path: "/p", name: "p", tabs: [Tab(id: UUID(), title: "t", root: .leaf(term), focused: nil)], activeTab: 0)
    p.dashboard = url
    p.dashboardCommand = "python3 serve.py"
    var layout = Layout.default
    layout.projects = [p]
    assert(Services.wanted(layout).isEmpty, "dashboard not open: no server")
    layout.projects[0].tabs.append(Tab(id: UUID(), title: "u", root: .leaf(web), focused: nil))
    assert(Services.wanted(layout) == [p.id: .init(command: "python3 serve.py", cwd: "/p")], "open in any tab: its server runs")
    layout.projects[0].dashboardCommand = nil
    assert(Services.wanted(layout).isEmpty, "no command: nothing to run")
    print("servicesSelfCheck ok")
}
