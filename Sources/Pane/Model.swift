import Foundation

typealias PaneID = UUID

enum Agent: String, Codable, Sendable { case claude, codex }

struct Launch: Codable, Equatable, Sendable {
    var command: String
    var resume: String?
    var agent: Agent?
    var sessionID: String?
    var scrollbackLimit: Int?

    var commandLine: String {
        if let id = sessionID, let r = resume {
            return r.replacingOccurrences(of: "{id}", with: id)
        }
        return command
    }
}

enum PaneKind: Codable, Equatable, Sendable {
    case terminal(cwd: String, launch: Launch?)
    case markdown(path: String)
}

struct PaneSpec: Codable, Equatable, Sendable {
    var id: PaneID
    var kind: PaneKind
}

enum Axis: String, Codable, Sendable {
    case horizontal
    case vertical
}

indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(PaneSpec)
    case split(axis: Axis, ratio: Double, a: SplitNode, b: SplitNode)
}

extension SplitNode {
    var leaves: [PaneSpec] {
        switch self {
        case .leaf(let s): return [s]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ id: PaneID) -> Bool {
        leaves.contains { $0.id == id }
    }

    func replacing(_ id: PaneID, with node: SplitNode) -> SplitNode {
        switch self {
        case .leaf(let s):
            return s.id == id ? node : self
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, a: a.replacing(id, with: node), b: b.replacing(id, with: node))
        }
    }

    func removing(_ id: PaneID) -> SplitNode? {
        switch self {
        case .leaf(let s):
            return s.id == id ? nil : self
        case .split(let axis, let ratio, let a, let b):
            guard contains(id) else { return self }
            let na = a.removing(id)
            let nb = b.removing(id)
            if let na, let nb { return .split(axis: axis, ratio: ratio, a: na, b: nb) }
            return na ?? nb
        }
    }

    func updating(_ id: PaneID, _ f: (inout PaneSpec) -> Void) -> SplitNode {
        switch self {
        case .leaf(var s):
            if s.id == id { f(&s) }
            return .leaf(s)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, a: a.updating(id, f), b: b.updating(id, f))
        }
    }

    func equalized() -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let axis, _, let a, let b):
            return .split(axis: axis, ratio: 0.5, a: a.equalized(), b: b.equalized())
        }
    }
}

struct Tab: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var root: SplitNode
    var focused: PaneID?
}

struct Project: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var path: String
    var name: String
    var tabs: [Tab]
    var activeTab: Int
}

struct Preset: Codable, Equatable, Sendable {
    var key: Int
    var name: String
    var command: String
    var resume: String?
    var agent: Agent?
    var scrollbackLimit: Int?
}

struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]
    var activeProject: Int
    var sidebarVisible: Bool
    var theme: String
    var presets: [Preset]

    static let `default` = Layout(
        projects: [],
        activeProject: 0,
        sidebarVisible: true,
        theme: "oceanic-v2",
        presets: [
            Preset(key: 1, name: "Claude",
                   command: "cc1 --settings \"$PANE_CLAUDE_SETTINGS\"",
                   resume: "cc1 --settings \"$PANE_CLAUDE_SETTINGS\" --resume {id}",
                   agent: .claude, scrollbackLimit: nil),
            Preset(key: 2, name: "Codex",
                   command: "gpt1 -c \"notify=[\\\"$PANE_BIN\\\",\\\"hook\\\",\\\"done\\\"]\"",
                   resume: "gpt1 -c \"notify=[\\\"$PANE_BIN\\\",\\\"hook\\\",\\\"done\\\"]\" resume {id}",
                   agent: .codex, scrollbackLimit: nil),
        ]
    )
}

@MainActor final class Store {
    static let directory: URL = {
        #if DEBUG
        // Test isolation: a debug instance can run beside the real app without sharing its socket or layout.
        if let dir = ProcessInfo.processInfo.environment["PANE_STATE_DIR"] { return URL(fileURLWithPath: dir) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pane")
    }()

    var layout: Layout
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "pane.store")

    init() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        let url = Store.directory.appendingPathComponent("layout.json")
        let data = try? Data(contentsOf: url)
        let decoded = data.flatMap { try? JSONDecoder().decode(Layout.self, from: $0) }
        if data != nil, decoded == nil {
            // Never overwrite a layout we failed to read; keep it for recovery.
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak"))
        }
        var l = decoded ?? Layout.default
        l.activeProject = l.projects.isEmpty ? 0 : min(max(l.activeProject, 0), l.projects.count - 1)
        for i in l.projects.indices {
            let n = l.projects[i].tabs.count
            l.projects[i].activeTab = n == 0 ? 0 : min(max(l.projects[i].activeTab, 0), n - 1)
            for t in l.projects[i].tabs.indices where !(l.projects[i].tabs[t].focused.map(l.projects[i].tabs[t].root.contains) ?? false) {
                l.projects[i].tabs[t].focused = l.projects[i].tabs[t].root.leaves.first?.id
            }
        }
        layout = l
    }

    func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(layout) else { return }
        let url = Store.directory.appendingPathComponent("layout.json")
        queue.sync { try? data.write(to: url, options: .atomic) }
    }
}

#if DEBUG
func modelSelfCheck() {
    func leaf() -> PaneSpec { PaneSpec(id: UUID(), kind: .markdown(path: "/x")) }
    let p1 = leaf(), p2 = leaf(), p3 = leaf()
    let tree = SplitNode.split(axis: .horizontal, ratio: 0.3, a: .leaf(p1),
                               b: .split(axis: .vertical, ratio: 0.7, a: .leaf(p2), b: .leaf(p3)))
    assert(tree.removing(p2.id)?.leaves.map(\.id) == [p1.id, p3.id])
    assert(tree.removing(p1.id) == .split(axis: .vertical, ratio: 0.7, a: .leaf(p2), b: .leaf(p3)))
    assert(SplitNode.leaf(p1).removing(p1.id) == nil)
    let p4 = leaf()
    let rep = tree.replacing(p2.id, with: .leaf(p4))
    assert(rep.leaves.map(\.id) == [p1.id, p4.id, p3.id])
    assert(!rep.contains(p2.id))
    func ratios(_ n: SplitNode) -> [Double] {
        if case .split(_, let r, let a, let b) = n { return [r] + ratios(a) + ratios(b) }
        return []
    }
    assert(ratios(tree.equalized()) == [0.5, 0.5])
    var l = Launch(command: "c", resume: "r {id} {id}", agent: nil, sessionID: nil, scrollbackLimit: nil)
    assert(l.commandLine == "c")
    l.sessionID = "S"
    assert(l.commandLine == "r S S")
    let layout = Layout(
        projects: [Project(id: UUID(), path: "/p", name: "p",
                           tabs: [Tab(id: UUID(), title: "t", root: tree, focused: p1.id)], activeTab: 0)],
        activeProject: 0, sidebarVisible: true, theme: "t", presets: Layout.default.presets)
    let data = try! JSONEncoder().encode(layout)
    assert(try! JSONDecoder().decode(Layout.self, from: data) == layout)
}
#endif
