#!/usr/bin/env python3
"""End-to-end tests for New Project > Clone Repository.

Runs a debug Workbench in its own state directory (PANE_STATE_DIR) and drives it through the control socket's test
harness commands. Git never touches the network: https://git.example.test/ is rewritten (url.insteadOf) to a local
smart-HTTP server (git http-backend, Basic auth under /private/, pack responses throttled so progress is visible), and
ssh goes through a fake ssh that runs git-upload-pack on local bare repositories.

    scripts/bundle.sh --debug
    python3 -I scripts/e2e/clone.py [--app build.noindex/Workbench-debug.app] [--keep] [-k name]

Not covered: real TLS/ssh servers, host key and passphrase prompts, the done notification banner, the Files tab.
"""
import argparse
import base64
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HOST = "git.example.test"
USER, PASSWORD = "tester", "secret1"
REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# US ANSI virtual key codes, for typing into a pane with real key events (`key` harness command).
KEYCODES = {c: k for k, c in enumerate("asdfhgzxcv")} | {"b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "\r": 36}


# MARK: - Local git server

class GitHTTP(http.server.BaseHTTPRequestHandler):
    """Smart HTTP over `git http-backend` (CGI). Repos under /private/ need Basic auth."""
    root = ""

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.serve()

    def do_POST(self):
        self.serve()

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def serve(self):
        path, _, query = self.path.partition("?")
        user = ""
        if path.startswith("/private/"):
            expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="e2e"')
                self.end_headers()
                return
            user = USER
        env = dict(os.environ, GIT_PROJECT_ROOT=self.root, GIT_HTTP_EXPORT_ALL="1", PATH_INFO=path,
                   QUERY_STRING=query, REQUEST_METHOD=self.command, REMOTE_USER=user,
                   CONTENT_TYPE=self.headers.get("Content-Type", ""),
                   HTTP_CONTENT_ENCODING=self.headers.get("Content-Encoding", ""),
                   HTTP_GIT_PROTOCOL=self.headers.get("Git-Protocol", ""))
        data = self.body() if self.command == "POST" else b""
        env["CONTENT_LENGTH"] = str(len(data))
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n") if b"\r\n\r\n" in out else out.partition(b"\n\n")
        status, headers = 200, []
        for line in head.decode().splitlines():
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            else:
                headers.append((name, value.strip()))
        self.send_response(status)
        for h in headers:
            self.send_header(*h)
        self.end_headers()
        slow = path.endswith("/git-upload-pack") and len(rest) > 256 * 1024   # a pack: slow enough to see progress
        for i in range(0, len(rest), 16 * 1024):
            self.wfile.write(rest[i:i + 16 * 1024])
            if slow:
                time.sleep(0.01)


# MARK: - Control socket

class App:
    def __init__(self, app, state, env, log):
        self.sock = os.path.join(state, "pane.sock")
        self.state = state
        self.proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/Workbench")], env=env,
                                     stdout=log, stderr=subprocess.STDOUT)
        wait(lambda: self.ping(), 30, "Workbench to answer on its control socket")

    def ping(self):
        try:
            return isinstance(self.call("list"), list)
        except OSError:
            return False

    def call(self, cmd, **args):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        try:
            s.connect(self.sock)
            s.sendall(json.dumps({"cmd": cmd, **args}).encode() + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        finally:
            s.close()
        return json.loads(data)

    def ok(self, cmd, **args):
        reply = self.call(cmd, **args)
        assert not (isinstance(reply, dict) and "error" in reply), f"{cmd} {args}: {reply}"
        return reply

    def projects(self):
        return {row["project"] for row in self.call("list")}

    def pane(self, project):
        return next(row["pane"] for row in self.call("list") if row["project"] == project and row["kind"] == "terminal")

    def clones(self):
        return self.call("clones")

    def type(self, pane, text):
        for c in text:
            self.ok("key", pane=pane, code=str(KEYCODES[c]), chars=c)
            time.sleep(0.03)

    def quit(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        # A killed app leaves its terminal sessions running (that is how crashes survive): end them.
        subprocess.run(["pkill", "-f", os.path.join(self.state, "s") + "/"], check=False)


def wait(cond, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError(f"timed out after {timeout}s waiting for {what}")


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


# MARK: - Fixture

class Fixture:
    def __init__(self, keep):
        # /tmp, not $TMPDIR: unix socket paths must fit in 104 bytes.
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="wbe2e-", dir="/tmp"))
        self.keep = keep
        self.repos = os.path.join(self.root, "repos")
        self.work = os.path.join(self.root, "work")
        self.state = os.path.join(self.root, "state")
        for d in (self.repos, self.work, self.state):
            os.makedirs(d)
        self.gitconfig = os.path.join(self.root, "gitconfig")
        self.git_env = dict(os.environ, GIT_CONFIG_GLOBAL=self.gitconfig, GIT_CONFIG_NOSYSTEM="1")
        with open(self.gitconfig, "w") as f:
            f.write("[init]\n\tdefaultBranch = main\n[user]\n\tname = e2e\n\temail = e2e@example.test\n")
        os.environ.update(GIT_CONFIG_GLOBAL=self.gitconfig, GIT_CONFIG_NOSYSTEM="1")

        GitHTTP.root = self.repos
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHTTP)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        port = self.server.server_address[1]
        with open(self.gitconfig, "a") as f:
            f.write(f'[url "http://127.0.0.1:{port}/"]\n\tinsteadOf = https://{HOST}/\n')

        # Fake ssh (GIT_SSH_VARIANT=simple: argv is host then command): run git-upload-pack on the local repos.
        self.ssh = os.path.join(self.root, "fake-ssh")
        with open(self.ssh, "w") as f:
            f.write(f'#!/bin/sh\nfor last; do :; done\ncd {self.repos} || exit 1\nexec sh -c "$last"\n')
        os.chmod(self.ssh, 0o755)

        self.repo("acme/widgets", big=True)
        for name in ("other/gadgets", "acme/gadgets", "acme/tools", "acme/sprockets", "private/vault"):
            self.repo(name)

        with open(os.path.join(self.state, "layout.json"), "w") as f:
            json.dump({"projects": [], "activeProject": -1, "sidebarVisible": True, "theme": "system-dark",
                       "cloneLocations": [self.work]}, f)

    def repo(self, name, big=False):
        src = os.path.join(self.root, "src", name)
        os.makedirs(src)
        git("init", "-q", cwd=src)
        with open(os.path.join(src, "README.md"), "w") as f:
            f.write(f"# {name}\n")
        if big:   # incompressible, so the pack takes a few seconds through the throttle
            for i in range(6):
                with open(os.path.join(src, f"blob{i}.bin"), "wb") as f:
                    f.write(os.urandom(512 * 1024))
        git("add", "-A", cwd=src)
        git("commit", "-qm", "initial", cwd=src)
        bare = os.path.join(self.repos, name + ".git")
        git("clone", "-q", "--bare", src, bare)
        return bare

    def app_env(self):
        env = dict(os.environ, PANE_STATE_DIR=self.state, GIT_CONFIG_GLOBAL=self.gitconfig, GIT_CONFIG_NOSYSTEM="1",
                   GIT_SSH_COMMAND=self.ssh, GIT_SSH_VARIANT="simple", GIT_TERMINAL_PROMPT="1")
        for k in ("GIT_ASKPASS", "SSH_ASKPASS"):
            env.pop(k, None)
        return env

    def cleanup(self):
        self.server.shutdown()
        if not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)


