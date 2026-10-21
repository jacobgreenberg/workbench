// wbhost (bundled as Contents/Helpers/WorkbenchHost): owns one terminal pane's pty so the shell outlives the app.
// Workbench is only a viewer (Ghostty in manual IO mode); after a crash or Restart it reconnects and we replay.
// Single-threaded kqueue loop; idle = blocked in kevent.
//
// wbhost <socket-path> <cols> <rows> <cwd> <argv0> [args...]
//   envp = the shell's environment; fd 3 = the first client (one end of the app's socketpair); later clients connect
//   to <socket-path> (newest wins). Spawned with setsid and no other inherited fds.
// host -> app: 12-byte header (replay length UInt64 LE, pty cols and rows UInt16 LE), the replay, then raw output.
//   EOF = the session is over.
// app -> host frames: type byte, payload length UInt32 LE, payload:
//   'i' input for the shell (<= 1 MiB), 'w' 8 bytes cols/rows/xpixel/ypixel UInt16 LE, 'k' (empty) end the session.
//   Anything else drops that client; the session keeps running.
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <util.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define RING_CAP (1u << 20)   // ponytail: bounds how much a reattach can restore; raise if scrollback loss matters
#define MAX_FRAME (1u << 20)
#define MAX_PENDING (4u << 20)
#define OSC_MAX 512
#define OBUF_MAX 4096
#define PRE_MAX 2048

extern char **environ;

// ---- VT tracker: remembers the terminal state a replay must restore ----

enum { GROUND, ESC, CSI, OSC, OSC_ESC, STR, STR_ESC };
static const int MODES[] = {1, 6, 7, 25, 47, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 1047, 1049, 2004, 2026, 2027, 2031, 2048};
#define NMODES ((int)(sizeof MODES / sizeof MODES[0]))

struct vt {
    int state, utf8_left;
    char csi[64]; int csi_len, csi_bad;
    char osc[OSC_MAX]; int osc_len, osc_over;
    char seen[NMODES], on[NMODES];
    int keypad;
    unsigned kitty[8]; int nkitty;
    char title[OSC_MAX]; int title_len;
    char progress[OSC_MAX]; int progress_len;
};

// Parses ';'-separated decimals; an empty or malformed field is -1. Returns the field count (may exceed max).
static int csi_nums(const char *p, int n, long *out, int max) {
    int k = 0, bad = 0;
    long cur = -1;
    for (int i = 0; i <= n; i++) {
        if (i == n || p[i] == ';') {
            if (k < max) out[k] = bad ? -1 : cur;
            k++; cur = -1; bad = 0;
        } else if (p[i] >= '0' && p[i] <= '9') {
            cur = (cur < 0 ? 0 : cur) * 10 + (p[i] - '0');
            if (cur > 1000000) cur = 1000000;
        } else bad = 1;
    }
    return k;
}

static void csi_dispatch(struct vt *v, unsigned char f) {
    if (v->csi_bad) return;
    const char *p = v->csi;
    int n = v->csi_len;
    char prefix = (n && strchr("?<=>", p[0])) ? p[0] : 0;
    if (prefix) { p++; n--; }
    int inter = 0;
    for (int i = 0; i < n; i++) if (p[i] >= 0x20 && p[i] <= 0x2f) inter = 1;
    if (inter) return;
    long a[34];
    int k = csi_nums(p, n, a, 34);
    if (k > 34) k = 34;
    if (prefix == '?' && (f == 'h' || f == 'l')) {
        for (int i = 0; i < k; i++)
            for (int m = 0; m < NMODES; m++)
                if (a[i] == MODES[m]) { v->seen[m] = 1; v->on[m] = (f == 'h'); }
    } else if (prefix && f == 'u') {
        long x = a[0] < 0 ? 0 : a[0];
        if (prefix == '>') {
            if (v->nkitty == 8) { memmove(v->kitty, v->kitty + 1, 7 * sizeof v->kitty[0]); v->nkitty = 7; }
            v->kitty[v->nkitty++] = (unsigned)x;
        } else if (prefix == '<') {
            long cnt = a[0] < 0 ? 1 : a[0];
            v->nkitty = cnt >= v->nkitty ? 0 : v->nkitty - (int)cnt;
        } else {
            long mode = (k < 2 || a[1] < 0) ? 1 : a[1];
            if (v->nkitty == 0) { v->nkitty = 1; v->kitty[0] = 0; }
            unsigned *top = &v->kitty[v->nkitty - 1];
            if (mode == 1) *top = (unsigned)x;
            else if (mode == 2) *top |= (unsigned)x;
            else if (mode == 3) *top &= ~(unsigned)x;
        }
    }
}

