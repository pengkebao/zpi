#!/usr/bin/env python3
"""E2E stress: tool cards + streaming + spinner under a real pty.

Reproduces the reported "a line above the editor gets squeezed into the
content / borders desync, intermittently" by driving many turns of a
mock LLM that emits tool calls (bash tool cards) with output, then
checking after EVERY turn that the screen layout is still coherent.

The mock LLM streams N tool calls per turn so the transcript grows
through both the native-scroll path (shift detect) and the plain
repaint path, with the spinner thread redrawing every 22 ms in
parallel — the race window the user hits "sometimes".
"""
import os, pty, time, select, struct, fcntl, termios, threading, sys, json
import http.server, socketserver
import pyte

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_stress/agent"
PROJ = "/tmp/zpi_stress/proj"
PORT = 18471
TOOL_CALLS_PER_TURN = 6

os.makedirs(AGENT, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write(json.dumps({"defaultProvider": "mock", "defaultModel": "m1", "tuiMode": "regular"}))
with open(f"{AGENT}/models.json", "w") as f:
    f.write(json.dumps({"providers": {"mock": {"name": "Mock", "baseUrl": f"http://127.0.0.1:{PORT}/v1", "api": "openai-completions", "apiKey": "sk-test", "models": [{"id": "m1", "name": "Mock 1", "contextWindow": 128000, "maxTokens": 4096}]}}}))


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
        # A tool result on the wire => finish the turn with a short text.
        # (Do NOT sniff '"name":"bash"' from the raw body: the tool-schema
        # block in the system prompt matches every first request.)
        had_tool = any(m.get("role") == "tool" for m in req.get("messages", []))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def sse(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()

        if had_tool:
            sse({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "全部完成，工具都跑完了。"}}]})
            sse({"id": "c", "choices": [{"index": 0, "delta": {}}], "usage": {"prompt_tokens": 100, "completion_tokens": 10}})
            self.wfile.write(b"data: [DONE]\n\n")
            return
        # First round of the turn: stream N bash calls (CJK + emoji args).
        for i in range(TOOL_CALLS_PER_TURN):
            args = json.dumps({"command": f"echo stress-out-{i} 测试参数 🚀🚀🚀 && sleep 0.05", "timeout": 5})
            sse({"id": "c", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": i, "id": f"call_{i}", "type": "function", "function": {"name": "bash", "arguments": args}}]}}]})
        sse({"id": "c", "choices": [{"index": 0, "delta": {}}], "finish_reason": "tool_calls"})
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

    def send(self, bs, wait=0.6):
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
        fails.append(f"status row moved: {disp[ROWS-1]!r}")
    borders = [i for i, l in enumerate(disp) if l and set(l.strip()) <= {"─"} and len(l.strip()) >= COLS - 2]
    if len(borders) < 2:
        fails.append(f"borders missing/squeezed: {borders}")
    return fails


check("startup: chrome ready", "m1" in s.screen.display[ROWS - 1], repr(s.screen.display[ROWS - 1]))

for turn in range(6):
    s.send(b"run the stress batch\r", 2.5)
    for _ in range(60):
        if "Working" not in s.st():
            break
        time.sleep(0.3)
    time.sleep(0.6)
    disp = s.st()
    check(f"turn {turn}: tool cards visible", any(f"stress-out-{i}" in disp for i in range(TOOL_CALLS_PER_TURN)), disp[:400])
    check(f"turn {turn}: Took lines visible", "Took" in disp)
    fails = audit(f"turn {turn}")
    check(f"turn {turn}: screen coherent", not fails, "; ".join(fails)[:300])
    check(f"turn {turn}: back to idle prompt", "Working" not in disp)

s.quit()
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
