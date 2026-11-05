import AppKit
import AVFoundation

enum SpeechFrame {
    /// Complete frames off the front of `buffer` (LE u32 id, LE u32 sample rate Hz, LE u32 byte count, LE float32 mono PCM); a partial frame stays for the next read.
    static func parse(_ buffer: inout Data) -> [(id: UInt32, rate: Double, samples: [Float])] {
        var out: [(id: UInt32, rate: Double, samples: [Float])] = []
        var pos = 0
        buffer.withUnsafeBytes { raw in
            while raw.count - pos >= 12 {
                let id = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                let rate = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self))
                let n = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: pos + 8, as: UInt32.self)))
                guard raw.count - pos - 12 >= n else { break }
                // Apple Silicon and x86 hosts are little-endian: the payload is copied as is
                let samples = [Float](unsafeUninitializedCapacity: n / 4) { dst, count in
                    UnsafeMutableRawBufferPointer(dst).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(pos + 12)..<(pos + 12 + n / 4 * 4)]))
                    count = n / 4
                }
                out.append((id: id, rate: Double(rate), samples: samples))
                pos += 12 + n
            }
        }
        if pos > 0 { buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + pos) }
        return out
    }
}

@MainActor final class Speaker {
    enum State: Equatable, Sendable { case idle, loading, speaking }
    /// The app-wide speaker.
    static let shared = Speaker()
    /// helper.log (the helper's stderr: the voice it picked, errors).
    static var directory: URL { Store.directory.appendingPathComponent("speech") }
    /// idle, waiting for the first audio, or playing.
    private(set) var state: State = .idle
    /// Called on every state change.
    var onChange: ((State) -> Void)?
    /// Called when speech cannot start or the helper dies mid-job.
    var onFailure: () -> Void = { NSSound.beep() }
    /// Playback speed (1 = as generated); time-stretched, so the voice keeps its pitch. Applies mid-reply too.
    var rate: Float = 1 { didSet { stretch?.rate = rate } }
    /// Tone: pitch multiplier, applied in playback (Siri voices ignore AVSpeechUtterance.pitchMultiplier and SSML pitch). Live.
    var pitch: Float = 1 { didSet { stretch?.pitch = Self.cents(pitch) } }
    nonisolated static func cents(_ multiplier: Float) -> Float { 1200 * log2(multiplier) }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var current: UInt32 = 0
    private var pending: [String] = []
    private var inFlight = 0
    private var queued: Double = 0
    private var scheduled = 0
    private var rateHz: Double = 48000
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var stretch: AVAudioUnitTimePitch?

    init() {}

    #if DEBUG
    var helperPID: pid_t? { process?.processIdentifier }
    var playbackCents: Float? { stretch?.pitch }
    #endif

    private func set(_ s: State) {
        if s != state { state = s; onChange?(s) }
    }

    /// Cancels any job and speaks the chunks in order, streaming audio as the helper produces it.
    func speak(_ chunks: [String]) {
        let chunks = chunks.filter { !$0.isEmpty }
        if chunks.isEmpty { onFailure(); return }
        if state != .idle { send(["cancel": current]) }
        current &+= 1
        player?.stop()
        pending = chunks; inFlight = 0; queued = 0; scheduled = 0
        guard ensureHelper() else { finish(); onFailure(); return }
        set(.loading)
        feed()
        guard ensureAudio() else { finish(); onFailure(); return }
    }

    /// Starts the helper now (e.g. while a transcript is being looked up), so its startup overlaps the lookup.
    func prewarm() { _ = ensureHelper() }

    /// Keeps at most two chunks in synthesis and 30 s of audio queued.
    private func feed() {
        while !pending.isEmpty && inFlight < 2 && queued < 30 {
            var job: [String: Any] = ["id": current, "text": pending.removeFirst()]
            send(job)
            inFlight += 1
        }
    }

    /// Stops the current job; later frames of it are dropped.
    func stop() {
        guard state != .idle else { return }
        send(["cancel": current])
        finish()
    }

    private func finish() {
        current &+= 1
        pending = []; inFlight = 0; queued = 0
        player?.stop()
        engine?.stop()
        set(.idle)
    }

    private func send(_ msg: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(10)
        try? input?.write(contentsOf: d)
    }