static void osc_end(struct vt *v) {
    if (v->osc_over) return;
    if (v->osc_len >= 2 && (!memcmp(v->osc, "0;", 2) || !memcmp(v->osc, "2;", 2))) {
        memcpy(v->title, v->osc, v->osc_len); v->title_len = v->osc_len;
    } else if (v->osc_len >= 3 && !memcmp(v->osc, "9;4", 3)) {
        memcpy(v->progress, v->osc, v->osc_len); v->progress_len = v->osc_len;
    }
}

static void vt_feed(struct vt *v, unsigned char c) {
    switch (v->state) {
    case GROUND:
        if (c == 0x1b) { v->state = ESC; v->utf8_left = 0; }
        else if (c >= 0xc2 && c <= 0xf4) v->utf8_left = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : 1;
        else if (c >= 0x80 && c < 0xc0) { if (v->utf8_left) v->utf8_left--; }
        else v->utf8_left = 0;
        break;
    case ESC:
        switch (c) {
        case '[': v->state = CSI; v->csi_len = 0; v->csi_bad = 0; break;
        case ']': v->state = OSC; v->osc_len = 0; v->osc_over = 0; break;
        case 'P': case '_': case '^': case 'X': v->state = STR; break;
        case '=': v->keypad = 1; v->state = GROUND; break;
        case '>': v->keypad = 0; v->state = GROUND; break;
        case 'c': memset(v, 0, sizeof *v); break;   // RIS
        case 0x1b: break;
        default: v->state = GROUND;
        }
        break;
    case CSI:
        if (c == 0x1b) v->state = ESC;
        else if (c == 0x18 || c == 0x1a) v->state = GROUND;
        else if (c >= 0x40 && c <= 0x7e) { csi_dispatch(v, c); v->state = GROUND; }
        else if (c >= 0x20 && c <= 0x3f) {
            if (v->csi_len < 64) v->csi[v->csi_len++] = (char)c; else v->csi_bad = 1;
        }
        break;
    case OSC:
        if (c == 0x07) { osc_end(v); v->state = GROUND; }
        else if (c == 0x1b) v->state = OSC_ESC;
        else if (v->osc_len < OSC_MAX) v->osc[v->osc_len++] = (char)c;
        else v->osc_over = 1;
        break;
    case OSC_ESC:
        if (c == '\\') { osc_end(v); v->state = GROUND; }
        else { v->state = ESC; vt_feed(v, c); }
        break;
    case STR:
        if (c == 0x1b) v->state = STR_ESC;
        break;
    case STR_ESC:
        if (c == '\\') v->state = GROUND;
        else if (c != 0x1b) v->state = STR;
        break;
    }
}

// Writes the escape sequences that restore the tracked state; buf must hold PRE_MAX bytes.
static size_t vt_preamble(const struct vt *v, unsigned char *buf) {
    size_t o = 0;
    for (int pass = 0; pass < 2; pass++)
        for (int m = 0; m < NMODES; m++) {
            int alt = MODES[m] == 47 || MODES[m] == 1047 || MODES[m] == 1049;
            if (!v->seen[m] || alt != (pass == 0)) continue;
            o += (size_t)snprintf((char *)buf + o, PRE_MAX - o, "\x1b[?%d%c", MODES[m], v->on[m] ? 'h' : 'l');
        }
    if (v->keypad) { memcpy(buf + o, "\x1b=", 2); o += 2; }
    for (int i = 0; i < v->nkitty; i++)
        o += (size_t)snprintf((char *)buf + o, PRE_MAX - o, "\x1b[>%uu", v->kitty[i]);
    const char *s[2] = {v->title, v->progress};
    int l[2] = {v->title_len, v->progress_len};
    for (int i = 0; i < 2; i++) {
        if (!l[i]) continue;
        memcpy(buf + o, "\x1b]", 2); o += 2;
        memcpy(buf + o, s[i], l[i]); o += l[i];
        memcpy(buf + o, "\x1b\\", 2); o += 2;
    }
    return o;
}

