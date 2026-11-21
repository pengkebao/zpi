#!/usr/bin/env python3
"""E2E: the read tool rendering a real tall PNG over a pty (mock LLM).

Drives zpi through a real tool round (mock OpenAI-compatible server makes
the model call `read` on a 606x1074 PNG) and verifies, over a real 30-row
pty in ghostty-detected Kitty mode:
  1. the encoded Kitty header carries the pi height cap: r=30 (NOT 53
     like the old unbounded encoding), c~34
  2. only ONE distinct placement id (no leaks across re-encodes)
  3. no uncapped (>30-row) placement ever goes out
"""
import os, pty, time, select, struct, fcntl, termios, threading, re, sys, json
import http.server, socketserver, signal

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_img2/agent"
PROJ = "/tmp/zpi_img2/proj"
IMG = "/tmp/zpi-clipboard-1795218375790.png"
PORT = 18477
os.makedirs(AGENT, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write(json.dumps({"defaultProvider": "mock", "defaultModel": "m1", "tuiMode": "regular", "showImages": True, "imageWidthCells": 60}))
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
        self.alive = True
        env = dict(os.environ)
        env["RPI_CODING_AGENT_DIR"] = AGENT
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "ghostty"  # image_caps = kitty
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0); os.dup2(slave, 1)
            stderr_log = os.open("/tmp/zpi_stderr.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
            os.dup2(stderr_log, 2)
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
try:
    time.sleep(2.0)
    s.send(f"/read {IMG}\r")
    # Wait for the tool round to finish (final text arrives).
    deadline = time.time() + 30
    while time.time() < deadline:
        if b"\x1b_Ga=T" in bytes(s.log) and (b"finishReason" in bytes(s.log) or b"tool_use_id" in bytes(s.log) or b"call_0" in bytes(s.log)):
            pass
        text_now = bytes(s.log).decode("utf-8", "replace")
        if "图片读取完成" in text_now:
            break
        time.sleep(0.2)
    time.sleep(1.5)  # let the final frames settle
    text = bytes(s.log).decode("utf-8", "replace")
    open("/tmp/zpi_img_log.bin", "wb").write(bytes(s.log))

    checks = []
    # 1. Kitty image headers
    headers = [(m.group(1), m.group(2), m.group(3)) for m in re.finditer(r"\x1b_Ga=T[^;]*?c=(\d+),i=(\d+)[^;]*?r=(\d+);", text)]
    if not headers:
        checks.append(("FAIL", f"no kitty image sequence in output ({len(text)} bytes)"))
    else:
        c, i, r = map(int, headers[0])
        checks.append(("OK" if (r <= 30 and 30 <= c <= 36) else "FAIL",
                       f"kitty header c={c} r={r} (expect height-capped r<=30, c~34; old code: c=60 r=53)"))
        ids = {int(x[1]) for x in headers}
        checks.append(("OK" if len(ids) == 1 else "FAIL", f"distinct placement ids: {sorted(ids)}"))
    big = [h for h in headers if int(h[2]) > 30]
    checks.append(("OK" if not big else "FAIL", f"uncapped placements (>30 rows): {[h[2] for h in big]}"))

    ok = all(k == "OK" for k, _ in checks)
    for k, msg in checks:
        print(f"{k} {msg}")
    print("ALL PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)
finally:
    srv.shutdown()
    try:
        os.kill(s.pid, signal.SIGKILL)
    except Exception:
        pass
