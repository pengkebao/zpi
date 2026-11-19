#!/usr/bin/env python3
"""Repro attempt: compact-queue + steering while streaming, regular mode.

The user's report: "sometimes a line above the editor gets squeezed down
INTO the content, and after a re-refresh it disappears again". The known
family of bugs here was the pending-queue row budget (fixed in 4d9b63d).
This hammers the exact scenario with the CURRENT build to see if any
desync remains: messages queued mid-stream (Enter = steer) while the
mock LLM streams tool cards, repeatedly.
"""
import os, pty, time, select, struct, fcntl, termios, threading, sys, json
import http.server, socketserver
import pyte

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_stress/agent"
PROJ = "/tmp/zpi_stress/proj"
PORT = 18473

os.makedirs(AGENT, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write(json.dumps({"defaultProvider": "mock", "defaultModel": "m1", "tuiMode": "regular"}))
with open(f"{AGENT}/models.json", "w") as f:
    f.write(json.dumps({"providers": {"mock": {"name": "Mock", "baseUrl": f"http://127.0.0.1:{PORT}/v1", "api": "openai-completions", "apiKey": "sk-test", "models": [{"id": "m1", "name": "Mock 1", "contextWindow": 128000, "maxTokens": 4096}]}}}))

STEER_TEXT = "这是一条比较长的 steering 消息，包含中文与 emoji 🚀🚀，用来测试队列行折行的正确性"


def sse(wfile, obj):
    wfile.write(b"data: " + json.dumps(obj).encode("utf-8") + b"\n\n")


class MockLLM(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        txt = body.decode("utf-8", "replace")
        try:
            req = json.loads(body)
        except Exception:
            req = {}
        had_tool = any(m.get("role") == "tool" for m in req.get("messages", []))
        steered = STEER_TEXT[:12] in txt  # steering text rides the wire as user content
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def done():
            sse(self.wfile, {"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "完成。"}}]})
            sse(self.wfile, {"id": "c", "choices": [{"index": 0, "delta": {}}], "usage": {"prompt_tokens": 100, "completion_tokens": 10}})
            self.wfile.write(b"data: [DONE]\n\n")

        if had_tool:
            done()
            return
        for i in range(5):
            args = json.dumps({"command": f"echo queue-out-{i} 中文输出 && sleep 0.15", "timeout": 5})
            sse(self.wfile, {"id": "c", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": i, "id": f"call_{i}", "type": "function", "function": {"name": "bash", "arguments": args}}]}}]})
        sse(self.wfile, {"id": "c", "choices": [{"index": 0, "delta": {}}], "finish_reason": "tool_calls"})
        self.wfile.write(b"data: [DONE]\n\n")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", PORT), MockLLM)
threading.Thread(target=srv.serve_forever, daemon=True).start()


class Session:
    def __init__(self):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.log = bytearray()
        self.alive = True
        env = dict(os.environ)
        env["RPI_CODING_AGENT_DIR"] = AGENT
        env["TERM"] = "xterm-256color"
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0)
            os.dup2(slave, 1)
            os.dup2(os.open("/dev/null", os.O_WRONLY), 2)
            os.close(master)
            os.close(slave)
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
                    d = os.read(self.master, 65536)
                except OSError:
                    self.alive = False
                    return
                if not d:
                    self.alive = False
                    return
                self.log.extend(d)
                self.stream.feed(d)

    def send(self, bs, wait=0.3):
        try:
            os.write(self.master, bs)
        except OSError:
            pass
        time.sleep(wait)

    def st(self):
        return "\n".join(self.screen.display)

    def quit(self):
        self.send(b"\x04", 1.0)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


s = Session()
time.sleep(2.0)
ok = True


def check(name, cond, extra=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ((" | " + extra) if extra and not cond else ""))
    if not cond:
        ok = False


def audit(tag):
    disp = s.screen.display
    fails = []
    if "m1" not in disp[ROWS - 1]:
        fails.append(f"status moved: {disp[ROWS-1]!r}")
    borders = [i for i, l in enumerate(disp) if l and set(l.strip()) <= {"─"} and len(l.strip()) >= COLS - 2]
    if len(borders) < 2:
        fails.append(f"borders: {borders}")
    return fails


for turn in range(5):
    s.send(b"queue stress batch\r", 0.8)
    # queue two steering messages mid-stream (Enter while Working)
    s.send(STEER_TEXT.encode() + b"\r", 0.4)
    s.send(STEER_TEXT.encode() + b"\r", 0.4)
    for _ in range(80):
        if "Working" not in s.st():
            break
        time.sleep(0.25)
    time.sleep(0.6)
    disp = s.st()
    fails = audit(f"turn {turn}")
    check(f"turn {turn}: coherent", not fails, "; ".join(fails)[:200])
    # the queue ROWS ("Steering: " peek label) must be gone once drained
    check(f"turn {turn}: queue drained", "Steering: " not in disp, disp[-400:])

s.quit()
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
