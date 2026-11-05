#!/usr/bin/python3
import json, os, struct, subprocess, sys, time, threading

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CMD = ["/usr/bin/osascript", "-l", "JavaScript", "Resources/speech/siri_helper.js"]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
frames = []  # (id, rate, samples)
cond = threading.Condition()


def reader():
    f = p.stdout
    while True:
        h = f.read(12)
        if len(h) < 12:
            return
        i, rate, n = struct.unpack("<III", h)
        body = f.read(n)
        with cond:
            frames.append((i, rate, n // 4 if len(body) == n else -1))
            cond.notify_all()


threading.Thread(target=reader, daemon=True).start()


def wait_end(job):
    deadline = time.time() + 15
    with cond:
        while not any(f[0] == job and f[1] == 0 and f[2] == 0 for f in frames):
            left = deadline - time.time()
            if left <= 0:
                fail("no end frame for job %d within 15 s" % job)
            cond.wait(left)
    return [f for f in frames if f[0] == job and f[1] != 0]


data = json.dumps({"id": 1, "text": "Hello \U0001F44B there."}, ensure_ascii=False).encode("utf-8") + b"\n"
cut = data.index("\U0001F44B".encode("utf-8")) + 2
p.stdin.write(data[:cut]); p.stdin.flush()
time.sleep(0.3)
p.stdin.write(data[cut:]); p.stdin.flush()
a = wait_end(1)
if not a:
    fail("job 1 produced no audio frames")
rate = a[0][1]
if any(f[1] != rate for f in a) or any(f[2] < 0 for f in a):
    fail("job 1 rates differ or a frame was short: %r" % a)
if len(a) > 1 and not a[0][2] < rate // 10:
    print("note: first frame not small (%d samples)" % a[0][2])
for f in a[1:-1]:
    if f[2] < rate // 10:
        fail("middle frame under 100 ms: %r" % (f,))

if rate != 48000:
    fail("Siri Voice 6 audio should be 48000 Hz, got %d" % rate)

p.stdin.close()
try:
    p.wait(5)
except subprocess.TimeoutExpired:
    p.kill()
    fail("helper did not exit within 5 s of stdin close")
err = p.stderr.read().decode()
if "voice: com.apple.siri.natural.en-US-G" not in err:
    fail("helper did not pick Siri Voice 6: " + err)
print("speech helper ok")