// ---- Ring buffer: the newest output; evicted bytes feed `base` ----

struct ring { unsigned char *buf; size_t cap, start, len; struct vt base; };

static void ring_init(struct ring *r, size_t cap) { memset(r, 0, sizeof *r); r->cap = cap; }

static void ring_append(struct ring *r, const unsigned char *d, size_t n) {
    if (!n) return;
    if (!r->buf && !(r->buf = malloc(r->cap))) {   // no memory: track state only
        for (size_t i = 0; i < n; i++) vt_feed(&r->base, d[i]);
        return;
    }
    if (n > r->cap) {
        for (size_t i = 0; i < r->len; i++) vt_feed(&r->base, r->buf[(r->start + i) % r->cap]);
        for (size_t i = 0; i < n - r->cap; i++) vt_feed(&r->base, d[i]);
        d += n - r->cap; n = r->cap; r->start = 0; r->len = 0;
    }
    if (r->len + n > r->cap) {
        size_t ev = r->len + n - r->cap;
        for (size_t i = 0; i < ev; i++) vt_feed(&r->base, r->buf[(r->start + i) % r->cap]);
        r->start = (r->start + ev) % r->cap; r->len -= ev;
    }
    size_t end = (r->start + r->len) % r->cap, first = r->cap - end < n ? r->cap - end : n;
    memcpy(r->buf + end, d, first);
    memcpy(r->buf, d + first, n - first);
    r->len += n;
}

// Replay = preamble + ring contents minus anything that would re-notify. Returns a malloc'd buffer (NULL on OOM).
static unsigned char *build_replay(const struct ring *r, size_t *outlen) {
    unsigned char *out = malloc(r->len + PRE_MAX);
    if (!out) return NULL;
    size_t o = vt_preamble(&r->base, out), i = 0;
    struct vt t = r->base;
    while (i < r->len && (t.state != GROUND || t.utf8_left > 0)) vt_feed(&t, r->buf[(r->start + i++) % r->cap]);
    unsigned char ob[OBUF_MAX];
    size_t ol = 0;
    int buffering = 0, passthru = 0, held = 0;
    for (; i < r->len; i++) {
        unsigned char c = r->buf[(r->start + i) % r->cap];
        int s = t.state;
        vt_feed(&t, c);
        if (buffering) {
            if (ol == OBUF_MAX) { memcpy(out + o, ob, ol); o += ol; buffering = 0; passthru = 1; out[o++] = c; continue; }
            ob[ol++] = c;
            if (t.state == OSC || t.state == OSC_ESC) continue;
            int done = t.state == GROUND && (c == 0x07 || (s == OSC_ESC && c == '\\'));
            const char *p = t.osc;
            int drop = done && ((t.osc_len >= 2 && !memcmp(p, "9;", 2) && !(t.osc_len >= 3 && p[2] == '4')) ||
                                (t.osc_len >= 4 && !memcmp(p, "777;", 4)) || (t.osc_len >= 3 && !memcmp(p, "99;", 3)));
            if (!drop) { memcpy(out + o, ob, ol); o += ol; }
            buffering = 0; ol = 0;
            continue;
        }
        if (held) {
            held = 0;
            if (t.state == OSC && !passthru) { ob[0] = 0x1b; ob[1] = c; ol = 2; buffering = 1; continue; }
            out[o++] = 0x1b;
        }
        if (s == GROUND && c == 0x1b) { held = 1; continue; }
        if (s != OSC && s != OSC_ESC) passthru = 0;
        if (s == GROUND && c == 0x07) continue;
        out[o++] = c;
    }
    if (held) out[o++] = 0x1b;
    if (buffering) { memcpy(out + o, ob, ol); o += ol; }
    *outlen = o;
    return out;
}

// ---- Host ----

