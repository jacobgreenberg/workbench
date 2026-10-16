import Foundation

final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: @MainActor ([String: String]) -> String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    init(path: String, handler: @escaping @MainActor ([String: String]) -> String) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { NSLog("pane: control socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            NSLog("pane: control socket path too long")
            close(s)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) }
        }
        guard rc == 0 else {
            NSLog("pane: control bind() failed: %d", errno)
            close(s)
            return
        }
        chmod(path, 0o600)
        guard listen(s, 16) == 0 else {
            NSLog("pane: control listen() failed: %d", errno)
            close(s)
            return
        }
        lock.lock()
        fd = s
        stopped = false
        lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(s) }
        t.name = "pane.control"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR); close(s) }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ s: Int32) {
        while !isStopped {
            let c = accept(s, nil, nil)
            if c < 0 {
                if isStopped || errno != EINTR { if isStopped || errno == EBADF || errno == EINVAL { return } }
                continue
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .utility).async { [self] in handle(c) }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > 1 << 20 { return }
            if data.contains(10) { break }
        }
        if let i = data.firstIndex(of: 10) { data = data.prefix(upTo: i) }
        let reply: String
        if let msg = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let h = handler
            reply = DispatchQueue.main.sync { MainActor.assumeIsolated { h(msg) } }
        } else {
            reply = "{\"error\":\"bad request\"}"
        }
        let out = Array((reply + "\n").utf8)
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            off += n
        }
    }
}

enum ControlClient {
    static func run(_ args: [String]) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let path = env["PANE_SOCK"] ?? (NSHomeDirectory() + "/Library/Application Support/Pane/pane.sock")
        let paneID = env["PANE_ID"]
        guard let cmd = args.first else { return usage() }

        if cmd == "hook" {
            guard let paneID, args.count > 1 else { return 0 }
            var raw: Data?
            if args.count > 2 {
                raw = args.last?.data(using: .utf8)
            } else if isatty(0) == 0 {
                raw = FileHandle.standardInput.readDataToEndOfFile()
            }
            var msg = ["cmd": "hook", "pane": paneID, "event": args[1]]
            if let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let session = (obj["session_id"] ?? obj["thread-id"]) as? String {
                msg["session"] = session
            }
            _ = send(msg, path: path)
            return 0
        }

        var msg: [String: String]
        let rest = Array(args.dropFirst())
        switch cmd {
        case "list":
            msg = ["cmd": "list"]
        case "focus":
            guard let id = rest.first else { return usage() }
            msg = ["cmd": "focus", "pane": id]
        case "split":
            let down = rest.contains("--down")
            let words = rest.filter { $0 != "--down" }
            msg = ["cmd": "split", "pane": paneID ?? "", "axis": down ? "vertical" : "horizontal"]
            if !words.isEmpty { msg["command"] = words.joined(separator: " ") }
        case "send":
            guard rest.count >= 2 else { return usage() }
            msg = ["cmd": "send", "pane": rest[0], "text": rest.dropFirst().joined(separator: " ")]
        case "open":
            guard let p = rest.first else { return usage() }
            let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
            msg = ["cmd": "open", "pane": paneID ?? "", "path": (abs as NSString).standardizingPath]
        case "add":
            let p = rest.first ?? "."
            let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
            msg = ["cmd": "add", "path": (abs as NSString).standardizingPath]
        default:
            return usage()
        }

        guard let reply = send(msg, path: path) else {
            FileHandle.standardError.write(Data("pane: Pane is not running\n".utf8))
            return 1
        }
        if let d = reply.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           obj["error"] != nil {
            FileHandle.standardError.write(Data((reply + "\n").utf8))
            return 1
        }
        print(reply)
        return 0
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        usage: pane <command>
          hook <event>
          list
          focus <pane-id>
          split [--down] [command...]
          send <pane-id> <text...>
          open <path>
          add [dir]

        """.utf8))
        return 2
    }

    static func encode(_ msg: [String: String]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys]) else { return nil }
        d.append(10)
        return d
    }

    private static func send(_ msg: [String: String], path: String) -> String? {
        guard let out = encode(msg) else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        guard rc == 0 else { return nil }
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            off += n
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(s, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(10) { break }
        }
        if let i = data.firstIndex(of: 10) { data = data.prefix(upTo: i) }
        return String(decoding: data, as: UTF8.self)
    }
}

#if DEBUG
func controlSelfCheck() {
    let msg = ["cmd": "hook", "pane": "X", "event": "stop"]
    let d = ControlClient.encode(msg)!
    assert(d.last == 10)
    let back = try! JSONSerialization.jsonObject(with: d.dropLast()) as! [String: String]
    assert(back == msg)
}
#endif
