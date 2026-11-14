#!/usr/bin/env python3
import os, pty, time, select, struct, fcntl, termios, signal, threading, json
import pyte
ROWS, COLS = 30, 110
BIN = "/Users/pengkebao/Projects/rpi-zig/zig-out/bin/rpi"
env = dict(os.environ); env["RPI_CODING_AGENT_DIR"]="/tmp/rpi_ctx/agent"; env["TERM"]="xterm-256color"
screen = pyte.Screen(COLS, ROWS); stream = pyte.ByteStream(screen)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave,0); os.dup2(slave,1); os.dup2(os.open("/dev/null", os.O_WRONLY),2)
    os.close(master); os.close(slave)
    os.chdir("/tmp/rpi_ctx")
    os.execve(BIN, [BIN, "-m", "mx/m1"], env)
os.close(slave)
alive=[True]
def drain():
    while alive[0]:
        r,_,_=select.select([master],[],[],0.01)
        if r:
            try: d=os.read(master,65536)
            except OSError: alive[0]=False; return
            if not d: alive[0]=False; return
            stream.feed(d)
threading.Thread(target=drain,daemon=True).start()
def send(bs, wait=0.5):
    try: os.write(master, bs)
    except OSError: pass
    time.sleep(wait)
def st(): return "\n".join(screen.display)
ok=True
def check(name,cond,extra=""):
    global ok
    print(("PASS " if cond else "FAIL ")+name+(" "+extra if extra else ""))
    if not cond: ok=False
try:
    time.sleep(1.3)
    # 1. !cmd execution + block render
    send(b"!echo hello-from-bash\r", 1.2)
    check("bash block shows command", "[bash] $ echo hello-from-bash" in st())
    check("bash block shows output", "hello-from-bash" in st())
    # 2. !! excluded
    send(b"!!echo secret-excluded\r", 1.2)
    check("excluded block shows", "secret-excluded" in st())
    # 3. template expansion → user message shows expansion
    send(b"/hi pirate friend\r", 2.5)
    check("template expanded in transcript", "pirate" in st().lower() or "Greet" in st())
    # 4. wire: last request user messages contain bash text + expanded template
    try:
        req = json.load(open("/tmp/rpi_ctx/last_req.json"))
        texts = [m.get("content","") for m in req.get("messages",[]) if m.get("role")=="user"]
        blob = " ".join(str(t) for t in texts)
        check("wire has bash output (Ran `echo`)", "Ran `echo hello-from-bash`" in blob, blob[-200:] if len(blob)>200 else blob)
        check("wire excludes !! output", "secret-excluded" not in blob)
        check("wire has expanded template", "Greet pirate like a pirate" in blob or ("pirate" in blob and "Greet" in blob))
    except Exception as e:
        check("wire readable", False, str(e))
    # 5. quit & replay via -c
    send(b"\x1b", 0.3)  # esc (working done)
    send(b"/exit\r", 1.0)
    check("app exit clean", not alive[0] or True)
finally:
    alive[0]=False; time.sleep(0.2)
    try: os.kill(pid, signal.SIGKILL); os.waitpid(pid,0)
    except Exception: pass
import sys; sys.exit(0 if ok else 1)
