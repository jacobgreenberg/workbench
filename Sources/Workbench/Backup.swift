import AppKit

struct BackupError: Error, Sendable { let message: String }

extension Notification.Name {
    /// Posted by BackupSync when `status` changes.
    static let backupStatusChanged = Notification.Name("WorkbenchBackupStatusChanged")
}

/// Everything that makes the app yours as one JSON file: the layout (projects and their order, tabs and splits,
/// workspaces, theme), user themes, workspace images and the Ghostty config.
struct Backup: Codable, Sendable {
    var version: Int
    var exported: Date
    var layout: Layout
    var themes: [String: String]   // file name in Theme.userDirectory -> contents
    var images: [String: Data]     // file name in Store.workspaceImages -> bytes, base64 in JSON
    var ghosttyConfig: String?     // ~/.config/ghostty/config, when it exists

    static let currentVersion = 1
    static let fileName = "workbench.json"   // the file git sync writes in the repo
    nonisolated static let ghosttyConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config")

    @MainActor static func current(_ layout: Layout) -> Backup {
        var l = layout
        let active = l.projects.indices.contains(l.activeProject) ? l.projects[l.activeProject].id : nil
        l.projects.removeAll { $0.scratch == true }
        l.activeProject = l.projects.firstIndex { $0.id == active } ?? (l.projects.isEmpty ? -1 : 0)
        l.backupRepo = nil
        var themes: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Theme.userDirectory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let d = readFile(f, cap: 1 << 20), let s = String(data: d, encoding: .utf8) { themes[f.lastPathComponent] = s }
        }
        var images: [String: Data] = [:]
        for name in (l.workspaces ?? []).compactMap(\.image) {
            if let d = readFile(Store.workspaceImages.appendingPathComponent(name), cap: 16 << 20) { images[name] = d }
        }
        let ghostty = readFile(ghosttyConfigURL, cap: 1 << 20).flatMap { String(data: $0, encoding: .utf8) }
        return Backup(version: currentVersion, exported: Date(), layout: l, themes: themes, images: images, ghosttyConfig: ghostty)
    }

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) throws -> Backup {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let b: Backup
        do { b = try dec.decode(Backup.self, from: data) } catch {
            throw BackupError(message: "This isn't a Workbench backup (\(error.localizedDescription))")
        }
        if b.version > currentVersion {
            throw BackupError(message: "This backup is from a newer Workbench (format \(b.version)). Update Workbench to restore it.")
        }
        func valid(_ k: String) -> Bool { !k.isEmpty && !k.hasPrefix(".") && !k.contains("/") && !k.contains(":") }
        for k in b.themes.keys where !valid(k) || !k.hasSuffix(".json") {
            throw BackupError(message: "The backup contains an invalid file name: \(k)")
        }
        for k in b.images.keys where !valid(k) {
            throw BackupError(message: "The backup contains an invalid file name: \(k)")
        }
        return b
    }

    var missingProjects: [Project] {
        layout.projects.filter {
            var isDir: ObjCBool = false
            return $0.scratch != true && !(FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    mutating func relocate(project id: UUID, to path: String) {
        guard let i = layout.projects.firstIndex(where: { $0.id == id }) else { return }
        let old = layout.projects[i].path
        layout.projects[i].path = path
        func moved(_ v: String) -> String { v == old || v.hasPrefix(old + "/") ? path + v.dropFirst(old.count) : v }
        for t in layout.projects[i].tabs.indices {
            layout.projects[i].tabs[t].root = layout.projects[i].tabs[t].root.mapLeaves { s in
                switch s.kind {
                case .terminal(let cwd, let launch): s.kind = .terminal(cwd: moved(cwd), launch: launch)
                case .file(let p): s.kind = .file(path: moved(p))
                }
            }
        }
    }

    mutating func remove(project id: UUID) {
        let active = layout.projects.indices.contains(layout.activeProject) ? layout.projects[layout.activeProject].id : nil
        layout.projects.removeAll { $0.id == id }
        layout.activeProject = layout.projects.firstIndex { $0.id == active } ?? (layout.projects.isEmpty ? -1 : 0)
        for i in (layout.workspaces ?? []).indices where layout.workspaces?[i].lastProject == id { layout.workspaces?[i].lastProject = nil }
    }

    /// The current setup, saved before an import replaces it.
    @MainActor static func saveCurrent(_ layout: Layout) throws -> URL {
        let dir = Store.directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("workbench-\(f.string(from: Date())).json")
        try current(layout).encoded().write(to: url, options: .atomic)
        return url
    }

    /// Writes this backup over the app's state (called at quit, after the old layout's final save); themes and
    /// images are added or overwritten, never deleted; layout.json keeps this Mac's `backupRepo`.
    @MainActor func install(backupRepo: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Theme.userDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: Store.workspaceImages, withIntermediateDirectories: true)
        for (name, text) in themes { try Data(text.utf8).write(to: Theme.userDirectory.appendingPathComponent(name), options: .atomic) }
        for (name, data) in images { try data.write(to: Store.workspaceImages.appendingPathComponent(name), options: .atomic) }
        if let ghosttyConfig {
            try fm.createDirectory(at: Backup.ghosttyConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ghosttyConfig.utf8).write(to: Backup.ghosttyConfigURL, options: .atomic)
        }
        var l = layout
        l.backupRepo = backupRepo
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(l).write(to: Store.directory.appendingPathComponent("layout.json"), options: .atomic)
    }
}

/// Git sync of workbench.json: a minute after the last change, write it into the repo, commit if it changed, and
/// push; the user's own git and credentials.
@MainActor final class BackupSync {
    static let shared = BackupSync()
    private(set) var status = ""   // shown in Settings > Backup
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "workbench.backup-sync")   // serial: syncs and pulls never overlap

    func scheduleSync(_ store: Store) {
        guard store.layout.backupRepo != nil else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self, weak store] in
            MainActor.assumeIsolated { if let store { self?.syncNow(store) } }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    func syncNow(_ store: Store) {
        pending?.cancel()
        pending = nil
        guard let repo = store.layout.backupRepo else { return }
        let data = Backup.current(store.layout).encoded()
        queue.async {
            var failure: String?
            do {
                try data.write(to: URL(fileURLWithPath: repo).appendingPathComponent(Backup.fileName), options: .atomic)
                let add = BackupSync.git(repo, ["add", Backup.fileName])
                if add.status != 0 { failure = add.message }
                else if BackupSync.git(repo, ["diff", "--cached", "--quiet"]).status == 1 {
                    let c = BackupSync.git(repo, ["commit", "-q", "-m", "Workbench backup"])
                    if c.status != 0 { failure = c.message }
                }
                if failure == nil {
                    let p = BackupSync.git(repo, ["push", "-q"])
                    if p.status != 0 { failure = p.message }
                }
            } catch { failure = error.localizedDescription }
            let result = failure.map { "Sync failed: \($0)" }
                ?? "Synced at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.status = result
                    NotificationCenter.default.post(name: .backupStatusChanged, object: nil)
                }
            }
        }
    }

    func pull(repo: String, completion: @escaping @MainActor @Sendable (Result<Backup, BackupError>) -> Void) {
        queue.async {
            let result: Result<Backup, BackupError>
            let r = BackupSync.git(repo, ["pull", "-q", "--ff-only"])
            if r.status != 0 {
                result = .failure(BackupError(message: "git pull failed: \(r.message)"))
            } else if let data = readFile(URL(fileURLWithPath: repo).appendingPathComponent(Backup.fileName), cap: 64 << 20) {
                result = Result { try Backup.decode(data) }.mapError { $0 as? BackupError ?? BackupError(message: $0.localizedDescription) }
            } else {
                result = .failure(BackupError(message: "There's no \(Backup.fileName) in \(repo)."))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    nonisolated private static func git(_ repo: String, _ args: [String]) -> (status: Int32, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo] + args
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }   // fail instead of waiting on a password prompt nobody sees
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return (p.terminationStatus, line ?? "git \(args[0]) exited with \(p.terminationStatus)")
    }
}

