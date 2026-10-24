import Foundation
import Synchronization

/// A git remote typed into New Project > Clone Repository: https://, ssh://, git:// or scp-like `user@host:org/repo`.
/// Local paths and file:// are not remotes here (Open Folder adds those).
struct GitRemote: Equatable, Sendable {
    let url: String    // as typed, trimmed
    let host: String   // lower case, no user or port
    let path: String   // org/repo, without .git and slashes at either end

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        var host: Substring, path: Substring
        if let scheme = ["https://", "http://", "ssh://", "git://", "git+ssh://", "ssh+git://"].first(where: { s.lowercased().hasPrefix($0) }) {
            let rest = s.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.lastIndex(of: ":") { host = host[..<colon] }   // a port
        } else if !s.contains("://"), let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            host = s[..<colon]   // scp-like: [user@]host:path
            path = s[s.index(after: colon)...]
            let user = host.lastIndex(of: "@")
            if let user { host = host[host.index(after: user)...] }
            guard user != nil || host.contains(".") else { return nil }   // `foo:bar` is a file name, not a host
        } else {
            return nil
        }
        var p = String(path)
        while p.hasSuffix("/") { p.removeLast() }
        if p.lowercased().hasSuffix(".git") { p.removeLast(4) }
        while p.hasPrefix("/") || p.hasPrefix("~") { p.removeFirst() }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-_[]".contains($0) }),
              !p.isEmpty, !p.split(separator: "/").contains("..") else { return nil }
        self.url = s
        self.host = host.lowercased()
        self.path = p
    }

    /// The folder `git clone` would make: the last path component.
    var folder: String { path.split(separator: "/").last.map(String.init) ?? "repo" }

    /// Same repository whatever the transport, user or `.git` suffix (hosts compare paths case-insensitively).
    func sameRepository(as other: GitRemote) -> Bool { host == other.host && path.lowercased() == other.path.lowercased() }

    /// Typed into the new project's shell. The clone's own progress output is what CloneWatch reads.
    func command(into folder: String) -> String {
        let f = Runtime.shellEscape(folder)
        return "git clone --progress -- \(Runtime.shellEscape(url)) \(f) && cd \(f)"
    }

    /// `dir`'s origin and branch, read from .git/config and .git/HEAD (no git process). nil = not a plain clone.
    static func checkout(at dir: String) -> (origin: String?, branch: String?)? {
        let git = URL(fileURLWithPath: dir).appendingPathComponent(".git")
        guard let config = readFile(git.appendingPathComponent("config"), cap: 1 << 20) else { return nil }
        var origin: String?, inOrigin = false
        for raw in String(decoding: config, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"; continue }
            if inOrigin, let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == "url" {
                origin = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let head = readFile(git.appendingPathComponent("HEAD"), cap: 4096).map { String(decoding: $0, as: UTF8.self) }
        let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        return (origin, branch)
    }
}

/// What the sidebar row shows while a project's first terminal clones it.
enum CloneStatus: Equatable, Sendable {
    case cloning(Int)        // percent
    case waiting(String)     // git or ssh is asking for something in the pane
    case failed(String)
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

enum CloneAction: Sendable { case retry, editURL, remove }   // a failed clone's sidebar buttons

/// Reads a clone pane's output (on the session's reader queue) for git's progress, credential prompts and the
/// fatal line, so the sidebar can show them. Events fire only on change.
final class CloneWatch: Sendable {
    enum Event: Equatable, Sendable { case progress(Int), prompt(String), error(String) }

    private struct State { var tail = ""; var percent = 0; var prompting = false; var error: String? }
    private let state = Mutex(State())

    /// Overall percent: objects received count for most of a clone, then deltas, then the checkout.
    private static let phases: [(String, Double, Double)] = [("Receiving objects:", 0, 80), ("Resolving deltas:", 80, 15), ("Updating files:", 95, 5)]

    func scan(_ bytes: UnsafeRawBufferPointer) -> [Event] {
        let text = String(decoding: bytes, as: UTF8.self)
        return state.withLock { s in
            s.tail += text
            var lines = s.tail.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            s.tail = String(lines.removeLast().suffix(1024))
            var events: [Event] = []
            for line in lines.map(Self.plain) {
                for (label, base, span) in Self.phases {
                    guard let r = line.range(of: label) else { continue }
                    let digits = line[r.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
                    if let n = Double(digits), line[r.upperBound...].drop(while: { $0 == " " }).dropFirst(digits.count).first == "%" {
                        let p = min(100, Int(base + span * n / 100))
                        if p > s.percent || s.prompting { s.percent = max(p, s.percent); s.prompting = false; events.append(.progress(s.percent)) }
                    }
                }
                if s.error == nil, let e = Self.failure(line) { s.error = e; events.append(.error(e)) }
            }
            // A prompt has no line end yet: it waits for input on the incomplete last line.
            if !s.prompting, let p = Self.prompt(Self.plain(s.tail)) { s.prompting = true; events.append(.prompt(p)) }
            return events
        }
    }

    /// Typing answers a prompt; the next prompt (a wrong passphrase) shows again.
    func answered() { state.withLock { $0.prompting = false; $0.tail = "" } }

    /// For a retry: a new clone in the same pane.
    func reset() { state.withLock { $0 = State() } }

    /// A line with terminal escape sequences (prompt colors, titles) taken out.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[@-_]", with: "", options: .regularExpression)
    }

    static func prompt(_ s: String) -> String? {
        let l = s.lowercased()
        if l.contains("passphrase for") { return "Waiting for SSH passphrase" }
        if l.hasPrefix("username for '") { return "Waiting for username" }
        if l.hasPrefix("password for '") || l.hasSuffix("'s password: ") { return "Waiting for password" }
        if l.contains("(yes/no") { return "Confirm the host key" }
        return nil
    }

    static func failure(_ s: String) -> String? {
        guard s.hasPrefix("fatal: ") || s.hasPrefix("ERROR: ") else { return nil }
        let l = s.lowercased()
        if l.contains("not found") || l.contains("does not exist") { return "repository not found" }
        if l.contains("authentication failed") || l.contains("permission denied") { return "access denied" }
        if l.contains("could not resolve host") { return "host not found" }
        if l.contains("already exists and is not an empty directory") { return "folder already exists" }
        if l.contains("could not read from remote") { return "could not read from remote" }
        return String(s.dropFirst(7))
    }
}

#if DEBUG
func gitCloneSelfCheck() {
    let https = GitRemote("https://github.com/ghostty-org/ghostty.git")
    assert(https?.host == "github.com" && https?.path == "ghostty-org/ghostty" && https?.folder == "ghostty")
    let scp = GitRemote("git@GitHub.com:acme/storefront.git")
    assert(scp?.host == "github.com" && scp?.folder == "storefront" && scp.map { https!.sameRepository(as: $0) } == false)
    assert(GitRemote("ssh://git@github.com:22/Acme/Storefront/")!.sameRepository(as: scp!))
    assert(GitRemote("https://user@git.sys.kwi.com:8443/reporting/acuity")?.host == "git.sys.kwi.com")
    for bad in ["", "foo", "foo:bar", "/Users/me/repo", "file:///tmp/x", "https://github.com", "https://github.com/", "git@host:a b", "git@host:../x"] {
        assert(GitRemote(bad) == nil, bad)
    }
    assert(GitRemote("git@github.com:o/r.git")!.command(into: "r 2") == "git clone --progress -- git@github.com:o/r.git 'r 2' && cd 'r 2'")

    let w = CloneWatch()
    func feed(_ s: String) -> [CloneWatch.Event] { Array(s.utf8).withUnsafeBytes { w.scan($0) } }
    assert(feed("\u{1B}]0;zsh\u{07}~ ❯ git clone x\r\nCloning into 'x'...\r\n") == [])
    assert(feed("Receiving objects:  50% (5/10)\rReceiving obj") == [.progress(40)])
    assert(feed("ects:  50% (5/10)\r") == [])   // same percent: no event
    assert(feed("Resolving deltas: 100% (3/3), done.\r\n") == [.progress(95)])
    assert(feed("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == [.prompt("Waiting for SSH passphrase")])
    assert(feed("") == [])   // still the same prompt
    w.answered()
    assert(feed("\r\nfatal: repository 'https://github.com/x/y.git/' not found\r\n") == [.error("repository not found")])
    assert(CloneWatch.prompt("git@github.com's password: ") == "Waiting for password")
}
#endif
