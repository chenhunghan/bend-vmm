#!/usr/bin/env python3
"""A pack disk end to end (check-host 5u; src/disk/pack.bend): a VM started
with --pack NAME finds the device by its serial, empty; files added over the
control socket appear at 1 MiB-aligned offsets and read back byte for byte
(zeros past a file's end inside its slot, a read across two entries split
right), one is added while another is held open, a dropped entry's slot
fails to read and is never handed out again, and a snapshot restores the
table (a file changed since fails the restore).

usage: pack-test.py VMM DIR [SLOW]      (DIR: a fresh, empty directory)
"""
import hashlib, json, os, re, socket, subprocess, sys, time

vmm, d = sys.argv[1], sys.argv[2]
slow = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
sock = os.path.join(d, "vm.sock")
kernel = ["--mem", "256", "--cpus", "2", "--kernel", os.environ.get("BEND_GUEST_KERNEL", "out/guest/Image"),
          "--initrd", os.environ.get("BEND_GUEST_INITRD", "out/guest/guest.cpio")]
console = os.environ.get("BEND_GUEST_CONSOLE", "console=ttyAMA0")
MIB = 1 << 20

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
            if re.search(pat.encode(), self.out):
                return True
            if self.p.poll() is not None and not b:
                return bool(re.search(pat.encode(), self.out))
            time.sleep(0.05)
        return False
    # Runs a shell line in the guest; its output between two markers.
    def sh(self, line, secs=60):
        self.n += 1
        tag = "R%d" % self.n
        self.p.stdin.write(("echo %s-B; %s; echo %s-E\n" % (tag, line, tag)).encode())
        self.p.stdin.flush()
        if not self.wait(r"\n%s-E\r?\n" % tag, secs):
            return None
        o = self.out.decode(errors="replace").replace("\r", "")
        i = o.rindex("\n%s-B\n" % tag) + len("\n%s-B\n" % tag)
        return o[i:o.rindex("\n%s-E\n" % tag)]
    def end(self):
        self.p.stdin.write(b"poweroff -f\n"); self.p.stdin.flush()
        self.gone()
    def gone(self):
        try:
            self.p.wait(30 * slow)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
    def tail(self):
        return self.out.decode(errors="replace").replace("\r", "")[-400:]

fails = []
def check(name, ok, why=""):
    print(("ok: " if ok else "FAILED: ") + name + ("" if ok else " (" + why + ")"))
    if not ok:
        fails.append(name)

def md5(b):
    return hashlib.md5(b).hexdigest()

# a: 3 MiB + 5 bytes (its slot 4 MiB), b: 1 MiB, c: 100 bytes
files = {}
for name, size in (("a.img", 3 * MIB + 5), ("b.img", MIB), ("c.img", 100)):
    data = os.urandom(size)
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)
    files[name] = data
A, B, C = (os.path.join(d, n) for n in ("a.img", "b.img", "c.img"))

vm = Vm(kernel + ["--pack", "layers", "--control", sock, "--cmdline", console + " quiet"])
check("boot", vm.wait("busybox shell", 60), vm.tail())
dev = (vm.sh("for b in /sys/block/vd*; do [ \"$(cat $b/serial)\" = layers ] && echo /dev/${b##*/}; done") or "").strip()
check("the guest finds the pack by its serial", dev.startswith("/dev/vd"), repr(dev))
blk = "/sys/block/" + dev.split("/")[-1]
check("an empty pack has no sectors", (vm.sh("cat %s/size" % blk) or "").strip() == "0")

def size_is(sectors):
    # the guest takes the new capacity from a config change interrupt
    for _ in range(int(50 * slow)):
        if (vm.sh("cat %s/size" % blk) or "").strip() == str(sectors):
            return True
        time.sleep(0.1)
    return False

def guest_md5(off, n):
    # whole 4 KiB blocks from the device (no page cache surprises), then cut
    first, last = off // 4096, (off + n + 4095) // 4096
    r = vm.sh("echo 3 > /proc/sys/vm/drop_caches; dd if=%s bs=4096 skip=%d count=%d 2>/dev/null | tail -c +%d | head -c %d | md5sum" %
              (dev, first, last - first, off - first * 4096 + 1, n), 120)
    return (r or "").split(" ")[0]

