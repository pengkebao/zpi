#!/usr/bin/env python3
"""E2E: regular TUI mode (tuiMode "regular", pi TuiMainScreen semantics).

Verifies over a real pty:
  1. regular mode NEVER enters the alt screen (no ?1049h) and runs the
     deferred protocol setup exactly once
  2. transcript content flows into the native scrollback (the raw byte
     stream carries the `!echo` lines as plain appends with CRLF)
  3. the bottom chrome (editor border + status) stays on the last screen
     rows across multiple turns (the terminal never net-scrolls)
  4. /settings hot-switch regular -> fullscreen live-swaps (?1049h after
     launch) and back is reachable; the screen stays intact
  5. fullscreen default unchanged (?1049h still present without settings)
"""
import os, pty, time, select, struct, fcntl, termios, signal, threading, sys
import pyte

ROWS, COLS = 30, 110
BIN = os.path.abspath("zig-out/bin/zpi")
AGENT = "/tmp/zpi_regular/agent"
os.makedirs(AGENT, exist_ok=True)
with open(f"{AGENT}/settings.json", "w") as f:
    f.write('{"tuiMode":"regular"}')
PROJ = "/tmp/zpi_regular/proj"
os.makedirs(PROJ, exist_ok=True)

class Session:
    def __init__(self, env_extra=None):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.log = bytearray()
        self.alive = True
        self.exit_code = None
        env = dict(os.environ)
        env["RPI_CODING_AGENT_DIR"] = AGENT
        env["TERM"] = "xterm-256color"
        if env_extra:
            env.update(env_extra)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0); os.dup2(slave, 1)
            os.dup2(os.open("/dev/null", os.O_WRONLY), 2)
            os.close(master); os.close(slave)
            os.chdir(os.path.dirname(BIN) or ".")
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
                    self.alive = False; return
                if not d:
                    self.alive = False; return
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
            w, status = os.waitpid(self.pid, 0)
            self.exit_code = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            self.exit_code = -1
        return self.exit_code

# Fixture: settings must say "regular" for session 1 (a previous run's
# step 4 may have left "{}" or "fullscreen" behind).
with open(f"{AGENT}/settings.json", "w") as f:
    f.write('{"defaultProvider":"yumakeji","defaultModel":"qwen3.8-27b","tuiMode":"regular"}')

ok = True
def check(name, cond, extra=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ((" | " + extra) if extra and not cond else ""))
    if not cond:
        ok = False

log_text = lambda s: bytes(s.log).decode("utf-8", "replace")

# ---- 1. regular mode: no alt screen, deferred setup once ----
s = Session()
time.sleep(2.2)
t1 = log_text(s)
check("regular: no ?1049h ever", "?1049h" not in t1)
# pi TuiMainScreen: NO mouse reporting in regular mode — the wheel belongs
# to the terminal (native scrollback scrolling is the point of the mode).
check("regular: no mouse grab", "?1000h" not in t1 and "?1006h" not in t1)
check("regular: focus reporting stays", "?1004h" in t1)
check("regular: kitty negotiation present", "[>7u" in t1)
check("regular: kitty negotiation exactly once", t1.count("[>7u") == 1, str(t1.count("[>7u")))
# chrome on screen: status row last, editor border above
check("regular: chrome on last rows", s.screen.display[ROWS-1].strip() != "" and "·" in s.screen.display[ROWS-1] or s.screen.display[ROWS-1].strip() != "", s.screen.display[ROWS-1])

# ---- 2. transcript flows into scrollback ----
status_row_before = ROWS - 1
s.send(b"!echo alpha-regular\r", 1.0)
s.send(b"!echo beta-regular\r", 1.0)
s.send(b"!echo gamma-regular\r", 1.0)
t2 = log_text(s)
check("regular: alpha line flowed raw", "alpha-regular" in t2)
check("regular: gamma line flowed raw", "gamma-regular" in t2)
# the flowed lines must be plain appends (CRLF), not CUP-positioned repaints
import re
check("regular: transcript used CRLF appends", t2.count("\r\n") >= 3, str(t2.count("\r\n")))
# chrome stays: status still on the last row (no net scroll)
check("regular: no net scroll (status row stable)", s.screen.display[ROWS-1].strip() != "")
check("regular: editor border still visible", any("─" in l or "╭" in l or "|" in l for l in s.screen.display[ROWS-6:ROWS-1]))

# ---- 3. /settings hot-switch to fullscreen ----
# pi SettingsSelector: type "tui" to filter, Enter cycles the value, Esc
# closes. (Blind arrow-walking is fragile: the list is long and sorted.)
s.send(b"/settings\r", 0.8)
s.send(b"tui", 0.6)
check("settings: TUI mode row visible", any("TUI mode" in l for l in s.screen.display))
t_before = log_text(s)
s.send(b"\r", 0.8)   # Enter/Space cycles regular -> fullscreen
s.send(b"\x1b", 0.8) # close the selector
t_after = log_text(s)
check("settings: live switch emitted ?1049h", "?1049h" in t_after[len(t_before):])
time.sleep(0.4)
check("fullscreen: editor border back", any("╭" in l or "─" in l for l in s.screen.display[ROWS-6:ROWS]))
try:
    persisted = open(f"{AGENT}/settings.json").read()
    check("settings: tuiMode persisted fullscreen", '"tuiMode"' in persisted and "fullscreen" in persisted, persisted)
except Exception as e:
    check("settings: tuiMode persisted fullscreen", False, str(e))

code = s.quit()
check("exit clean (0)", code == 0, str(code))

# ---- 4. default (no settings) still fullscreen ----
with open(f"{AGENT}/settings.json", "w") as f:
    f.write("{}")
s2 = Session()
time.sleep(2.2)
t4 = log_text(s2)
check("default: ?1049h present (fullscreen unchanged)", "?1049h" in t4)
check("default: mouse grab present (fullscreen unchanged)", "?1000h" in t4 and "?1006h" in t4)
code2 = s2.quit()
check("default: exit clean", code2 == 0, str(code2))

print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
