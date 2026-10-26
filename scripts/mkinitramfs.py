#!/usr/bin/env python3
"""Packs a directory into a newc cpio initramfs, adding /dev/console.

usage: mkinitramfs.py <dir> <out.cpio> [<host-file>:<guest-path> ...]
Directories become 0755, files keep their executable bit.
"""
import os, sys

ino = [1]
def entry(name, mode, data=b"", rdev=(0, 0)):
    ino[0] += 1
    hdr = "070701" + "".join("%08X" % v for v in [
        ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(name) + 1, 0])
    out = hdr.encode() + name.encode() + b"\0"
    out += b"\0" * (-len(out) % 4)
    return out + data + b"\0" * (-len(data) % 4)

root, out = sys.argv[1], sys.argv[2]
files = {}
for d, _, names in os.walk(root):
    for n in names:
        p = os.path.join(d, n)
        files[os.path.relpath(p, root)] = p
for extra in sys.argv[3:]:
    host, guest = extra.split(":", 1)
    files[guest.lstrip("/")] = host
dirs = {"dev", "proc", "sys", "tmp", "bin", "mnt"}
for g in files:
    parts = g.split("/")[:-1]
    for i in range(1, len(parts) + 1):
        dirs.add("/".join(parts[:i]))
blob = b"".join(entry(d, 0o040755) for d in sorted(dirs))
blob += entry("dev/console", 0o020600, rdev=(5, 1))
for g in sorted(files):
    data = open(files[g], "rb").read()
    mode = 0o100755 if os.access(files[g], os.X_OK) or g == "init" else 0o100644
    blob += entry(g, mode, data)
blob += entry("TRAILER!!!", 0)
blob += b"\0" * (-len(blob) % 512)
open(out, "wb").write(blob)
