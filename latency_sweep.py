#!/usr/bin/env python3
"""Latency sweep: does zpi's exit leak the DSR reply for ANY reply latency?

For each delay D, the harness answers the final frame's ESC[6n with
delay D (absolutely scheduled — the injection happens even if the child
has already exited, like a real terminal whose answer races the exit),
then reports what survives on the tty for the shell. Also measures the
exit overhead (quit keystroke -> child death) so the fix's cost is
visible.
Usage: latency_sweep.py <zpi-path> <delay-ms> [...]
"""
import os, pty, select, sys, time, fcntl, termios, struct, signal

ZPI = os.path.abspath(sys.argv[1])
DELAYS = [int(x) for x in sys.argv[2:]] or [10, 30, 80, 200, 400, 700]

def run_once(delay_ms):
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))
    attrs = termios.tcgetattr(slave_fd)
    attrs[3] &= ~termios.ICANON
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)

    pid = os.fork()
    if pid == 0:
        os.dup2(slave_fd, 0); os.dup2(slave_fd, 1); os.dup2(slave_fd, 2)
        if slave_fd > 2: os.close(slave_fd)
        os.close(master_fd)
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZPI, [ZPI]); os._exit(127)

    def rd(f, t):
        r, _, _ = select.select([f], [], [], t)
        return os.read(f, 65536) if r else b""

    buf = b""
    quit_at = time.time() + 1.0
    quit_sent = False
    t_quit = None
    injections = []   # absolute (due_at, bytes) — fire even AFTER child death
    dead = False
    deadline = time.time() + 12
    while time.time() < deadline:
        now = time.time()
        for i, (due, b) in enumerate(injections):
            if now >= due:
                os.write(master_fd, b)
                injections.pop(i)
                break
        if not quit_sent and now >= quit_at:
            os.write(master_fd, b"\x04")
            quit_sent = True
            t_quit = now
        c = rd(master_fd, 0.005)
        if c:
            buf += c
            if b"\x1b[6n" in c:
                # the terminal answers EVERY query at exactly delay_ms
                injections.append((now + delay_ms / 1000.0, b"\x1b[43;1R"))
        try:
            w, _ = os.waitpid(pid, os.WNOHANG)
            if w == pid:
                dead = True
                break
        except ChildProcessError:
            dead = True
            break
    if not dead:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        os.close(master_fd); os.close(slave_fd)
        return "NO-EXIT"
    t_death = time.time()
    # keep firing scheduled replies past death (the race we model), then
    # give late arrivals time to land before sampling the queue
    t0 = time.time()
    while injections and time.time() - t0 < 2.0:
        now = time.time()
        for i, (due, b) in enumerate(injections):
            if now >= due:
                os.write(master_fd, b)
                injections.pop(i)
                break
        rd(master_fd, 0.01)
    time.sleep(0.15)
    left = b""
    t0 = time.time()
    while time.time() - t0 < 0.3:
        c = rd(slave_fd, 0.05)
        if c: left += c
    os.close(master_fd); os.close(slave_fd)
    overhead = (t_death - t_quit) * 1000
    verdict = ("LEAK " + repr(left)) if left else "clean"
    return "%s  (exit overhead %.0f ms)" % (verdict, overhead)

for d in DELAYS:
    print("%4dms -> %s" % (d, run_once(d)))