    private func ensureHelper() -> Bool {
        if process?.isRunning == true { return true }
        let p = Process()
        if let override = ProcessInfo.processInfo.environment["PANE_SPEECH_HELPER"] {
            p.executableURL = URL(fileURLWithPath: override)
            p.arguments = []
        } else {
            guard let res = Bundle.main.resourceURL else { return false }
            // osascript is Apple-signed, so it sees the Siri voices (siri_helper.js)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-l", "JavaScript", res.appendingPathComponent("speech/siri_helper.js").path]
        }
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        let log = Speaker.directory.appendingPathComponent("helper.log")
        try? FileManager.default.createDirectory(at: Speaker.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            p.standardError = h
        } else {
            p.standardError = FileHandle.nullDevice
        }
        // a write after the helper died fails with EPIPE instead of killing Workbench
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperExited(p) } }
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(d) } }
        }
        do { try p.run() } catch { return false }
        process = p
        input = stdinPipe.fileHandleForWriting
        buffer = Data()
        return true
    }

    private func helperExited(_ p: Process) {
        guard p === process else { return }
        process = nil; input = nil; buffer = Data()
        if state != .idle && inFlight > 0 {
            finish(); onFailure()
        } else if state != .idle && !pending.isEmpty {
            if ensureHelper() { feed() } else { finish(); onFailure() }
        }
    }

    private func ensureAudio() -> Bool {
        if engine == nil || player == nil {
            let e = AVAudioEngine(), pl = AVAudioPlayerNode(), st = AVAudioUnitTimePitch()
            st.rate = rate
            st.pitch = Self.cents(pitch)
            e.attach(pl); e.attach(st)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rateHz, channels: 1)!
            e.connect(pl, to: st, format: fmt)
            e.connect(st, to: e.mainMixerNode, format: fmt)
            engine = e; player = pl; stretch = st
        }
        guard let engine, let player else { return false }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        player.play()
        return true
    }

    private func received(_ d: Data) {
        buffer.append(d)
        for f in SpeechFrame.parse(&buffer) where f.id == current && state != .idle {
            if f.samples.isEmpty {
                inFlight -= 1
                feed()
            } else {
                if f.rate != rateHz, let engine, let player, let stretch {
                    rateHz = f.rate
                    let fmt = AVAudioFormat(standardFormatWithSampleRate: f.rate, channels: 1)!
                    engine.stop()
                    engine.connect(player, to: stretch, format: fmt)
                    engine.connect(stretch, to: engine.mainMixerNode, format: fmt)
                    try? engine.start()
                    player.play()
                }
                schedule(f.samples, f.rate)
            }
        }
        checkDone()
    }

    private func schedule(_ samples: [Float], _ rate: Double) {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        scheduled += 1
        let seconds = Double(samples.count) / rate
        queued += seconds
        let id = current
        player?.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(id, seconds) } }
        }
        if state == .loading { set(.speaking) }
    }

    private func played(_ id: UInt32, _ seconds: Double) {
        guard id == current else { return }
        scheduled -= 1
        queued -= seconds
        feed()
        checkDone()
    }

    private func checkDone() {
        if state != .idle && pending.isEmpty && inFlight == 0 && scheduled == 0 { finish() }
    }
}

