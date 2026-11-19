#!/usr/bin/env python3
"""E2E: zpi exit must not leak the late DSR reply (ESC[<r>;<c>R) to the shell.

Reproduces the real race on a manual pty:
  - answers every ESC[6n while the app runs, 30 ms later like a terminal
  - sends ctrl+d, STOPS answering; the final frame's DSR goes unanswered
  - the moment the exit sequence (?1049l) hits the output stream, injects
    the late reply — the process is still alive, mid-teardown
  - after the child dies, reads the SLAVE side: any bytes there are what
    zsh's raw ZLE reads would pick up and echo at the prompt (the bug)

The child must NOT become a session leader: a session leader's death
hangs up the tty line discipline, which flushes the input queue and
masks exactly the leak this test exists to catch. Without a controlling
tty the queue survives, like it does behind a live zsh.

Usage: e2e_exit_race.py [path-to-zpi]
"""
import os, pty, select, sys, time, fcntl, termios, struct, signal

ZPI = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zpi")

master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))
# Noncanonical from the start: the app saves this as its "old" termios and
# restores it on exit, so the queue stays raw-readable after child death
# (macOS refuses tcgetattr on the slave once the session leader is gone).
attrs = termios.tcgetattr(slave_fd)
attrs[3] &= ~termios.ICANON  # lflag
attrs[6][termios.VMIN] = 0
attrs[6][termios.VTIME] = 0
termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)

pid = os.fork()
if pid == 0:
    # No setsid / TIOCSCTTY: keep the input queue alive past child death
    # (a session leader's exit flushes it via the hangup path).
    os.dup2(slave_fd, 0)
    os.dup2(slave_fd, 1)
    os.dup2(slave_fd, 2)
    if slave_fd > 2:
        os.close(slave_fd)
    os.close(master_fd)
    os.environ["TERM"] = "xterm-256color"
    os.execv(ZPI, [ZPI])
    os._exit(127)

def read_fd(f, timeout):
    r, _, _ = select.select([f], [], [], timeout)
    if not r:
        return b""
    try:
        return os.read(f, 65536)
    except OSError:
        return b""

buf = b""
quit_sent = False
quit_at = time.time() + 1.2
injected = False
t_inject = None
deadline = time.time() + 15
child_dead = False
exit_code = None

while time.time() < deadline:
    now = time.time()
    if not quit_sent and now >= quit_at:
        os.write(master_fd, b"\x04")  # ctrl+d: exit (editor empty)
        quit_sent = True
    chunk = read_fd(master_fd, 0.02)
    if chunk:
        buf += chunk
        # Teardown marker: fullscreen exits the alt screen (?1049l); regular
        # mode has no alt screen — its teardown starts with the mouse-off
        # burst (?1000l). Either marks "process alive, mid-teardown":
        # inject the late DSR reply now.
        teardown = b"\x1b[?1049l" in chunk or b"\x1b[?1000l" in chunk
        if quit_sent and teardown and not injected:
            # Process is alive and mid-teardown: the terminal's answer to
            # the last frame's DSR lands right now.
            injected = True
            t_inject = time.time()
            os.write(master_fd, b"\x1b[45;1R")
        elif not quit_sent:
            for _ in range(chunk.count(b"\x1b[6n")):
                pass  # answered only while running; after ctrl+d: silent
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            child_dead = True
            exit_code = os.waitstatus_to_exitcode(status)
            break
    except ChildProcessError:
        child_dead = True
        break

t_death = time.time()
if not child_dead:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    exit_code = "SIGKILL (never exited)"

# What zsh would read from the tty input queue after the app is gone.
# The tty is noncanonical (preset before fork, restored by the app), so a
# partial line IS selectable — exactly like zsh's raw ZLE reads.
time.sleep(0.2)
leftover = b""
t0 = time.time()
while time.time() - t0 < 0.4:
    c = read_fd(slave_fd, 0.05)
    if c:
        leftover += c

print("child_dead:", child_dead, "exit_code:", exit_code)
print("late_reply_injected:", injected)
if injected and child_dead:
    print("inject_to_death_ms: %.1f" % ((t_death - t_inject) * 1000))
print("leftover_for_shell:", repr(leftover))
ok = child_dead and injected and exit_code == 0 and len(leftover) == 0
print("PASS" if ok else "FAIL")
os.close(master_fd)
os.close(slave_fd)
sys.exit(0 if ok else 1)