# MARK: - Tests

def cloned(app, f, project, url):
    """The clone of `project` finished: no clone row left, and its folder is a checkout of `url`."""
    path = os.path.join(f.work, project)
    wait(lambda: project not in app.clones() and os.path.isdir(os.path.join(path, ".git")), 60, f"{project} to clone")
    assert git("-C", path, "config", "remote.origin.url") == url
    assert git("-C", path, "status", "--porcelain") == "", "checkout is not clean"
    assert project in app.projects()


def failed(app, project, reason=None):
    """The clone of `project` failed (with `reason`, if given). Returns the row's state."""
    want = f'failed("{reason}")' if reason else "failed("
    return wait(lambda: (st := app.clones().get(project, "")).startswith(want) and st, 30,
                f"{project} to show {want} (now {app.clones().get(project)})")


def test_https_clone_with_progress(app, f):
    url = f"https://{HOST}/acme/widgets.git"
    app.ok("newproject", url=url)
    s = app.ok("sheet")
    assert s["mode"] == "clone" and s["urlNote"] == f"✓ {HOST} · acme/widgets", s
    assert s["location"] == f.work and s["destination"] == f"Clones into {f.work}/widgets", s
    assert s["conflict"] == "" and s["primaryEnabled"] == "yes", s
    assert app.ok("sheet", press="primary")["pressed"] == "yes"
    seen = set()
    def done():
        st = app.clones().get("widgets")
        if st:
            seen.add(st)
        return st is None
    wait(done, 60, "widgets to clone")
    partial = [s for s in seen if s.startswith("cloning(") and s not in ("cloning(0)", "cloning(100)")]
    assert partial, f"no progress between 0 and 100% was shown: {seen}"
    cloned(app, f, "widgets", url)


