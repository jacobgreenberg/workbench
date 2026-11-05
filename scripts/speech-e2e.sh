#!/usr/bin/env bash
# Read Aloud end to end: the debug bundle with a stub voice helper, driven over its control socket.
# Usage: scripts/speech-e2e.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--no-build" ] || scripts/bundle.sh --debug >/dev/null
scripts/speech-helper-check.py   # the real helper (osascript + the Siri voice), outside the app

DIR=$(mktemp -d /tmp/wbspeech.XXXX)   # short: the control socket path must fit sun_path
APP_PID=
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null && wait "$APP_PID" 2>/dev/null
  pkill -f -- "$DIR" 2>/dev/null || true   # the panes' hosts and the stub outlive a killed app
  rm -rf "$DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub voice: 2 s of silence (48 kHz) per chunk, then the chunk's end frame (protocol: Speaker.swift).
cat > "$DIR/stub.py" <<'EOF'
#!/usr/bin/python3
import json, struct, sys
out = sys.stdout.buffer
log = open(sys.argv[0] + ".jobs", "a")
for line in sys.stdin:
    log.write(line); log.flush()
    msg = json.loads(line)
    if "cancel" in msg:
        continue
    n = 96000
    out.write(struct.pack("<III", msg["id"], 48000, n * 4) + bytes(n * 4))
    out.write(struct.pack("<III", msg["id"], 0, 0))
    out.flush()
EOF
chmod +x "$DIR/stub.py"

# A Claude transcript whose turn ends on an unanswered question, in the shape Claude Code writes it.
cat > "$DIR/t.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"brainstorm"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is what I found."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which voice engine?","header":"Voice","multiSelect":false,"options":[{"label":"OpenAI TTS","description":"cloud"},{"label":"Local neural","description":"free"}]}]}}]}}
EOF

PANE_STATE_DIR="$DIR" PANE_SPEECH_HELPER="$DIR/stub.py" build.noindex/Workbench-debug.app/Contents/MacOS/Workbench >/dev/null 2>&1 &
APP_PID=$!
SOCK="$DIR/pane.sock"
for _ in $(seq 150); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || fail "no control socket"

ctl() {
  /usr/bin/python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
print(s.makefile().readline().strip())' "$SOCK" "$1"
}
state() { ctl '{"cmd":"speak-state"}' | sed -E 's/.*"state":"([a-z]+)".*/\1/'; }
speed() { ctl '{"cmd":"speak-state"}' | sed -E 's/.*"speed":"([0-9.]+)".*/\1/'; }
speak() { ctl "{\"cmd\":\"speak\",\"path\":\"$DIR/t.jsonl\"}"; }

# 1. The pending question is what gets said, after the text before it.
reply=$(speak)
expected='{"text":"Here is what I found. Claude is asking: Which voice engine? Option one, OpenAI TTS. Option two, Local neural."}'
[ "$reply" = "$expected" ] || fail "speak said: $reply"

# 2. It plays (loading → speaking) and returns to idle on its own.
saw=no
for _ in $(seq 200); do
  s=$(state)
  [ "$s" = speaking ] && saw=yes
  [ "$s" = idle ] && [ "$saw" = yes ] && break
  sleep 0.05
done
[ "$saw" = yes ] || fail "never reached speaking"
[ "$(state)" = idle ] || fail "did not return to idle"

# 3. Stop mid-reply: idle at once, and the rest of the audio never comes back.
speak >/dev/null
for _ in $(seq 100); do [ "$(state)" = speaking ] && break; sleep 0.05; done
[ "$(state)" = speaking ] || fail "second read never started"
ctl '{"cmd":"speak-stop"}' >/dev/null
[ "$(state)" = idle ] || fail "stop did not stop"
sleep 1
[ "$(state)" = idle ] || fail "audio came back after stop"

# 4. Every pane's header has the controls; the speed button cycles 1× → 1.25× → … → 2× → 1× and is saved.
ctl "{\"cmd\":\"add\",\"path\":\"$PWD\"}" >/dev/null
sleep 1
pane=$(ctl '{"cmd":"list"}' | sed -E 's/.*"pane":"([0-9A-F-]+)".*/\1/')
[ -n "$pane" ] || fail "no pane to click"
click() { ctl "{\"cmd\":\"header-click\",\"pane\":\"$pane\",\"button\":\"$1\"}"; }
speeds=""
for _ in 1 2 3 4 5; do click speed >/dev/null; sleep 0.2; speeds="$speeds $(speed)"; done
[ "$speeds" = " 1.25 1.5 1.75 2.0 1.0" ] || fail "speed cycle went:$speeds"
click speed >/dev/null
sleep 1   # the layout save is debounced 500 ms
grep -Eq '"readAloudSpeed" ?: ?1\.25' "$DIR/layout.json" || fail "speed not saved"

# 5. Settings > Read Aloud > Tone: saved, and shifts playback (1.1 = 165 cents).
ctl '{"cmd":"speak-tone","pitch":"1.1"}' >/dev/null
sleep 1   # debounced save
grep -Eq '"readAloudPitch" ?: ?1\.1' "$DIR/layout.json" || fail "tone not saved"
speak >/dev/null
for _ in $(seq 100); do [ "$(state)" = speaking ] && break; sleep 0.05; done
ctl '{"cmd":"speak-stop"}' >/dev/null
ctl '{"cmd":"speak-state"}' | grep -q '"cents":"165"' || fail "tone not applied to playback: $(ctl '{"cmd":"speak-state"}')"

# 6. Select text in a pane, right-click > Read Aloud Selection: the selection is what goes to the helper.
ctl "{\"cmd\":\"send\",\"pane\":\"$pane\",\"text\":\"echo zebra marmalade\"}" >/dev/null
sleep 1
ctl "{\"cmd\":\"select-all\",\"pane\":\"$pane\"}" | grep -q '"selected":true' || fail "nothing selected"
r=$(ctl "{\"cmd\":\"menu\",\"pane\":\"$pane\",\"item\":\"Read Aloud Selection\"}")
[ "$r" = "{}" ] || fail "no Read Aloud Selection item: $r"
sleep 0.5
grep '"text"' "$DIR/stub.py.jobs" | tail -1 | grep -q 'zebra marmalade' || fail "selection not spoken: $(grep '"text"' "$DIR/stub.py.jobs" | tail -1)"
ctl '{"cmd":"speak-stop"}' >/dev/null

echo "speech e2e ok"
