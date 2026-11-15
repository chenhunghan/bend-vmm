#!/usr/bin/env python3
"""virtio-balloon free page reporting end to end (check-host 5h).

usage: balloon-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)

A 2 GiB, 2-vCPU guest with --balloon free-page-reporting fills 1 GiB of its
tmpfs and frees it: the VMM's resident memory must at least halve, by at
least 300 MiB, within 10 s (RAM mapped from a snapshot counts less). Then it writes 512 MiB again into the freed memory and copies
it out through virtio-blk: the host's disk image must hold exactly what the
guest wrote (the VMM sees the guest's data in released pages). The same once
more after a snapshot and a restore (RAM mapped from the snapshot file).
Then inflate and deflate from the control socket: 1 GiB of page cache,
`balloon 1024` (status json reports it in the balloon; the VMM shrinks),
`balloon 0` (the guest can use that memory again). Then the automatic
balloon (the default, src/virtio/balauto.bend): an idle guest's free memory
goes into it, a 1.2 GiB burst still fits with nothing killed, it fills again
after; `balloon 100` stops it, `balloon auto` starts it again. Last, a
fragmented guest (bench frag: every other 4 KiB page free): `balloon 200`
fills within 10 s even so, status json's kept_mib says most of it could not
be released (16 KiB blocks only part in the balloon).
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
        # (Linux: /proc; a minimal ps may not take -o)
        try:
            m = re.search(r"^VmRSS:\s+(\d+) kB", open("/proc/%d/status" % self.p.pid).read(), re.M)
            if m:
                return int(m.group(1)) // 1024
        except OSError:
            pass
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

def ctl(cmd):
    c = socket.socket(socket.AF_UNIX); c.connect(sock); c.sendall((cmd + "\n").encode())
    r = c.makefile().readline().strip(); c.close(); return r

# inflate and deflate: 1 GiB of page cache (a disk read the guest keeps),
# then `balloon 1024`: the guest gives 1 GiB to the balloon (dropping that
# cache) and the host lets it go; `balloon 0` gives it back
open(disk, "wb").truncate(1100 << 20)
with open(disk, "r+b") as f:
    f.write(os.urandom(1024 << 20))
vm = Vm(["--mem", "2048", "--cpus", "2", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio", "--disk", disk,
         "--control", sock, "--balloon", "free-page-reporting", "--cmdline", "console=ttyAMA0 quiet"])
check("boot again", vm.wait("busybox shell", 60))
vm.run("dd if=/dev/vda of=/dev/null bs=1048576 count=1024 2>/dev/null")
full = vm.rss()
r = ctl("balloon 1024")
check("balloon 1024 answers", r.startswith("balloon 1024 MiB"), r)
st = ""
for _ in range(int(60 * slow)):
    time.sleep(0.5)
    st = ctl("status json")
    if '"actual_mib":1024' in st:
        break
check("the guest puts 1024 MiB in the balloon (status json)", '"actual_mib":1024' in st and '"target_mib":1024' in st, st)
low = vm.rss()
check("inflating gives the host its memory (%d -> %d MiB)" % (full, low), full - low >= 500, "%d -> %d" % (full, low))
ctl("balloon 0")
for _ in range(int(60 * slow)):
    time.sleep(0.5)
    st = ctl("status json")
    if '"actual_mib":0' in st:
        break
check("balloon 0: the guest takes it all back", '"actual_mib":0' in st, st)
# (the guest's tmpfs holds under half its RAM) 900 MiB in tmpfs, and 700 MiB
# more in a process, need the memory the balloon gave back
vm.run("dd if=/dev/urandom of=/tmp/b3 bs=1048576 count=900 2>/dev/null; echo FILL-$(wc -c < /tmp/b3); "
       "head -c 734003200 /dev/zero | tail -c 1 >/dev/null && echo ANON-OK")
o = vm.out.decode(errors="replace")
check("after deflating, the guest uses its memory again (900 MiB in tmpfs, 700 MiB in a process)", "FILL-943718400" in o and "ANON-OK" in o, o[-300:])
vm.end()

# the balloon is the default; --balloon off leaves it out, and a snapshot
# taken without it restores without it
vm = Vm(["--mem", "512", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio", "--cmdline", "console=ttyAMA0 quiet"])
vm.wait("busybox shell", 60); vm.run("echo DEF-$(ls /sys/bus/virtio/drivers/virtio_balloon/ | grep -c virtio)"); vm.end()
check("the balloon is on by default", b"DEF-1" in vm.out)
vm = Vm(["--mem", "512", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio", "--control", sock, "--balloon", "off", "--cmdline", "console=ttyAMA0 quiet"])
vm.wait("busybox shell", 60); vm.run("echo OFF-$(ls /sys/bus/virtio/drivers/virtio_balloon/ | grep -c virtio)")
check("--balloon off leaves it out", b"OFF-0" in vm.out)
r = ctl("balloon 100")
check("balloon MiB without one says so", r.startswith("error: no balloon"), r)
r = ctl("snapshot " + snap)
vm.p.kill(); vm.p.wait()
vm = Vm(["--restore", snap])
ok = vm.wait("restored", 60); vm.run("echo RE-$(ls /sys/bus/virtio/drivers/virtio_balloon/ | grep -c virtio)"); vm.end()
check("a snapshot without the balloon restores without it", r == "saved" and ok and b"RE-0" in vm.out, (r, ok))
# the automatic balloon (the default)
def target_mib():
    m = re.search(r'"target_mib":(\d+)', ctl("status json"))
    return int(m.group(1)) if m else -1

def wait_target(pred, secs):
    t = -1
    for _ in range(int(secs * 2 * slow)):
        time.sleep(0.5)
        t = target_mib()
        if pred(t):
            break
    return t

vm = Vm(["--mem", "2048", "--cpus", "2", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio",
         "--control", sock, "--cmdline", "console=ttyAMA0 quiet"])
check("boot with the automatic balloon", vm.wait("busybox shell", 60))
# (its first poll comes 30 s after the start: Auto.start_ms)
t = wait_target(lambda t: t >= 512, 60)
check("auto: an idle guest's free memory goes into the balloon (target %d MiB)" % t, t >= 512, t)
vm.run("mkdir -p /t; mount -t tmpfs -o size=1900m none /t; dd if=/dev/zero of=/t/x bs=1048576 count=1200 2>/dev/null; echo BURST-$(wc -c < /t/x)", 300)
o = vm.out.decode(errors="replace")
check("auto: a 1.2 GiB burst fits, nothing killed", "BURST-1258291200" in o and "Killed" not in o and "Out of memory" not in o, o[-300:])
vm.run("rm /t/x")
t = wait_target(lambda t: t >= 512, 30)
check("auto: after it, the balloon fills again (target %d MiB)" % t, t >= 512, t)
ctl("balloon 100")
time.sleep(6 * slow)
t = target_mib()
check("balloon 100 stops it (target %d MiB)" % t, t == 100, t)
r = ctl("balloon auto")
t = wait_target(lambda t: t >= 512, 30)
check("balloon auto starts it again (target %d MiB)" % t, r == "balloon auto" and t >= 512, (r, t))
vm.end()

def kept_mib():
    m = re.search(r'"kept_mib":(\d+)', ctl("status json"))
    return int(m.group(1)) if m else -1

vm = Vm(["--mem", "1024", "--cpus", "2", "--kernel", "out/guest/Image", "--initrd", "out/guest/guest.cpio",
         "--control", sock, "--cmdline", "console=ttyAMA0 quiet"])
check("boot a guest to fragment", vm.wait("busybox shell", 60))
vm.p.stdin.write(b"bench frag 600 20 &\n"); vm.p.stdin.flush()
check("bench frag", vm.wait("FRAG-READY", 60))
ctl("balloon 200")
st = ""
for _ in range(int(20 * slow)):
    time.sleep(0.5)
    st = ctl("status json")
    if '"actual_mib":200' in st:
        break
check("a fragmented guest fills the balloon within 10 s", '"actual_mib":200' in st, st)
k = kept_mib()
check("kept_mib: the balloon's pages the host could not release (%d MiB)" % k, k >= 100, st)
vm.end()
sys.exit(1 if fails else 0)
