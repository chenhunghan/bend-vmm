#!/usr/bin/env python3
"""Host faults while a guest runs.

usage: hostfault-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)

- A silent control client (it connects and sends nothing) holds the control
  socket at most its 5 s deadline: a second client's `status` is answered
  after it, and the silent one is let go.
- A stalled console (nobody reads the VMM's stdout for 20 s while the guest
  prints without pause) does not stop the VMM: the control socket answers
  during the stall, the VMM grows by less than its 16 MiB output backlog
  and a margin, and the guest answers again once stdout is read.
- Few descriptors (a hard limit of 200 leaves guest flows 100 descriptors,
  and a NAT connection takes 3): a guest opening 150 connections to the
  host gets 33, the rest are refused, the control socket still answers,
  and once the guest closes them new connections open again.
- SIGHUP presses the guest's power button: the guest powers itself off and
  the VMM exits 0. SIGINT stops the VMM at once, exit status 130.
- A VM that cannot start (a missing kernel, 99 vCPUs, and on macOS 1 TiB
  of RAM the host cannot give) exits non-zero within 10 s, saying why.

The guest is the arm64 one by default; FAULT_KERNEL, FAULT_INITRD and
FAULT_CONSOLE choose another.
"""
import os, resource, signal, socket, subprocess, sys, threading, time

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
K = os.environ.get("FAULT_KERNEL", "out/guest/Image")
I = os.environ.get("FAULT_INITRD", "out/guest/guest.cpio")
C = os.environ.get("FAULT_CONSOLE", "console=ttyAMA0") + " quiet"
fails = []


def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + str(why) + ")"), flush=True)
    if not ok:
        fails.append(name)


class Vm:
    """A VMM on a pipe; out keeps the last MiB of its output."""

    def __init__(self, args, nofile=None):
        pre = None
        if nofile:
            pre = lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (nofile, nofile))
        self.p = subprocess.Popen([vmm] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, preexec_fn=pre)
        os.set_blocking(self.p.stdout.fileno(), False)
        self.out = b""
        self.n = 0

    def pump(self):
        try:
            b = self.p.stdout.read()
        except Exception:
            b = None
        if b:
            self.out = (self.out + b)[-(1 << 20):]
        return b

    def wait(self, pat, secs=60):
        end = time.time() + secs * slow
        while time.time() < end:
            b = self.pump()
            if pat.encode() in self.out:
                return True
            if self.p.poll() is not None and not b:
                return False
            if not b:
                time.sleep(0.05)
        return False

    def send(self, line):
        self.p.stdin.write(line.encode())
        self.p.stdin.flush()

    def run(self, cmd, secs=60):
        # a marker the shell's echo of the command does not contain
        self.n += 1
        self.send("%s; echo END$((%d+1))X\n" % (cmd, self.n))
        return self.wait("END%dX" % (self.n + 1), secs)

    def rss(self):
        r = subprocess.run(["ps", "-o", "rss=", "-p", str(self.p.pid)], capture_output=True, text=True).stdout.strip()
        return int(r or 0) // 1024

    def end(self):
        try:
            self.send("poweroff -f\n")
            self.p.wait(30 * slow)
        except Exception:
            self.p.kill()
            self.p.wait()


def ctl(sock, cmd, secs):
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(secs)
    c.connect(sock)
    c.sendall((cmd + "\n").encode())
    try:
        return c.makefile().readline().strip()
    except OSError as e:
        return "error: %s" % e
    finally:
        c.close()


def boot(tag, extra=(), nofile=None):
    sock = os.path.join(d, tag + ".sock")
    vm = Vm(["--mem", "1024", "--cpus", "2", "--kernel", K, "--initrd", I, "--control", sock,
             "--cmdline", C] + list(extra), nofile)
    up = vm.wait("busybox shell", 90)
    check("%s: boot" % tag, up, vm.out[-400:])
    return vm, sock, up


# 1. A silent control client.
vm, sock, up = boot("silent")
if up:
    quiet = socket.socket(socket.AF_UNIX)
    quiet.connect(sock)
    t0 = time.time()
    r = ctl(sock, "status", 30 * slow)
    took = time.time() - t0
    check("a silent control client holds the socket at most its deadline (status after %.1f s)" % took,
          r == "running" and took < 5 + 5 * slow, (r, took))
    quiet.settimeout(10 * slow)
    try:
        gone = quiet.recv(1) == b""
    except OSError as e:
        gone = "reset" in str(e).lower()
    quiet.close()
    check("the silent client is let go", gone)
vm.end()

