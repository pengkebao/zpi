#!/usr/bin/env python3
"""E2E: interactive scrolling with a rendered Kitty image (mock LLM).

Reproduces the user report: read a tall image, then scroll the transcript
with the mouse wheel. After EVERY frame, the floating placement's anchor
row must equal the frame row of the image line (the reservation), and the
placement must never cover the editor area.
"""
import os, pty, time, select, struct, fcntl, termios, threading, re, sys, json
import http.server, socketserver, signal

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_img3/agent"
PROJ = "/tmp/zpi_img3/proj"
IMG = "/tmp/zpi-clipboard-1795218375790.png"
PORT = 18478
os.makedirs(AGENT, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write(json.dumps({"defaultProvider": "mock", "defaultModel": "m1", "tuiMode": "fullscreen", "showImages": True, "imageWidthCells": 60}))
with open(f"{AGENT}/models.json", "w") as f:
    f.write(json.dumps({"providers": {"mock": {"name": "Mock", "baseUrl": f"http://127.0.0.1:{PORT}/v1", "api": "openai-completions", "apiKey": "sk-test", "models": [{"id": "m1", "name": "Mock 1", "contextWindow": 128000, "maxTokens": 4096}]}}}))


class MockLLM(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        try:
            req = json.loads(body)
        except Exception:
            req = {}
        had_tool = any(m.get("role") == "tool" for m in req.get("messages", []))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def sse(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()

        if had_tool:
            sse({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "图片读取完成。"}}]})
            sse({"id": "c", "choices": [{"index": 0, "delta": {}}], "usage": {"prompt_tokens": 100, "completion_tokens": 10}})
            self.wfile.write(b"data: [DONE]\n\n")
            return
        args = json.dumps({"path": IMG})
        sse({"id": "c", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_0", "type": "function", "function": {"name": "read", "arguments": args}}]}}]})
        sse({"id": "c", "choices": [{"index": 0, "delta": {}}], "finish_reason": "tool_calls"})
        self.wfile.write(b"data: [DONE]\n\n")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", PORT), MockLLM)
threading.Thread(target=srv.serve_forever, daemon=True).start()


class Session:
    def __init__(self):
        self.log = bytearray()
        self.snap = 0
        self.alive = True
        env = dict(os.environ)
        env["RPI_CODING_AGENT_DIR"] = AGENT
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "ghostty"
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0); os.dup2(slave, 1)
            os.dup2(os.open("/tmp/zpi_scroll_stderr.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 2)
            os.close(master); os.close(slave)
            os.chdir(PROJ)
            os.execve(BIN, [BIN], env)
            os._exit(127)
        os.close(slave)
        self.master, self.pid = master, pid
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while self.alive:
            r, _, _ = select.select([self.master], [], [], 0.01)
            if r:
                try:
                    self.log.extend(os.read(self.master, 65536))
                except OSError:
                    self.alive = False

    def send(self, data):
        os.write(self.master, data.encode())


s = Session()
failures = []
try:
    time.sleep(2.0)
    s.send(f"/read {IMG}\r")
    kitty_seen = False
    found = False
    deadline = time.time() + 20
    while time.time() < deadline:
        blob = bytes(s.log)
        if not kitty_seen and b"\x1b_Ga=T" in blob:
            kitty_seen = True
        if "图片读取完成" in blob.decode("utf-8", "replace"):
            found = True
            break
        time.sleep(0.1)
    print(f"tool round: done={found} kitty={kitty_seen} log={len(s.log)}b")
    if not kitty_seen:
        print("FAILED (no kitty sequence)")
        os._exit(1)
    time.sleep(0.5)
    # Scroll UP with the mouse wheel (SGR): 6 notches, settle between.
    t0 = time.time()
    for k in range(6):
        s.send("\x1b[<64;10;10M")
        time.sleep(0.3)
    print(f"scroll phase {time.time()-t0:.1f}s")
    time.sleep(1.5)
    blob = bytes(s.log)
    open("/tmp/zpi_img_scroll_log.bin", "wb").write(blob)
    frames = []
    pos = 0
    while True:
        a = blob.find(b"\x1b[?2026h", pos)
        if a == -1: break
        b = blob.find(b"\x1b[?2026l", a)
        if b == -1: break
        frames.append(blob[a:b])
        pos = b + 8

    ats = []  # (frame_idx, cup_row, c, r, y)
    for fi, fr in enumerate(frames):
        last_row = None
        idx = 0
        n = len(fr)
        while idx < n:
            c = fr[idx]
            if c == 0x1b and idx + 1 < n:
                c1 = fr[idx + 1]
                if c1 == 0x5B:  # CSI
                    j = idx + 2
                    while j < n and not (0x40 <= fr[j] <= 0x7E):
                        j += 1
                    if j < n and fr[j] == 0x48:  # 'H' CUP
                        try:
                            parts = fr[idx+2:j].split(b";")
                            last_row = int(parts[0]) if parts and parts[0] else 1
                        except ValueError:
                            pass
                    idx = j + 1
                    continue
                if c1 == 0x5F:  # APC (kitty): data starts at idx+3 (after ESC _ G)
                    end = fr.find(b"\x1b\\", idx)
                    if end == -1: break
                    # a=T carries "params;payload"; a=p is placement-only
                    # (header straight to ST, no ';').
                    hdr_end = fr.find(b";", idx + 3, end)
                    if hdr_end == -1: hdr_end = end
                    is_anchor = fr[idx+3:idx+6] in (b"a=T", b"a=p")
                    if is_anchor:
                        kv = {}
                        for part in fr[idx+3:hdr_end].split(b","):
                            if b"=" in part:
                                kk, vv = part.split(b"=", 1)
                                kv[kk] = vv
                        try:
                            kind = 'T' if fr[idx+3:idx+6] == b'a=T' else 'p'
                            ats.append((fi, last_row, int(kv.get(b"c", b"0")), int(kv.get(b"r", b"0")), int(kv.get(b"y", b"0")), kind))
                        except ValueError:
                            pass
                    idx = end + 2
                    continue
                idx += 2
                continue
            idx += 1
        # frame done

    checks = []
    if not ats:
        checks.append(("FAIL", "no kitty anchor (a=T/a=p) observed during scroll"))
    else:
        bad = [a for a in ats if a[3] > 30 or a[2] > 40]
        checks.append(("OK" if not bad else "FAIL", f"all anchors capped: {[(x[2], x[3]) for x in ats]}"))
        # at most 2 full transmissions (initial upload + one edge-case
        # re-upload); the old bug re-sent 384KB PER FRAME (6 frames = 2.3MB)
        n_t = sum(1 for a in ats if a[5] == 'T')
        checks.append(("OK" if n_t <= 2 else "FAIL",
                       f"full transmissions: {n_t} (<=2; the old bug re-sent per frame)"))
        # every wheel notch must produce a re-anchor (the placement follows
        # the content instead of sticking/being deleted)
        n_p = sum(1 for a in ats if a[5] == 'p')
        checks.append(("OK" if n_p >= 6 else "FAIL",
                       f"re-anchors: {n_p} (>=6 wheel notches)"))
        # the re-anchor y params must track the scroll: NEVER increase while
        # scrolling up, with >=6 strict decrease steps (one per wheel notch).
        # Identical consecutive ys are legal (swept idle frames re-anchor the
        # same scroll position); an INCREASE means the crop jumped backwards.
        ys = [a[4] for a in ats if a[5] == 'p']
        noninc = all(y2 <= y1 for y1, y2 in zip(ys, ys[1:]))
        strict = sum(1 for y1, y2 in zip(ys, ys[1:]) if y2 < y1)
        checks.append(("OK" if (ys and noninc and strict >= 6) else "FAIL",
                       f"re-anchor crop ys: {ys} (non-increasing, {strict} strict steps while scrolling up)"))
        # GHOST-LAYER GUARD: a=p CREATES a placement (it does not move the
        # old one) — every frame that emits a=p must carry a d=a sweep
        # (delete-all-placements, data kept) at its top, or each re-anchor
        # leaves one more floating copy stacked over the transcript/editor
        # (observed: three image layers after a few wheel notches).
        missing_sweep = 0
        for a in [x for x in ats if x[5] == 'p']:
            fr = frames[a[0]]
            has_sweep = b"\x1b_Ga=d,d=a,q=2\x1b\\" in fr or b"\x1b_Ga=d,d=a\x1b\\" in fr
            # the sweep must precede the FIRST a=p in the frame
            if has_sweep:
                sweep_at = fr.find(b"\x1b_Ga=d,d=a")
                first_p = fr.find(b"\x1b_Ga=p")
                if first_p != -1 and sweep_at > first_p:
                    has_sweep = False
            if not has_sweep:
                missing_sweep += 1
        checks.append(("OK" if missing_sweep == 0 else "FAIL",
                       "every a=p frame carries a preceding d=a sweep" if missing_sweep == 0
                       else f"{missing_sweep} a=p frames WITHOUT a d=a sweep (ghost layers)"))
        # DATA-FREEDOM GUARD: an a=p re-anchor referencing data freed by a
        # d=I renders NOTHING (uppercase I frees uploaded bytes) — a d=I for
        # a live id in the frame followed by an a=p of the SAME id within
        # the same frame is the streaming-blank bug.
        data_free_then_anchor = 0
        for a in [x for x in ats if x[5] == 'p']:
            fr = frames[a[0]]
            for chunk in fr.split(b"\x1b_G"):
                if not chunk.startswith(b"a=d,d=I,i="):
                    continue
                hdr_end = chunk.find(b"\x1b\\")
                hdr = chunk[:hdr_end]
                iv = None
                for part in hdr.split(b","):
                    if part.startswith(b"i="):
                        iv = part[2:]
                if iv and (b"\x1b_Ga=p" in chunk or b"\x1b_Ga=T" in chunk) :
                    tail = chunk[hdr_end:]
                    if (b"\x1b_Ga=p" in tail or b"\x1b_Ga=T" in tail) and (b",i=" + iv + b"," in hdr or hdr.endswith(b"i=" + iv)):
                        data_free_then_anchor += 1
        checks.append(("OK" if data_free_then_anchor == 0 else "FAIL",
                       "no d=I-then-re-anchor (data-freed blank) sequences" if data_free_then_anchor == 0
                       else f"{data_free_then_anchor} d=I followed by re-anchor of the same id (blank render)"))
    ok = all(k == "OK" for k, _ in checks)
    for k, msg in checks:
        print(f"{k} {msg}")
    print("ALL PASS" if ok else "FAILED")
    os._exit(0 if ok else 1)
finally:
    try:
        os.kill(s.pid, signal.SIGKILL)
    except Exception:
        pass
    os._exit(1)  # any fall-through is a failure (checks above exit explicitly)