static struct ring ring;
static int kq = -1, master = -1, listener = -1, client = -1, master_live = 1, wr_armed, need_winch;
static pid_t child;
static const char *sock_path;
static ino_t listen_ino;
static unsigned char *fbuf, *pend;
static size_t flen, fcap, plen, poff, pcap;

static int ev(uintptr_t id, int16_t filter, uint16_t flags, uint32_t fflags) {
    struct kevent k;
    EV_SET(&k, id, filter, flags, fflags, 0, NULL);
    return kevent(kq, &k, 1, NULL, 0, NULL);
}

static int write_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = write(fd, c, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        c += w; n -= (size_t)w;
    }
    return 0;
}

static int grow(unsigned char **b, size_t *cap, size_t need) {
    if (need <= *cap) return 0;
    size_t nc = *cap ? *cap : 4096;
    while (nc < need) nc *= 2;
    unsigned char *nb = realloc(*b, nc);
    if (!nb) return -1;
    *b = nb; *cap = nc;
    return 0;
}

static void drop_client(void) {
    if (client >= 0) close(client);   // closing removes its kqueue filter
    client = -1; flen = 0;
}

static void cleanup(void) {
    struct stat st;   // a newer host may own the path now
    if (listener >= 0 && stat(sock_path, &st) == 0 && st.st_ino == listen_ino) unlink(sock_path);
}

static void forward(const unsigned char *d, size_t n) {
    ring_append(&ring, d, n);
    if (client >= 0 && write_all(client, d, n) < 0) drop_client();
}

static void pump(void) {
    unsigned char buf[65536];
    for (;;) {
        ssize_t n = read(master, buf, sizeof buf);
        if (n > 0) { forward(buf, (size_t)n); continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) return;
        master_live = 0;   // hung up: wait for the child to exit
        ev((uintptr_t)master, EVFILT_READ, EV_DELETE, 0);
        if (wr_armed) { ev((uintptr_t)master, EVFILT_WRITE, EV_DELETE, 0); wr_armed = 0; }
        return;
    }
}

static void flush_pending(void) {
    while (master_live && poff < plen) {
        ssize_t w = write(master, pend + poff, plen - poff);
        if (w > 0) { poff += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && errno == EAGAIN) break;
        poff = plen;   // pty gone: discard
    }
    if (poff >= plen) poff = plen = 0;
    int want = poff < plen;
    if (want != wr_armed && master_live) {
        ev((uintptr_t)master, EVFILT_WRITE, want ? EV_ADD : EV_DELETE, 0);
        wr_armed = want;
    }
}

static int reaped(int ms_total) {
    struct timespec ts = {0, 50 * 1000000};
    for (int i = 0; i < ms_total / 50; i++) {
        if (waitpid(child, NULL, WNOHANG) != 0) return 1;
        nanosleep(&ts, NULL);
    }
    return waitpid(child, NULL, WNOHANG) != 0;
}

static void end_session(void) {
    kill(-child, SIGHUP);
    close(master);
    if (!reaped(2000)) {
        kill(-child, SIGTERM);
        if (!reaped(1000)) kill(-child, SIGKILL);
    }
    cleanup();
    exit(0);
}

static void on_frame(unsigned char type, const unsigned char *p, uint32_t n) {
    if (type == 'i') {
        if (plen - poff + n > MAX_PENDING) { drop_client(); return; }
        if (poff && poff == plen) poff = plen = 0;
        if (grow(&pend, &pcap, plen + n) < 0) { drop_client(); return; }
        memcpy(pend + plen, p, n); plen += n;
        flush_pending();
    } else if (type == 'w') {
        struct winsize ws = {.ws_col = (unsigned short)(p[0] | p[1] << 8), .ws_row = (unsigned short)(p[2] | p[3] << 8),
                             .ws_xpixel = (unsigned short)(p[4] | p[5] << 8), .ws_ypixel = (unsigned short)(p[6] | p[7] << 8)};
        if (master_live) ioctl(master, TIOCSWINSZ, &ws);
        if (need_winch) {   // size may be unchanged after a reattach; nudge full-screen apps to redraw anyway
            need_winch = 0;
            pid_t pg = tcgetpgrp(master);
            if (pg > 0) kill(-pg, SIGWINCH);
        }
    } else end_session();
}