# 2. A stalled console.
vm, sock, up = boot("console")
if up:
    vm.run("yes 0123456789abcdefghijklmnopqrstuvwxyz > /dev/console & echo $! > /tmp/yes.pid")
    before = vm.rss()
    # stop reading stdout for 20 s; ask the control socket meanwhile
    answers = []
    for _ in range(4):
        time.sleep(5 * slow)
        t0 = time.time()
        answers.append((ctl(sock, "status", 20 * slow), round(time.time() - t0, 1)))
    peak = vm.rss()
    check("the control socket answers while nobody reads the console (%s)" % answers,
          all(a == "running" for a, _ in answers), answers)
    check("the VMM stays bounded with the console stalled (%d -> %d MiB)" % (before, peak),
          peak - before < 16 + 48, (before, peak))
    ok = vm.run("kill $(cat /tmp/yes.pid)", 120)
    check("the guest answers once the console is read again", ok and vm.run("echo alive", 60))
vm.end()

# 3. Few descriptors.
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(512)
port = srv.getsockname()[1]
held = []
opened = [0]
stop = False


def accept():
    # holds every connection until the guest closes its side, then closes it
    import selectors
    sel = selectors.DefaultSelector()
    srv.setblocking(False)
    sel.register(srv, selectors.EVENT_READ)
    while not stop:
        for key, _ in sel.select(0.2):
            if key.fileobj is srv:
                try:
                    c, _ = srv.accept()
                except OSError:
                    continue
                c.setblocking(False)
                held.append(c)
                opened[0] += 1
                sel.register(c, selectors.EVENT_READ)
            else:
                c = key.fileobj
                try:
                    b = c.recv(4096)
                except OSError:
                    b = b""
                if not b:
                    sel.unregister(c)
                    held.remove(c)
                    c.close()


th = threading.Thread(target=accept, daemon=True)
th.start()
vm, sock, up = boot("fds", nofile=200)
if up:
    vm.run("for i in $(seq 150); do sleep 600 | nc 10.0.2.2 %d >/dev/null 2>&1 & done; sleep %d" % (port, int(4 * slow)), 120)
    time.sleep(2 * slow)
    first = opened[0]
    vm.run("echo NC-$(pidof nc | wc -w)")
    check("the guest's connections stop at the descriptor budget (%d of 150 opened; 100 descriptors, 3 a connection)" % first,
          25 <= first <= 33, (first, vm.out[-200:]))
    r = ctl(sock, "status", 20 * slow)
    check("the control socket answers at the descriptor budget", r == "running", r)
    vm.run("killall nc sleep 2>/dev/null; sleep %d" % int(3 * slow), 60)
    vm.run("for i in $(seq 5); do sleep 600 | nc 10.0.2.2 %d >/dev/null 2>&1 & done; sleep %d" % (port, int(3 * slow)), 60)
    time.sleep(1 * slow)
    check("connections open again once the guest closed them (%d new, %d held)" % (opened[0] - first, len(held)),
          opened[0] - first >= 5, (opened[0] - first, len(held)))
    vm.run("killall nc sleep 2>/dev/null")
vm.end()
stop = True
th.join()
for c in held:
    c.close()
srv.close()

# 4. A VM that cannot start.
for what, args, says in (("a missing kernel", ["--mem", "256", "--kernel", os.path.join(d, "none")], "cannot load the kernel"),
                         ("99 vCPUs", ["--mem", "256", "--cpus", "99", "--kernel", K], "--cpus takes 1 to 64")) + (
        # (macOS only: Linux may overcommit 1 TiB and boot it)
        (("1 TiB of RAM", ["--mem", "1048576", "--kernel", K, "--initrd", I, "--cmdline", C], "cannot create the VM"),)
        if sys.platform == "darwin" else ()):
    t0 = time.time()
    try:
        r = subprocess.run([vmm] + args, stdin=subprocess.DEVNULL, capture_output=True, timeout=10 * slow)
        code, said = r.returncode, (r.stdout + r.stderr).decode(errors="replace")
    except subprocess.TimeoutExpired:
        code, said = None, "still running after %d s" % (10 * slow)
    check("%s: the VMM exits %s in %.1f s, saying why" % (what, code, time.time() - t0),
          code not in (None, 0) and says in said, (code, said[-200:]))

# 5. SIGHUP presses the power button; SIGINT stops the VMM at once.
for name, sig, want in (("SIGHUP", signal.SIGHUP, 0), ("SIGINT", signal.SIGINT, 130)):
    vm, sock, up = boot(name.lower())
    if up:
        vm.p.send_signal(sig)
        pressed = vm.wait("GUEST: power button", 30) if want == 0 else True
        try:
            code = vm.p.wait(30 * slow)
        except subprocess.TimeoutExpired:
            vm.p.kill()
            code = vm.p.wait()
        what = "powers the guest off (its power button" if want == 0 else "stops the VMM at once (no power button"
        check("%s %s; exit %s)" % (name, what, code), pressed and code == want, (pressed, code, vm.out[-300:]))
    else:
        vm.p.kill()
        vm.p.wait()

print("HOSTFAULT %s" % ("OK" if not fails else "FAILED: " + ", ".join(fails)), flush=True)
sys.exit(1 if fails else 0)