#if DEBUG
@MainActor func speakerSelfCheck() {
    func frame(_ id: UInt32, _ s: [Float], rate: UInt32 = 48000) -> Data {
        var d = Data()
        withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: rate.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(s.count * 4).littleEndian) { d.append(contentsOf: $0) }
        for f in s { withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
    let nine = frame(9, [0.25], rate: 22050)
    var buf = frame(7, [1, -0.5]) + frame(7, []) + nine.prefix(6)
    var got = SpeechFrame.parse(&buf)
    assert(got.count == 2 && got[0].id == 7 && got[0].samples == [1, -0.5] && got[0].rate == 48000 && got[1].id == 7 && got[1].samples.isEmpty, "complete frames parsed")
    assert(buf.count == 6, "partial frame stays")
    buf.append(nine.dropFirst(6))
    got = SpeechFrame.parse(&buf)
    assert(got.count == 1 && got[0].id == 9 && got[0].rate == 22050 && got[0].samples == [0.25] && buf.isEmpty, "partial frame completed")
    var shifted = (Data([0]) + frame(3, [2], rate: 22050) + frame(4, [1]))[1...]
    got = SpeechFrame.parse(&shifted)
    assert(got.count == 2 && got[0].id == 3 && got[0].rate == 22050 && got[0].samples == [2] && got[1].id == 4 && shifted.isEmpty, "non-zero startIndex")

    let stubPath = FileManager.default.temporaryDirectory.appendingPathComponent("speech-stub-\(UUID().uuidString).py").path
    let script = """
    #!/usr/bin/python3
    import json, struct, sys, time
    out = sys.stdout.buffer
    def frame(i, n, rate=48000):
        out.write(struct.pack("<III", i, rate, n * 4) + bytes(n * 4)); out.flush()
    log = open(sys.argv[0] + ".log", "a")
    for line in sys.stdin:
        log.write(line); log.flush()
        msg = json.loads(line)
        if "cancel" in msg: continue
        i, text = msg["id"], msg["text"]
        if text == "hang": continue
        if text == "late": time.sleep(0.3)
        if text == "slow": frame(i, 22050, 22050)
        else: frame(i, 48000 if text == "long" else 4800)
        out.write(struct.pack("<III", i, 0, 0)); out.flush()
        if text == "bye": sys.exit(0)

    """
    try? script.write(toFile: stubPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
    defer { try? FileManager.default.removeItem(atPath: stubPath); try? FileManager.default.removeItem(atPath: stubPath + ".log") }
    setenv("PANE_SPEECH_HELPER", stubPath, 1)
    defer { unsetenv("PANE_SPEECH_HELPER") }

    func spin(_ timeout: TimeInterval, until done: () -> Bool = { false }) -> Bool {
        let end = Date() + timeout
        while !done() && Date() < end { RunLoop.main.run(until: Date() + 0.02) }
        return done()
    }
    let s = Speaker()
    var seen: [Speaker.State] = []
    var failures = 0
    s.onChange = { seen.append($0) }
    s.onFailure = { failures += 1 }

    s.speak(["a", "b"])
    assert(s.state == .loading)
    assert(spin(10) { s.state == .idle })
    assert(seen == [.loading, .speaking, .idle], "\(seen)")
    assert(failures == 0)

    seen = []
    s.speak(["late"])
    s.stop()
    assert(s.state == .idle)
    _ = spin(0.8)
    assert(seen == [.loading, .idle], "late frames of a stopped job are dropped: \(seen)")

    seen = []
    s.speak(["late"])
    s.speak(["hang"])   // replaces it while its audio is still on the way
    _ = spin(0.8)
    assert(seen == [.loading] && s.state == .loading, "a replaced job's frames never play as the new one's: \(seen)")
    s.stop()

    seen = []
    s.speak(["bye"])
    assert(spin(10) { s.state == .idle })
    assert(seen == [.loading, .speaking, .idle] && failures == 0, "a helper exiting after its last chunk lets the audio finish: \(seen)")

    s.speak(["hang", "hang", "x"])
    _ = spin(0.5)
    let lines = ((try? String(contentsOfFile: stubPath + ".log", encoding: .utf8)) ?? "").split(separator: "\n").suffix(3)
    assert(lines.filter { $0.contains("\"hang\"") }.count == 2 && !lines.contains { $0.contains("\"x\"") }, "two chunks ahead at most: \(lines)")
    s.stop()

    s.speak(["hang"])
    let pid = s.helperPID!
    kill(pid, SIGKILL)
    assert(spin(5) { s.state == .idle }, "a dead helper ends the job")
    assert(failures == 1)

    seen = []
    s.speak(["a"])
    assert(spin(10) { s.state == .idle })
    assert(seen == [.loading, .speaking, .idle], "\(seen)")
    assert(s.helperPID != nil && s.helperPID != pid, "respawned")

    s.pitch = 1.2
    s.speak(["a"])
    assert(spin(10) { s.state == .idle })
    assert(abs((s.playbackCents ?? 0) - 315.6) < 0.5, "tone 1.2 plays 316 cents up: \(String(describing: s.playbackCents))")
    s.pitch = 0.9
    assert(abs((s.playbackCents ?? 0) + 182.4) < 0.5, "tone changes live: \(String(describing: s.playbackCents))")
    s.pitch = 1

    s.speak([])
    assert(failures == 2 && s.state == .idle, "nothing to say")

    func playTime(_ rate: Float) -> TimeInterval {   // 1 s of audio, from first sound to done
        s.rate = rate
        s.speak(["long"])
        _ = spin(10) { s.state == .speaking }
        let t0 = Date()
        _ = spin(10) { s.state == .idle }
        return Date().timeIntervalSince(t0)
    }
    let normal = playTime(1), fast = playTime(2)
    assert(normal > 0.8 && fast < normal * 0.75, "2× plays faster: \(normal) s vs \(fast) s")
    s.rate = 1
    s.speak(["slow"])
    _ = spin(10) { s.state == .speaking }
    let t1 = Date()
    _ = spin(10) { s.state == .idle }
    let slow = Date().timeIntervalSince(t1)
    assert(slow > 0.8 && slow < 1.5, "22.05 kHz audio plays at its own rate: \(slow) s")
}
#endif