r = ctl("pack add " + A)
check("pack add answers OFFSET LENGTH", r == "0 %d" % (3 * MIB + 5), r)
check("the capacity grows to the slot's end", size_is(4 * MIB // 512))
check("the first file reads back", guest_md5(0, 3 * MIB + 5) == md5(files["a.img"]))
check("past its end its slot reads as zeros", guest_md5(3 * MIB + 5, MIB - 5) == md5(bytes(MIB - 5)))

# hold a open while b is added (a mounted layer stays in use)
vm.sh("exec 7<%s" % dev)
r = ctl("pack add " + B)
check("a second file goes after the first's slot", r == "%d %d" % (4 * MIB, MIB), r)
check("the capacity grows again", size_is(5 * MIB // 512))
check("the second file reads back", guest_md5(4 * MIB, MIB) == md5(files["b.img"]))
check("a read across two entries", guest_md5(3 * MIB, 2 * MIB) == md5(files["a.img"][3 * MIB:] + bytes(MIB - 5) + files["b.img"][:MIB]))
check("the first still reads while the second was added", guest_md5(0, 4096) == md5(files["a.img"][:4096]))

st = ctl("status json")
try:
    pk = json.loads(st)["pack"]
    ok = pk["name"] == "layers" and pk["size"] == 5 * MIB and [(e["offset"], e["length"], e["path"], e["live"]) for e in pk["entries"]] == [(0, 3 * MIB + 5, A, True), (4 * MIB, MIB, B, True)]
except Exception as e:
    ok, st = False, "%s: %s" % (e, st)
check("status json lists the pack", ok, st)

check("pack add of a missing file is an error", ctl("pack add " + os.path.join(d, "none.img")).startswith("error: cannot open"))
check("pack add of a directory is an error", ctl("pack add " + d).startswith("error: cannot open"))
vm.sh("exec 7<&-")
r = ctl("pack drop 0")
check("pack drop answers dropped", r == "dropped", r)
check("a dropped slot fails to read", "error" in (vm.sh("echo 3 > /proc/sys/vm/drop_caches; dd if=%s bs=4096 count=1 of=/dev/null 2>&1 || echo DD-error" % dev) or "").lower())
check("the other entry still reads", guest_md5(4 * MIB, MIB) == md5(files["b.img"]))
check("a second drop is an error", ctl("pack drop 0").startswith("error: no live entry"))
check("a drop inside an entry is an error", ctl("pack drop 4096").startswith("error: no live entry"))
check("a malformed command gets the usage", ctl("pack drop x").startswith("usage: pack"))
r = ctl("pack add " + C)
check("a new file never takes a dropped slot", r == "%d 100" % (5 * MIB), r)
check("the capacity never shrinks", size_is(6 * MIB // 512))
check("the third file reads back", guest_md5(5 * MIB, 100) == md5(files["c.img"]))

# snapshot and restore: the table comes back, and reads find the files again
r = ctl("snapshot " + os.path.join(d, "s.snap"))
check("snapshot", r == "saved", r)
ctl("quit"); vm.gone()
vm = Vm(["--restore", os.path.join(d, "s.snap"), "--control", sock])
ok = vm.wait("restored", 60)
vm.p.stdin.write(b"\n"); vm.p.stdin.flush()
check("restore", ok, vm.tail())
check("after a restore the files read back", guest_md5(4 * MIB, MIB) == md5(files["b.img"]) and guest_md5(5 * MIB, 100) == md5(files["c.img"]))
check("after a restore the dropped slot still fails", "error" in (vm.sh("echo 3 > /proc/sys/vm/drop_caches; dd if=%s bs=4096 count=1 of=/dev/null 2>&1 || echo DD-error" % dev) or "").lower())
vm.end()

# a file changed since the snapshot: the restore fails and says which
time.sleep(1.1)
with open(C, "ab") as f:
    f.write(b"more")
vm = Vm(["--restore", os.path.join(d, "s.snap"), "--control", sock])
vm.wait("missing or changed|restored", 60)
if "restored" in vm.tail():
    vm.end()
vm.gone()
check("a restore over a changed file fails", vm.p.returncode != 0 and "c.img is missing or changed" in vm.tail(), vm.tail())
sys.exit(1 if fails else 0)
