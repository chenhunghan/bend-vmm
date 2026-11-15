#!/usr/bin/env python3
"""virtio-balloon free page reporting end to end (check-host 5h).

usage: balloon-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)

A 2 GiB, 2-vCPU guest with --balloon free-page-reporting fills 1 GiB of its
tmpfs and frees it: the VMM's resident memory must at least halve, by at
least 300 MiB, within 10 s (RAM mapped from a snapshot counts less). Then it writes 512 MiB again into the freed memory and copies
it out through virtio-blk: the host's disk image must hold exactly what the
guest wrote (the VMM sees the guest's data in released pages). The same once
more after a snapshot and a restore (RAM mapped from the snapshot file).
"""
import hashlib, os, re, socket, subprocess, sys, time

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
disk, sock, snap = os.path.join(d, "d.img"), os.path.join(d, "vm.sock"), os.path.join(d, "vm.snap")
fails = []

def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + str(why) + ")"))
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
        # a marker the shell's echo of the command does not contain
        self.n += 1
        self.p.stdin.write(("%s; echo END$((%d+1))X\n" % (cmd, self.n)).encode()); self.p.stdin.flush()
        return self.wait("END%dX" % (self.n + 1), secs)
    def rss(self):
        r = subprocess.run(["ps", "-o", "rss=", "-p", str(self.p.pid)], capture_output=True, text=True).stdout.strip()
        return int(r or 0) // 1024
    def end(self):
        try:
            self.p.stdin.write(b"poweroff -f\n"); self.p.stdin.flush()
            self.p.wait(30 * slow)
        except Exception:
            self.p.kill()

def round_(vm, tag):
    vm.run("dd if=/dev/urandom of=/tmp/big bs=1048576 count=1024 2>/dev/null")
    full = vm.rss()
    vm.run("rm /tmp/big")
    low = full
    for _ in range(int(20 * slow)):
        time.sleep(0.5)
        low = min(low, vm.rss())
        if full - low >= 300 and low * 2 <= full:
            break
    check("%s: freeing 1 GiB in the guest gives it back (%d -> %d MiB)" % (tag, full, low), full - low >= 300 and low * 2 <= full, "%d -> %d" % (full, low))
    vm.run("dd if=/dev/urandom of=/tmp/b2 bs=1048576 count=512 2>/dev/null; echo GMD5-%s-$(head -c 62914560 /tmp/b2 | md5sum | cut -c1-32); "
           "dd if=/tmp/b2 of=/dev/vda bs=1048576 count=60 oflag=direct 2>/dev/null; sync" % tag)
    g = re.search(r"GMD5-%s-([0-9a-f]{32})" % tag, vm.out.decode(errors="replace"))
    host = hashlib.md5(open(disk, "rb").read(60 << 20)).hexdigest()
    check("%s: the host sees what the guest wrote into released memory" % tag, g is not None and g.group(1) == host, (g and g.group(1), host))

open(disk, "wb").truncate(64 << 20)
vm = Vm(["--mem", "2048", "--cpus", "2", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio", "--disk", disk,
         "--control", sock, "--balloon", "free-page-reporting", "--cmdline", "console=ttyAMA0 quiet"])
check("boot", vm.wait("busybox shell", 60))
vm.run("echo BAL-$(ls /sys/bus/virtio/drivers/virtio_balloon/ | grep -c virtio)")
check("the guest binds the balloon", b"BAL-1" in vm.out)
round_(vm, "boot")
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.sendall(("snapshot %s\n" % snap).encode())
r = s.makefile().readline().strip(); s.close()
check("snapshot with the balloon", r == "saved", r)
vm.p.kill(); vm.p.wait()
vm = Vm(["--restore", snap, "--disk", disk])
check("restore with the balloon", vm.wait("restored", 60))
vm.run("true")
round_(vm, "restored")
vm.end()
sys.exit(1 if fails else 0)