def test_ssh_clone(app, f):
    url = f"git@{HOST}:other/gadgets.git"
    app.ok("clone", url=url)
    assert app.clones().get("gadgets", "").startswith(("cloning(", "failed")) or "gadgets" in app.projects()
    cloned(app, f, "gadgets", url)


def test_credential_prompt(app, f):
    url = f"https://{HOST}/private/vault.git"
    app.ok("clone", url=url)
    wait(lambda: app.clones().get("vault") == 'waiting("Waiting for username")', 30, "the username prompt")
    pane = app.pane("vault")
    app.type(pane, USER)
    wait(lambda: app.clones().get("vault", "").startswith("cloning("), 10, "typing to clear the prompt")
    app.type(pane, "\r")
    wait(lambda: app.clones().get("vault") == 'waiting("Waiting for password")', 30, "the password prompt")
    app.type(pane, PASSWORD + "\r")
    cloned(app, f, "vault", url)


def test_bad_url_retry(app, f):
    url = f"https://{HOST}/acme/missing.git"
    app.ok("clone", url=url)
    failed(app, "missing", "repository not found")
    assert "missing" in app.projects()
    f.repo("acme/missing")   # it exists now: Retry succeeds
    app.ok("cloneaction", project="missing", name="retry")
    cloned(app, f, "missing", url)


def test_bad_url_edit(app, f):
    app.ok("clone", url=f"https://{HOST}/acme/sprokets.git")
    failed(app, "sprokets", "repository not found")
    app.ok("cloneaction", project="sprokets", name="edit")
    s = wait(lambda: (r := app.call("sheet")) and "error" not in r and r, 10, "the sheet to open")
    assert s["url"] == f"https://{HOST}/acme/sprokets.git" and s["location"] == f.work, s
    fixed = f"https://{HOST}/acme/sprockets.git"
    s = app.ok("sheet", url=fixed)
    assert s["destination"] == f"Clones into {f.work}/sprockets", s
    app.ok("sheet", press="primary")
    cloned(app, f, "sprockets", fixed)
    assert "sprokets" not in app.projects() and "sprokets" not in app.clones(), "the failed clone was not replaced"


def test_bad_url_remove(app, f):
    app.ok("clone", url=f"git@{HOST}:acme/nope.git")
    failed(app, "nope")   # the fake ssh's upload-pack error, not a mapped one
    app.ok("cloneaction", project="nope", name="remove")
    wait(lambda: "nope" not in app.projects() and "nope" not in app.clones(), 10, "nope to be removed")
    assert not os.path.exists(os.path.join(f.work, "nope"))


