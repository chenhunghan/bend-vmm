#!/usr/bin/env python3
"""Incremental snapshots end to end (check-host 5i).

usage: snapshot-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory;
                                            short: it holds a control socket)

A VM folder's 1 GiB guest writes 300 MiB into tmpfs, snapshot s1; then 20
MiB more, snapshot s2. Restoring s2 gives back both files, s1 only the first
(checksums made in the guest). After s1 guest RAM maps it (Snapf.rebase):
on macOS the VMM's physical footprint drops below a quarter, and s2, a
clone of s1 with only what changed written (APFS shares the rest), holds
under 100 MiB of its own (`bend-vmm snapshots`). A snapshot of a restored
VM works the same way.
"""
import os, re, subprocess, sys, time

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
mac = sys.platform == "darwin"
V = os.path.join(d, "vm")
here = os.path.dirname(os.path.abspath(vmm))
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
                self.out += b
            if pat.encode() in self.out:
                return True
            if self.p.poll() is not None and not b:
                return False
            time.sleep(0.05)
        return False
    def run(self, cmd, secs=120):
        self.n += 1
        self.p.stdin.write(("%s; echo END$((%d+1))X\n" % (cmd, self.n)).encode()); self.p.stdin.flush()
        return self.wait("END%dX" % (self.n + 1), secs)
    def end(self):
        try:
            self.p.stdin.write(b"poweroff -f\n"); self.p.stdin.flush()
            self.p.wait(30 * slow)
        except Exception:
            self.p.kill()

def cli(*a):
    r = subprocess.run([vmm] + list(a), capture_output=True, text=True, timeout=120 * slow)
    return (r.stdout + r.stderr).strip()

def phys(pid):
    o = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Physical footprint:\s+([\d.]+)([KMG])", o)
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)] if m else -1

def mem_mib(listing, name):
    m = re.search(r"^" + name + r"\s.*memory (\d+) (KiB|MiB)", listing, re.M)
    return -1 if not m else int(m.group(1)) / (1024 if m.group(2) == "KiB" else 1)

# the guest (BEND_GUEST_KERNEL, BEND_GUEST_INITRD, BEND_GUEST_CONSOLE: arm64's by default)
guest = [os.environ.get("BEND_GUEST_KERNEL", os.path.join(here, "guest", "Image")), os.environ.get("BEND_GUEST_INITRD", os.path.join(here, "guest", "guest.cpio"))]
cli("create", V, "--mem", "1024", "--kernel", guest[0], "--initrd", guest[1], "--cmdline", os.environ.get("BEND_GUEST_CONSOLE", "console=ttyAMA0") + " quiet")
v = Vm(["run", V])
check("boot", v.wait("~ #", 60))
time.sleep(2)
v.run("mkdir -p /t; mount -t tmpfs none /t; dd if=/dev/urandom of=/t/a bs=1048576 count=300 2>/dev/null; md5sum /t/a > /t/a.md5")
before = phys(v.p.pid) if mac else 0
o1 = cli("snapshot", "s1", "--vm", V)
check("snapshot s1", o1.startswith("saved s1"), o1)
time.sleep(1)
if mac:
    after = phys(v.p.pid)
    check("after a snapshot, RAM is the file's (footprint %.0f -> %.0f MiB)" % (before, after), 0 < after < before / 4, (before, after))
v.run("dd if=/dev/urandom of=/t/b bs=1048576 count=20 2>/dev/null; md5sum /t/b > /t/b.md5")
o2 = cli("snapshot", "s2", "--vm", V)
check("snapshot s2", o2.startswith("saved s2"), o2)
ls = cli("snapshots", "--vm", V)
if mac:
    s2 = mem_mib(ls, "s2")
    check("s2 holds only what changed (%.0f MiB of its own)" % s2, 0 < s2 < 100, ls)
v.run("rm /t/b /t/b.md5; dd if=/dev/urandom of=/t/c bs=1048576 count=10 2>/dev/null")
v.end()
for name, want in (("s2", ["/t/a: OK", "/t/b: OK"]), ("s1", ["/t/a: OK"])):
    r = Vm(["restore", name, "--vm", V])
    time.sleep(3 * slow)
    r.run("cd /t; md5sum -c a.md5; [ -f b.md5 ] && md5sum -c b.md5; echo FILES-$(ls /t | tr '\\n' -)X")
    out = r.out.decode(errors="replace")
    files = re.findall(r"^FILES-(.*)X", out, re.M)
    has = files[-1].split("-") if files else []
    check("restore %s: its files and checksums" % name, all(w in out for w in want) and "FAILED" not in out
          and ("b" in has) == (name == "s2") and "a" in has and "c" not in has, out[-400:])
    o3 = cli("snapshot", "r" + name, "--vm", V)
    check("snapshot of the VM restored from %s" % name, o3.startswith("saved r" + name), o3)
    if mac:
        k = mem_mib(cli("snapshots", "--vm", V), "r" + name)
        check("it holds only what changed since the restore (%.0f MiB of its own)" % k, 0 <= k < 100, k)
    r.end()
sys.exit(1 if fails else 0)
