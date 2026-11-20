#!/usr/bin/env python3
"""hibernate PATH end to end (the control socket).

usage: hibernate-test.py VMM DIR [SLOW]     (DIR: a fresh, empty directory;
                                            short: it holds a control socket)

A 1 GiB guest with a writable disk writes 300 MiB into tmpfs. hibernate
pauses it and moves its RAM into a file that guest RAM then maps: the VMM's
memory (macOS: its physical footprint; Linux: its resident set) falls below
a quarter and under 100 MiB, the VM stays paused, and the file is gone at
once (nor are disks copied: the directory holds what it held). resume
continues it with every byte (a checksum made in the guest). 20 MiB more,
then hibernate again: only what changed is written (under 2 s), and the
memory falls again. After that a snapshot still saves and restores, and
the VM powers off with no file left behind.
"""
import os, re, socket, subprocess, sys, time

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
mac = sys.platform == "darwin"
K = os.environ.get("BEND_GUEST_KERNEL", "out/guest/Image")
I = os.environ.get("BEND_GUEST_INITRD", "out/guest/guest.cpio")
C = os.environ.get("BEND_GUEST_CONSOLE", "console=ttyAMA0") + " quiet"
sock, disk = os.path.join(d, "c.sock"), os.path.join(d, "d.img")
hib, snap = os.path.join(d, "h.ram"), os.path.join(d, "s.snap")
fails = []


def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + str(why) + ")"), flush=True)
    if not ok:
        fails.append(name)


class Vm:
    def __init__(self, args):
        self.p = subprocess.Popen([vmm] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        os.set_blocking(self.p.stdout.fileno(), False)
        self.out = b""
        self.n = 0

    def wait(self, pat, secs=60):
        end = time.time() + secs * slow
        while time.time() < end:
            try:
                b = self.p.stdout.read()
            except Exception:
                b = None
            if b:
                self.out = (self.out + b)[-(1 << 20):]
            if pat.encode() in self.out:
                return True
            if self.p.poll() is not None and not b:
                return False
            if not b:
                time.sleep(0.05)
        return False

    def run(self, cmd, secs=120):
        self.n += 1
        self.p.stdin.write(("%s; echo END$((%d+1))X\n" % (cmd, self.n)).encode())
        self.p.stdin.flush()
        return self.wait("END%dX" % (self.n + 1), secs)


def ctl(line, secs=120):
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(secs * slow)
    c.connect(sock)
    c.sendall((line + "\n").encode())
    try:
        return c.makefile().readline().strip()
    finally:
        c.close()


def mem(pid):
    if mac:
        o = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True).stdout
        m = re.search(r"Physical footprint:\s+([\d.]+)([KMG])", o)
        return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)] if m else -1
    m = re.search(r"^VmRSS:\s+(\d+) kB", open("/proc/%d/status" % pid).read(), re.M)
    return int(m.group(1)) / 1024 if m else -1


def sums(v, tag):
    v.run("echo %s-$(cat /t/*.bin | md5sum | cut -c1-32)" % tag)
    m = re.search(r"%s-([0-9a-f]{32})" % tag, v.out.decode(errors="replace"))
    return m and m.group(1)


open(disk, "wb").truncate(64 << 20)
v = Vm(["--mem", "1024", "--cpus", "2", "--kernel", K, "--initrd", I, "--disk", disk, "--control", sock, "--cmdline", C])
check("boot", v.wait("busybox shell", 90 if slow < 4 else 60))
v.run("mkdir -p /t; mount -t tmpfs none /t; dd if=/dev/urandom of=/t/a.bin bs=1048576 count=300 2>/dev/null")
want = sums(v, "S1")
before = mem(v.p.pid)
files = sorted(os.listdir(d))

t0 = time.time()
r = ctl("hibernate " + hib)
took = time.time() - t0
time.sleep(1)
after = mem(v.p.pid)
check("hibernate answers (%s, %.2f s)" % (r, took), r == "hibernated", r)
check("the VM stays paused", ctl("status") == "paused")
check("the hibernate file is removed at once, and no disk is copied", sorted(os.listdir(d)) == files, sorted(os.listdir(d)))
check("the VMM's memory goes (%.0f -> %.0f MiB)" % (before, after), 0 < after < before / 4 and after < 100, (before, after))

check("resume", ctl("resume") == "running")
check("the guest's RAM is intact after resume", sums(v, "S2") == want and want is not None)
v.run("dd if=/dev/urandom of=/t/b.bin bs=1048576 count=20 2>/dev/null")
want2 = sums(v, "S3")
mid = mem(v.p.pid)
t0 = time.time()
r = ctl("hibernate " + hib)
took = time.time() - t0
time.sleep(1)
low = mem(v.p.pid)
check("hibernate again writes only what changed (%.2f s)" % took, r == "hibernated" and took < 2 * slow, (r, took))
check("the VMM's memory goes again (%.0f -> %.0f MiB)" % (mid, low), 0 < low < 100, (mid, low))
check("resume again, every byte there", ctl("resume") == "running" and sums(v, "S4") == want2 and want2 is not None)

r = ctl("snapshot " + snap)
check("a snapshot after hibernating saves (%s)" % r, r == "saved", r)
v.run("rm /t/b.bin; sync")
v.p.stdin.write(b"poweroff -f\n")
v.p.stdin.flush()
try:
    v.p.wait(30 * slow)
except subprocess.TimeoutExpired:
    v.p.kill()
    v.p.wait()
left = sorted(f for f in os.listdir(d) if f not in ("c.sock", "d.img", "s.snap") and not f.startswith("s.snap."))
check("the VM exits with no hibernate file left", left == [] and not os.path.exists(hib), left)

v = Vm(["--restore", snap, "--disk", disk, "--control", sock])
check("the snapshot restores", v.wait("restored", 60))
v.run("true")
check("the restored guest has both files", sums(v, "S5") == want2 and want2 is not None)
v.p.stdin.write(b"poweroff -f\n")
v.p.stdin.flush()
try:
    v.p.wait(30 * slow)
except subprocess.TimeoutExpired:
    v.p.kill()

print("HIBERNATE %s" % ("OK" if not fails else "FAILED: " + ", ".join(fails)), flush=True)
sys.exit(1 if fails else 0)