def test_existing_same_origin(app, f):
    # tools is checked out already (outside Workbench), from the same repository under its https URL.
    path = os.path.join(f.work, "tools")
    git("clone", "-q", os.path.join(f.repos, "acme/tools.git"), path)
    git("-C", path, "remote", "set-url", "origin", f"https://{HOST}/acme/tools.git")
    app.ok("newproject")
    s = app.ok("sheet", url=f"git@{HOST}:acme/tools.git")   # the ssh form of the same repository
    assert s["conflict"] == f"{path} already exists", s
    assert "origin matches, branch main" in s["conflictDetail"] and s["openExisting"] == "shown", s
    assert s["name"] == "tools-2" and s["nameNote"] == f"Clones into {path}-2", s
    assert app.ok("sheet", press="openExisting")["pressed"] == "yes"
    wait(lambda: "tools" in app.projects(), 10, "tools to be added")
    assert "tools" not in app.clones() and not os.path.exists(path + "-2"), "Open Existing started a clone"


def test_existing_other_origin(app, f):
    # gadgets is a clone of other/gadgets (test_ssh_clone, or made here); acme/gadgets wants the same folder.
    path = os.path.join(f.work, "gadgets")
    if not os.path.isdir(path):
        git("clone", "-q", os.path.join(f.repos, "other/gadgets.git"), path)
        git("-C", path, "remote", "set-url", "origin", f"git@{HOST}:other/gadgets.git")
    url = f"https://{HOST}/acme/gadgets.git"
    app.ok("newproject")
    s = app.ok("sheet", url=url)
    assert s["conflict"] == f"{path} already exists", s
    assert s["conflictDetail"] == f"It’s a clone of another repository: git@{HOST}:other/gadgets.git.", s
    assert s["openExisting"] == "hidden" and s["name"] == "gadgets-2" and s["primaryEnabled"] == "yes", s
    s = app.ok("sheet", name="gadgets")
    assert s["nameNote"] == "gadgets exists too" and s["primaryEnabled"] == "no", s
    assert app.ok("sheet", press="primary")["pressed"] == "no"
    app.ok("sheet", name="gadgets-2")
    app.ok("sheet", press="primary")
    cloned(app, f, "gadgets-2", url)


TESTS = [test_https_clone_with_progress, test_ssh_clone, test_credential_prompt, test_bad_url_retry,
         test_bad_url_edit, test_bad_url_remove, test_existing_same_origin, test_existing_other_origin]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=os.path.join(REPO_DIR, "build.noindex/Workbench-debug.app"))
    ap.add_argument("--keep", action="store_true", help="keep the temp folder (repos, clones, app log)")
    ap.add_argument("-k", dest="only", help="run tests whose name contains this")
    a = ap.parse_args()
    if not os.path.isdir(a.app):
        sys.exit(f"{a.app} not found: run scripts/bundle.sh --debug")

    f = Fixture(a.keep)
    log = open(os.path.join(f.root, "app.log"), "w")
    app = App(a.app, f.state, f.app_env(), log)
    failures = 0
    try:
        for t in TESTS:
            if a.only and a.only not in t.__name__:
                continue
            start = time.time()
            try:
                t(app, f)
                print(f"PASS {t.__name__} ({time.time() - start:.1f}s)", flush=True)
            except Exception:
                failures += 1
                print(f"FAIL {t.__name__}\n{traceback.format_exc()}", flush=True)
                if app.call("sheet").get("error") is None:
                    app.call("sheet", press="cancel")   # a sheet left open would block the next test
                app.call("snapshot", path=os.path.join(f.root, t.__name__))
                f.keep = True
    finally:
        app.quit()
        f.cleanup()
    if f.keep:
        print(f"kept {f.root}")
    print("ok" if not failures else f"{failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