static void client_read(void) {
    if (grow(&fbuf, &fcap, flen + 65536) < 0) { drop_client(); return; }
    ssize_t n = recv(client, fbuf + flen, fcap - flen, MSG_DONTWAIT);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) return;
    if (n <= 0) { drop_client(); return; }
    flen += (size_t)n;
    size_t off = 0;
    while (client >= 0 && flen - off >= 5) {
        const unsigned char *f = fbuf + off;
        uint32_t len = (uint32_t)f[1] | (uint32_t)f[2] << 8 | (uint32_t)f[3] << 16 | (uint32_t)f[4] << 24;
        if (len > MAX_FRAME || (f[0] != 'i' && f[0] != 'w' && f[0] != 'k') || (f[0] == 'w' && len != 8) ||
            (f[0] == 'k' && len != 0)) { drop_client(); return; }
        if (flen - off < 5 + (size_t)len) break;
        off += 5 + (size_t)len;
        on_frame(f[0], f + 5, len);
    }
    if (client >= 0) { memmove(fbuf, fbuf + off, flen - off); flen -= off; }
}

// Header: replay length (UInt64 LE), then the pty's cols and rows (UInt16 LE): the app sizes its view to the grid
// the replay was drawn for before playing it, or cursor-relative redraws land in the wrong place.
static void header(unsigned char *h, size_t n, unsigned cols, unsigned rows) {
    for (int i = 0; i < 8; i++) h[i] = (unsigned char)((uint64_t)n >> (8 * i));
    h[8] = (unsigned char)cols; h[9] = (unsigned char)(cols >> 8); h[10] = (unsigned char)rows; h[11] = (unsigned char)(rows >> 8);
}

static void accept_client(void) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    drop_client();   // newest app instance wins
    client = fd;
    if (ev((uintptr_t)fd, EVFILT_READ, EV_ADD, 0) < 0) { drop_client(); return; }
    size_t n = 0;
    unsigned char *rp = build_replay(&ring, &n);
    if (!rp) n = 0;
    struct winsize ws = {0};
    if (master_live) ioctl(master, TIOCGWINSZ, &ws);
    unsigned char hdr[12];
    header(hdr, n, ws.ws_col, ws.ws_row);
    if (write_all(fd, hdr, 12) < 0 || (n && write_all(fd, rp, n) < 0)) drop_client();
    free(rp);
    need_winch = 1;
}

static void child_exited(void) {
    waitpid(child, NULL, 0);
    if (master_live) pump();
    cleanup();
    exit(0);
}

static void listen_on(const char *path) {
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    struct stat st;
    if (strlen(path) >= sizeof sa.sun_path) return;
    strcpy(sa.sun_path, path);
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 || chmod(path, 0600) < 0 || listen(fd, 4) < 0 ||
        stat(path, &st) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); unlink(path); return; }   // no stray path: the app reads one as "killed"
    listener = fd; listen_ino = st.st_ino;
}

// ---- Self-test ----

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "selftest FAIL: %s\n", msg); exit(1); } } while (0)

static const char *find(const unsigned char *h, size_t hn, const char *needle) {
    return memmem(h, hn, needle, strlen(needle));
}

static void feed(struct ring *r, const char *s) { ring_append(r, (const unsigned char *)s, strlen(s)); }

