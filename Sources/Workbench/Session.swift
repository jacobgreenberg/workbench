import Foundation
import Synchronization
@preconcurrency import GhosttyKit

/// The app's end of one pane's session. The shell is owned by a `wbhost` process (protocol in Sources/wbhost/main.c),
/// so it outlives the app: after a crash or Restart the app reattaches and the host replays its recent output.
/// fd ownership: only the reader (`start`'s source) reads it; it is closed solely on `writeQ` by kill()/detach(),
/// which first stop the reader, so nothing uses it after close and it closes once.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

final class Session: @unchecked Sendable {
    @MainActor static var keepOnClose = false   // Restart: closing a surface detaches instead of ending the session

    static var directory: URL { Store.directory.appendingPathComponent("s") }
    static func path(_ id: PaneID) -> String { directory.path + "/" + id.uuidString }

    private static let reapers = Mutex<[pid_t: DispatchSourceProcess]>([:])

    private let fd: Int32
    private let queue = DispatchQueue(label: "workbench.session.read", qos: .userInitiated)
    private let writeQ = DispatchQueue(label: "workbench.session.write")
    private var source: DispatchSourceRead?
    private let replaying = Atomic<Bool>(false)
    private let endedOnce = Atomic<Bool>(false)
    private var closed = false          // writeQ only
    private var lastSize: [UInt16] = [] // writeQ only
    private var header: [UInt8] = []    // reader only; prefilled by attach
    /// The pty's grid when attached (from the host's header): the replay was drawn for it. nil for a new session.
    private(set) var grid: (cols: UInt16, rows: UInt16)?

    private init(fd: Int32) { self.fd = fd }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Connected socket fd, or nil with errno set.
    private static func connect(_ path: String) -> Int32? {
        guard var addr = address(path) else { errno = ENAMETOOLONG; return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(s); errno = e; return nil }
        return s
    }

    static func attach(_ id: PaneID) -> Session? {
        let p = path(id)
        guard let s = connect(p) else {
            if errno == ECONNREFUSED || errno == ENOENT { unlink(p) }
            return nil
        }
        // The host answers at once with its header; read it here so the caller can size the view before the replay.
        var t = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        var h = [UInt8](repeating: 0, count: 12), got = 0
        while got < 12 {
            let n = h[got...].withUnsafeMutableBytes { read(s, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { close(s); return nil }   // ended, or wedged: start a new session instead
            got += n
        }
        t = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        let session = Session(fd: s)
        session.header = h
        let cols = UInt16(h[8]) | UInt16(h[9]) << 8, rows = UInt16(h[10]) | UInt16(h[11]) << 8
        if cols > 0, rows > 0 { session.grid = (cols, rows) }
        return session
    }

    static func spawn(_ id: PaneID, cwd: String, argv: [String], env: [String: String], cols: UInt16, rows: UInt16) -> Session? {
        let p = path(id)
        guard address(p) != nil else { NSLog("Workbench: session path too long: \(p)"); return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WorkbenchHost").path
        if !FileManager.default.fileExists(atPath: helper), let exe = Bundle.main.executableURL {
            helper = exe.deletingLastPathComponent().appendingPathComponent("wbhost").path
        }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        for f in pair { _ = fcntl(f, F_SETFD, FD_CLOEXEC); var one: Int32 = 1; setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // The host answers for its own privacy grants (Documents, Full Disk Access...). Inherited, they'd be the
        // app's only while it lives: after a crash or Restart each process becomes responsible for itself, and every
        // shell, ls and agent would be judged (and prompt) on its own.
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        for n in 0...2 { posix_spawn_file_actions_addopen(&fa, Int32(n), "/dev/null", n == 0 ? O_RDONLY : O_WRONLY, 0) }
        posix_spawn_file_actions_adddup2(&fa, pair[1], 3)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&fa) }

        let args = [helper, p, String(cols), String(rows), cwd] + argv
        let envp = env.map { "\($0.key)=\($0.value)" }
        let a = args.map { strdup($0) } + [nil], e = envp.map { strdup($0) } + [nil]
        defer { a.forEach { free($0) }; e.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, helper, &fa, &attr, a, e)
        close(pair[1])
        guard rc == 0 else { close(pair[0]); NSLog("Workbench: posix_spawn \(helper) failed: \(rc)"); return nil }

        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        src.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            src.cancel()
            _ = reapers.withLock { $0.removeValue(forKey: pid) }
        }
        reapers.withLock { $0[pid] = src }
        src.resume()
        return Session(fd: pair[0])
    }

    func start(output: @escaping @Sendable (UnsafeRawBufferPointer) -> Void, ended: @escaping @Sendable () -> Void) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buf = [UInt8](repeating: 0, count: 65536)
        var replayLeft: UInt64 = header.count == 12 ? header[..<8].reversed().reduce(0) { $0 << 8 | UInt64($1) } : 0
        src.setEventHandler { [self] in
            let want = Int(min(max(src.data, 1), 65536))
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
            if n <= 0 {
                src.cancel()
                if !endedOnce.exchange(true, ordering: .acquiringAndReleasing) { ended() }
                return
            }
            var off = 0
            if header.count < 12 {   // a new session's header: replay length 0
                let take = min(12 - header.count, n)
                header += buf[0..<take]
                off = take
            }
            buf.withUnsafeBytes { all in
                if replayLeft > 0, off < n {
                    let take = Int(min(replayLeft, UInt64(n - off)))
                    replaying.store(true, ordering: .releasing)
                    output(UnsafeRawBufferPointer(rebasing: all[off..<off + take]))
                    replaying.store(false, ordering: .releasing)
                    replayLeft -= UInt64(take)
                    off += take
                }
                if off < n { output(UnsafeRawBufferPointer(rebasing: all[off..<n])) }
            }
        }
        source = src
        src.resume()
    }

