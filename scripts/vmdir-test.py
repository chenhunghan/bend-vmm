#!/usr/bin/env python3
"""VM folders and named snapshots end to end (check-host 5g): bend-vmm
create, run, status, snapshot (named, and by the time), snapshots, restore
(which saves the current state first and stops the running VM), a snapshot
of a stopped VM (its disks), snapshot-rm, prune and ctl.

usage: vmdir-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)
"""
import os, subprocess, sys, time

vmm, base = os.path.abspath(sys.argv[1]), sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
root = os.getcwd()
vm = os.path.join(base, "web")
fails = []

def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + str(why) + ")"))
    if not ok:
        fails.append(name)

def cmd(*args):
    r = subprocess.run([vmm] + list(args), capture_output=True, text=True, timeout=600 * slow)
    return r.returncode, (r.stdout + r.stderr).strip()

class Run:
    def __init__(self, *args):
        self.p = subprocess.Popen([vmm] + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        os.set_blocking(self.p.stdout.fileno(), False)
        self.out = b""
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
                return pat.encode() in self.out
            time.sleep(0.05)
        return False
    def type(self, s):
        try:
            self.p.stdin.write(s.encode()); self.p.stdin.flush()
        except BrokenPipeError:
            pass
    def mark(self, m):
        self.type("printf 'MARK-%s' | dd of=/dev/vda bs=512 seek=10 conv=notrunc oflag=direct 2>/dev/null; sync; echo WROTE-%s\n" % (m, m))
        return self.wait("WROTE-%s\r" % m) or self.wait("WROTE-%s\n" % m)
    def read(self, tag):
        self.type("echo GOT-%s-$(dd if=/dev/vda bs=512 skip=10 count=1 2>/dev/null | head -c 6)\n" % tag)
        self.wait("GOT-%s-MARK" % tag, 30)
        for line in self.out.decode(errors="replace").splitlines():
            if line.startswith("GOT-%s-" % tag):
                return line.strip()[len("GOT-%s-" % tag):]
        return None
    def end(self):
        self.type("poweroff -f\n")
        try:
            self.p.wait(30 * slow)
        except subprocess.TimeoutExpired:
            self.p.kill()

rc, out = cmd("create", vm, "--kernel", os.path.join(root, "out/guest/Image"), "--initrd", os.path.join(root, "out/guest/guest.cpio"),
              "--mem", "256", "--disk", "disk.img", "--cmdline", "console=ttyAMA0 quiet")
check("create writes vm.conf", rc == 0 and os.path.exists(os.path.join(vm, "vm.conf")), out)
with open(os.path.join(vm, "disk.img"), "wb") as f:
    f.truncate(16 << 20)
rc, out = cmd("create", vm, "--mem", "256")
check("create refuses a folder that has a VM", rc != 0 and "has a vm.conf" in out, out)
rc, out = cmd("status", "--vm", vm)
check("status of a VM never run: stopped", rc == 0 and out.startswith("stopped"), out)

r = Run("run", vm)
check("run boots the folder's VM", r.wait("busybox shell", 60))
rc, out = cmd("status", "--vm", vm)
check("status: running", rc == 0 and out.startswith("running"), out)
r.mark("A")
rc, out = cmd("snapshot", "s1", "--note", "first one", "--vm", vm)
check("snapshot s1", rc == 0 and out.startswith("saved s1") and "first one" in out, out)
rc, out = cmd("snapshot", "s1", "--vm", vm)
check("a name in use is refused", rc != 0 and "exists already" in out, out)
rc, out = cmd("snapshot", "../x", "--vm", vm)
check("a bad name is refused", rc != 0 and "bad snapshot name" in out, out)
r.mark("B")
rc, out = cmd("snapshot", "--vm", vm)
check("snapshot with the time's name, from s1", rc == 0 and out.startswith("saved 20") and "from s1" in out, out)
rc, out = cmd("snapshots", "--vm", vm)
lines = out.splitlines()
check("snapshots lists both, oldest first", rc == 0 and len(lines) == 2 and lines[0].startswith("s1 "), out)

# restore s1 while running: the current state is saved, the VM stops, s1 runs
r2 = Run("restore", "s1", "--vm", vm)
ok = r2.wait("restored", 60)
try:
    r.p.wait(30 * slow)
    stopped = True
except subprocess.TimeoutExpired:
    stopped = False
check("restore stops the running VM", stopped)
check("restore saves the current state first", b"saved before-restore-" in r2.out, r2.out[-300:])
r2.type("\n")
got = r2.read("s1")
check("restore s1: the disk reads s1's mark", ok and got == "MARK-A", got)
r2.end()

rc, out = cmd("status", "--vm", vm)
check("status after the VM ends: stopped", rc == 0 and out.startswith("stopped"), out)
rc, out = cmd("snapshot", "cold", "--vm", vm)
check("a snapshot of a stopped VM keeps its disks", rc == 0 and "memory -" in out, out)
r3 = Run("restore", "cold", "--vm", vm)
ok = r3.wait("busybox shell", 60)
got = r3.read("cold") if r3.p.poll() is None else None
if not ok or got is None:
    print("restore cold said:", r3.out.decode(errors="replace")[-600:])
check("restore of a disks-only snapshot boots on its disks", ok and got == "MARK-A", got)
r3.end()

rc, out = cmd("snapshots", "--vm", vm)
n_before = len(out.splitlines())
rc, out = cmd("snapshot-rm", "cold", "--vm", vm)
check("snapshot-rm", rc == 0 and out == "removed cold" and not os.path.exists(os.path.join(vm, "snapshots", "cold")), out)
rc, out = cmd("prune", "--keep", "1", "--vm", vm)
rc2, left = cmd("snapshots", "--vm", vm)
check("prune --keep 1 leaves the newest", rc == 0 and len(left.splitlines()) == 1 and out.count("removed ") == n_before - 2, out + " / " + left)
rc, out = cmd("ctl", os.path.join(vm, "control.sock"), "status")
check("ctl on a stopped VM says so", rc != 0 and "not running" in out, out)
check("no temporary folders left", not [x for x in os.listdir(os.path.join(vm, "snapshots")) if x.endswith(".tmp")], os.listdir(os.path.join(vm, "snapshots")))
sys.exit(1 if fails else 0)
