#!/usr/bin/env python3
"""E2E: transport failure mid-conversation does NOT kill the turn.

The mock LLM's server REFUSES connections for the first request burst
(simulating a gateway blip / process restart), then starts serving. pi's
retryAssistantCall semantics expect the agent to survive: the provider
layer retries 3x (1s/2s/4s), then the NEW agent-layer budget retries 3x
(2s/4s/8s) — ~35s of combined tolerance — and the turn completes with a
real answer instead of dying with 'transport error: HttpError'.
"""
import os, pty, time, select, struct, fcntl, termios, threading, sys, json
import http.server, socketserver, signal

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_retry/agent"
PROJ = "/tmp/zpi_retry/proj"
PORT = 18480
os.makedirs(AGENT, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write(json.dumps({"defaultProvider": "mock", "defaultModel": "m1", "tuiMode": "regular"}))
with open(f"{AGENT}/models.json", "w") as f:
    f.write(json.dumps({"providers": {"mock": {"name": "Mock", "baseUrl": f"http://127.0.0.1:{PORT}/v1", "api": "openai-completions", "apiKey": "sk-test", "models": [{"id": "m1", "name": "Mock 1", "contextWindow": 128000, "maxTokens": 4096}]}}}))

DOWN_UNTIL = time.time() + 12  # refuse connections for the first 12s


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
            sse({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "任务完成。"}}]})
        else:
            sse({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "恢复成功，服务已恢复。"}}]})
        sse({"id": "c", "choices": [{"index": 0, "delta": {}}], "usage": {"prompt_tokens": 100, "completion_tokens": 10}})
        self.wfile.write(b"data: [DONE]\n\n")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# Server bound but refusing: close() the listening socket? Simplest reliable
# "connection refused" is to NOT bind until DOWN_UNTIL passes. zpi's retries
# (3 x 1s/2s/4s + agent 3 x 2s/4s/8s) cover ~35s, so a 12s outage must heal.
srv_holder = {}


def start_server_later():
    while time.time() < DOWN_UNTIL:
        time.sleep(0.2)
    srv_holder["srv"] = Server(("127.0.0.1", PORT), MockLLM)
    srv_holder["srv"].serve_forever()


threading.Thread(target=start_server_later, daemon=True).start()


class Session:
    def __init__(self):
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
            os.dup2(slave, 0); os.dup2(slave, 1)
            os.dup2(os.open("/dev/null", os.O_WRONLY), 2)
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
    time.sleep(1.0)
    s.send("你好\r")
    # Generous budget: outage 12s + zpi retries (~35s tolerance) + settle.
    deadline = time.time() + 90
    recovered = False
    transport_died = False
    retry_notice = False
    while time.time() < deadline:
        text = bytes(s.log).decode("utf-8", "replace")
        if "retrying" in text:
            retry_notice = True
        if "恢复成功" in text:
            recovered = True
            break
        if "Error: transport error" in text:
            transport_died = True
            break
        time.sleep(0.2)
    text = bytes(s.log).decode("utf-8", "replace")

    checks = []
    checks.append(("OK" if recovered else "FAIL",
                   "turn recovered after the outage (final answer rendered)" if recovered else "turn NEVER recovered"))
    checks.append(("OK" if not transport_died else "FAIL",
                   "no 'Error: transport error' termination" if not transport_died else "turn DIED with transport error"))
    checks.append(("OK" if retry_notice else "INFO",
                   "retry notice rendered in the transcript" if retry_notice else "no retry notice (provider+agent backoff may have absorbed it silently)"))

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
    if "srv" in srv_holder:
        srv_holder["srv"].shutdown()
    os._exit(1)