    private func send(_ type: UInt8, _ payload: [UInt8]) {
        var buf: [UInt8] = [type]
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { buf += $0 }
        buf += payload
        let frame = buf
        writeQ.async { [self] in
            guard !closed else { return }
            var off = 0
            while off < frame.count {
                let n = frame[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }   // the reader will see EOF
                off += n
            }
        }
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, !replaying.load(ordering: .acquiring) else { return }   // replies to queries in replayed history
        send(UInt8(ascii: "i"), [UInt8](bytes))
    }

    func resize(cols: UInt16, rows: UInt16, width: UInt16, height: UInt16) {
        let size = [cols, rows, width, height]
        var bytes: [UInt8] = []
        for v in size { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        let payload = bytes
        writeQ.async { [self] in
            guard size != lastSize else { return }
            lastSize = size
            send(UInt8(ascii: "w"), payload)
        }
    }

    /// Stops the reader; when this returns no output callback is running or will run. Safe to repeat.
    func stopReading() {
        source?.cancel()
        queue.sync {}
    }

    private func closeFD() {
        writeQ.async { [self] in
            guard !closed else { return }
            closed = true
            close(fd)
        }
    }

    /// Ends the session (host kills the shell and exits), then closes.
    func kill() {
        stopReading()
        Session.ending.enter()
        writeQ.async { [self] in
            defer { Session.ending.leave() }
            guard !closed else { return }
            closed = true
            Session.end(fd)
        }
    }

    private static let ending = DispatchGroup()

    /// Quit: returns once every kill() has seen its host exit (or after `timeout`), so the app doesn't exit with a
    /// 'k' still queued and leave that shell running.
    static func waitForEnds(timeout: TimeInterval) { _ = ending.wait(timeout: .now() + timeout) }

    /// Sends 'k', then reads until the host exits (EOF) and closes. A host busy writing output (or answering a connect
    /// with its replay) reads the frame only once those writes go through, and drops a client it can no longer write
    /// to, so closing right after sending could lose the 'k' and leave the shell running.
    private static func end(_ fd: Int32) {
        let frame: [UInt8] = [UInt8(ascii: "k"), 0, 0, 0, 0]
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, 5) }
        var t = timeval(tv_sec: 5, tv_usec: 0)   // a wedged host: give up
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        var sink = [UInt8](repeating: 0, count: 65536)
        while sink.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) > 0 {}
        close(fd)
    }

    /// Leaves the session running for the next attach.
    func detach() {
        stopReading()
        closeFD()
    }

    /// At EOF: a host removes its socket on every way it ends a session, so one left behind means it was killed (a
    /// broad pkill; force-quitting an app launched from the pane takes the pane's coalition with it). attach() clears it.
    static func wasKilled(_ id: PaneID) -> Bool { FileManager.default.fileExists(atPath: path(id)) }

    /// Ends every host in the directory whose pane is not in `ids`. Off main.
    static func endOrphans(keeping ids: Set<PaneID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            let p = path(id)
            guard let s = connect(p) else { unlink(p); continue }
            end(s)
        }
    }

    /// argv and environment for a pane shell, what Ghostty's exec backend used to build.
    static func shell(cwd: String, paneEnv: [String: String], base: [String: String] = ProcessInfo.processInfo.environment) -> (argv: [String], env: [String: String]) {
        var env = base
        env["GHOSTTY_LOG"] = nil
        env["VTE_VERSION"] = nil
        let res = env["GHOSTTY_RESOURCES_DIR"]
        if let res {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = (res as NSString).deletingLastPathComponent + "/terminfo"
            env["XDG_DATA_DIRS"] = (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share") + ":" + res + "/.."
            env["MANPATH"] = (env["MANPATH"] ?? "") + ":" + res + "/../man"
        } else {
            env["TERM"] = "xterm-256color"
        }
        let info = ghostty_info()
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)), as: UTF8.self)
        // ponytail: Ghostty's default shell features with cursor blink off (Runtime forces cursor-style-blink=false); read the config if they're ever customized.
        env["GHOSTTY_SHELL_FEATURES"] = "cursor:steady,path,title"
        let shell = env["SHELL"] ?? "/bin/zsh"
        if let res, (shell as NSString).lastPathComponent == "zsh" {
            if let z = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = z }
            env["ZDOTDIR"] = res + "/shell-integration/zsh"
        }
        env["PWD"] = cwd
        env.merge(paneEnv) { _, new in new }
        let hush = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.hushlogin")
        return (["/usr/bin/login", hush ? "-qflp" : "-flp", NSUserName(), "/bin/bash", "--noprofile", "--norc", "-c", "exec -l " + Runtime.shellEscape(shell)], env)
    }
}