static void selftest(void) {
    unsigned char pre[PRE_MAX], *rp;
    size_t n;
    struct ring r;
    const char *x = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

    ring_init(&r, 16);
    feed(&r, "\x1b[?2004h\x1b[?1049h"); feed(&r, x);
    n = vt_preamble(&r.base, pre);
    const char *a = find(pre, n, "\x1b[?1049h"), *b = find(pre, n, "\x1b[?2004h");
    CHECK(a && b && a < b, "alt screen before other modes");
    free(r.buf);

    ring_init(&r, 16);
    feed(&r, "\x1b[>1u"); feed(&r, x);
    n = vt_preamble(&r.base, pre);
    CHECK(find(pre, n, "\x1b[>1u"), "kitty push in preamble");
    feed(&r, "\x1b[<u"); feed(&r, x);
    n = vt_preamble(&r.base, pre);
    CHECK(!find(pre, n, "\x1b[>"), "kitty pop clears preamble");
    free(r.buf);

    ring_init(&r, 256);
    feed(&r, "a\x07" "b\x1b]9;hello\x07" "c\x1b]9;4;1;50\x07" "d\x1b]0;T\x07");
    rp = build_replay(&r, &n);
    const char *want = "abc\x1b]9;4;1;50\x07" "d\x1b]0;T\x07";
    CHECK(rp && n == strlen(want) && !memcmp(rp, want, n), "notification filtering");
    free(rp); free(r.buf);

    ring_init(&r, 3);
    feed(&r, "\x1b[31mX");
    rp = build_replay(&r, &n);
    CHECK(rp && n == 1 && rp[0] == 'X', "alignment skips partial CSI");
    free(rp); free(r.buf);

    ring_init(&r, 16);
    feed(&r, "\x1b]0;T\x07\x1b]9;4;1;50\x07"); feed(&r, x);
    n = vt_preamble(&r.base, pre);
    CHECK(find(pre, n, "\x1b]0;T\x1b\\") && find(pre, n, "\x1b]9;4;1;50\x1b\\"), "title/progress in preamble");
    free(r.buf);
    puts("selftest ok");
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--selftest")) { selftest(); return 0; }
    if (argc < 6) { fprintf(stderr, "usage: wbhost <socket> <cols> <rows> <cwd> <argv0> [args...]\n"); return 2; }
    signal(SIGPIPE, SIG_IGN);
    char *e1, *e2;
    long cols = strtol(argv[2], &e1, 10), rows = strtol(argv[3], &e2, 10);
    if (*e1 || *e2 || cols < 1 || cols > 65535 || rows < 1 || rows > 65535) return 2;
    sock_path = argv[1];
    ring_init(&ring, RING_CAP);
    listen_on(sock_path);

    kq = kqueue();
    if (kq < 0 || fcntl(kq, F_SETFD, FD_CLOEXEC) < 0) { perror("kqueue"); cleanup(); return 1; }
    client = fcntl(3, F_SETFD, FD_CLOEXEC) < 0 ? -1 : 3;

    struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) { perror("forkpty"); cleanup(); return 1; }
    if (pid == 0) {
        signal(SIGPIPE, SIG_DFL);
        if (chdir(argv[4]) < 0) { const char *h = getenv("HOME"); if (!h || chdir(h) < 0) chdir("/"); }
        execve(argv[5], argv + 5, environ);
        _exit(127);
    }
    child = pid;
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 || fcntl(master, F_SETFL, O_NONBLOCK) < 0) { perror("fcntl"); kill(-child, SIGKILL); cleanup(); return 1; }

    if (client >= 0) {
        unsigned char hdr[12];
        header(hdr, 0, (unsigned)cols, (unsigned)rows);
        if (write_all(client, hdr, 12) < 0) drop_client();
    }
    if (ev((uintptr_t)master, EVFILT_READ, EV_ADD, 0) < 0 ||
        (listener >= 0 && ev((uintptr_t)listener, EVFILT_READ, EV_ADD, 0) < 0) ||
        (client >= 0 && ev((uintptr_t)client, EVFILT_READ, EV_ADD, 0) < 0)) { perror("kevent"); kill(-child, SIGKILL); cleanup(); return 1; }
    if (ev((uintptr_t)child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT) < 0) child_exited();   // already gone

    for (;;) {
        struct kevent evs[8];
        int n = kevent(kq, NULL, 0, evs, 8, NULL);
        if (n < 0) { if (errno == EINTR) continue; perror("kevent"); kill(-child, SIGKILL); cleanup(); return 1; }
        for (int i = 0; i < n; i++) {
            int id = (int)evs[i].ident;
            if (evs[i].filter == EVFILT_PROC) child_exited();
            else if (evs[i].filter == EVFILT_WRITE && id == master) flush_pending();
            else if (evs[i].filter != EVFILT_READ) continue;
            else if (id == master && master_live) pump();
            else if (id == listener) accept_client();
            else if (id == client) client_read();
        }
    }
}
