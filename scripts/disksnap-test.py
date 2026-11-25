#!/usr/bin/env python3
"""Disk snapshots end to end (check-host 5f): the guest marks its disk A,
snapshot s1; B, snapshot s2; C, quits. Restoring s1, s2, then s1 again each
reads its own mark back (the copies are never written), and a snapshot taken
over s1 removes s1's old copies.

usage: disksnap-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)
"""
import re, os, socket, subprocess, sys, time, glob

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
disk, sock = os.path.join(d, "d.img"), os.path.join(d, "vm.sock")
# the guest (BEND_GUEST_KERNEL, BEND_GUEST_INITRD, BEND_GUEST_CONSOLE: arm64's by default)
kernel = ["--mem", "256", "--kernel", os.environ.get("BEND_GUEST_KERNEL", "out/guest/Image"), "--initrd", os.environ.get("BEND_GUEST_INITRD", "out/guest/guest.cpio")]

def ctl(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock)
    s.sendall((cmd + "\n").encode())
    r = s.makefile().readline().strip()
    s.close()
    return r

class Vm:
    def __init__(self, args):
        self.p = subprocess.Popen([vmm] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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
        self.p.stdin.write(s.encode()); self.p.stdin.flush()
    def mark(self, m):
        self.type("printf 'MARK-%s' | dd of=/dev/vda bs=512 seek=10 conv=notrunc oflag=direct 2>/dev/null; sync; echo WROTE-%s\n" % (m, m))
        return self.wait("WROTE-%s\r" % m) or self.wait("WROTE-%s\n" % m)
    def read(self, tag):
        self.type("echo GOT-%s-$(dd if=/dev/vda bs=512 skip=10 count=1 2>/dev/null | head -c 6)\n" % tag)
        # the whole line: on a slow host it arrives in pieces
        end = time.time() + 30 * slow
        while time.time() < end:
            m = re.search(r"^GOT-%s-([^\r\n]*)[\r\n]" % re.escape(tag), self.out.decode(errors="replace"), re.M)
            if m:
                return m.group(1).strip()
            self.wait("\x00", 0.2)
        return None
    def end(self):
        self.type("poweroff -f\n")
        self.gone()
    # Waits for the VMM to exit (after quit or poweroff), so the next one
    # finds the disk and the control socket free; a fixed pause was not
    # always enough on an emulated host (CI 45494539407: the last restore
    # read nothing).
    def gone(self):
        try:
            self.p.wait(30 * slow)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
    def tail(self):
        return self.out.decode(errors="replace").replace("\r", "")[-300:]

fails = []
def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + why + ")"))
    if not ok:
        fails.append(name)

with open(disk, "wb") as f:
    f.truncate(16 << 20)
vm = Vm(kernel + ["--disk", disk, "--control", sock, "--cmdline", os.environ.get("BEND_GUEST_CONSOLE", "console=ttyAMA0") + " quiet"])
check("boot", vm.wait("busybox shell", 60))
vm.mark("A"); r1 = ctl("snapshot " + os.path.join(d, "s1.snap"))
vm.mark("B"); r2 = ctl("snapshot " + os.path.join(d, "s2.snap"))
vm.mark("C"); ctl("quit"); vm.gone()
check("snapshots saved", r1 == "saved" and r2 == "saved", "%s %s" % (r1, r2))
s1copies = sorted(glob.glob(os.path.join(d, "s1.snap.*.disk0")))
check("each snapshot keeps a copy of the disk", len(s1copies) == 1 and len(glob.glob(os.path.join(d, "s2.snap.*.disk0"))) == 1, str(os.listdir(d)))
for snap, want in (("s1", "MARK-A"), ("s2", "MARK-B"), ("s1", "MARK-A")):
    vm = Vm(["--restore", os.path.join(d, snap + ".snap"), "--disk", disk, "--control", sock])
    ok = vm.wait("restored", 30)
    vm.type("\n")
    got = vm.read(snap)
    check("restore %s reads %s" % (snap, want), ok and got == want, "got %r, restored %s: %s" % (got, ok, vm.tail()))
    if snap == "s2":
        vm.end()
    elif snap == "s1" and want == "MARK-A" and not getattr(check, "again", False):
        check.again = True
        vm.end()
    else:
        # the last: snapshot over s1, which replaces s1's copies
        vm.mark("D")
        r = ctl("snapshot " + os.path.join(d, "s1.snap"))
        ctl("quit"); vm.gone()
        now = sorted(glob.glob(os.path.join(d, "s1.snap.*.disk0")))
        check("a snapshot over s1 replaces its copies", r == "saved" and len(now) == 1 and now != s1copies, "%s %s -> %s" % (r, s1copies, now))
vm = Vm(["--restore", os.path.join(d, "s1.snap"), "--disk", disk, "--control", sock])
ok = vm.wait("restored", 30); vm.type("\n")
got = vm.read("s1b"); vm.end()
check("restore of the new s1 reads MARK-D", ok and got == "MARK-D", "got %r, restored %s: %s" % (got, ok, vm.tail()))
check("no temporary files left", not glob.glob(os.path.join(d, "*bend-vmm-tmp")), str(os.listdir(d)))
sys.exit(1 if fails else 0)