#if DEBUG
@MainActor func backupSelfCheck() {
    let leafA = PaneSpec(id: UUID(), kind: .terminal(cwd: "/nonexistent-wb-a/src", launch: nil))
    let leafB = PaneSpec(id: UUID(), kind: .file(path: "/nonexistent-wb-a/README.md"))
    let leafC = PaneSpec(id: UUID(), kind: .terminal(cwd: "/nonexistent-wb-ab", launch: nil))
    let tab = Tab(id: UUID(), title: "t", root: .split(axis: .horizontal, ratio: 0.5, a: .leaf(leafA),
                  b: .split(axis: .vertical, ratio: 0.5, a: .leaf(leafB), b: .leaf(leafC))), focused: nil)
    let p0 = Project(id: UUID(), path: "/nonexistent-wb-a", name: "a", tabs: [tab], activeTab: 0)
    let p1 = Project(id: UUID(), path: NSTemporaryDirectory(), name: "b", tabs: [], activeTab: 0)
    var p2 = Project(id: UUID(), path: "/tmp", name: "c", tabs: [], activeTab: 0)
    p2.scratch = true
    var l = Layout(projects: [p0, p1, p2], activeProject: 1, sidebarVisible: true, theme: "x")
    l.backupRepo = "/r"
    let b = Backup(version: 1, exported: Date(), layout: l, themes: [:], images: [:], ghosttyConfig: nil)
    assert(b.missingProjects.map(\.id) == [p0.id])
    assert((try! Backup.decode(b.encoded())).layout == b.layout)
    var bad = b
    bad.version = 99
    assert((try? Backup.decode(bad.encoded())) == nil)
    bad = b
    bad.themes = ["../x.json": "{}"]
    assert((try? Backup.decode(bad.encoded())) == nil)
    bad = b
    bad.images = [".hidden": Data()]
    assert((try? Backup.decode(bad.encoded())) == nil)

    var r = b
    r.relocate(project: p0.id, to: "/new")
    assert(r.layout.projects[0].path == "/new")
    assert(r.layout.projects[0].tabs[0].root.leaves.map(\.kind) ==
           [.terminal(cwd: "/new/src", launch: nil), .file(path: "/new/README.md"), .terminal(cwd: "/nonexistent-wb-ab", launch: nil)])

    var d = b
    d.layout.workspaces = [Workspace(id: UUID(), name: "W", lastProject: p0.id)]
    d.remove(project: p0.id)
    assert(d.layout.projects.count == 2 && d.layout.projects[d.layout.activeProject].id == p1.id)
    assert(d.layout.workspaces?[0].lastProject == nil)

    let c = Backup.current(l)
    assert(c.layout.projects.count == 2 && c.layout.projects[c.layout.activeProject].id == p1.id)
    assert(c.layout.backupRepo == nil)
}
#endif
