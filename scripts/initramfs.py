#!/usr/bin/env python3
"""Writes a newc cpio initramfs holding /dev/console and the given /init.

usage: initramfs.py <init-binary> <out.cpio>
"""
import sys

def entry(name, mode, data=b"", rdev=(0, 0), ino=[1]):
    ino[0] += 1
    hdr = "070701" + "".join("%08X" % v for v in [
        ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(name) + 1, 0])
    out = hdr.encode() + name.encode() + b"\0"
    out += b"\0" * (-len(out) % 4)
    out += data + b"\0" * (-len(data) % 4)
    return out

init = open(sys.argv[1], "rb").read()
cpio = (entry("dev", 0o040755) + entry("dev/console", 0o020600, rdev=(5, 1))
        + entry("init", 0o100755, init) + entry("TRAILER!!!", 0))
cpio += b"\0" * (-len(cpio) % 512)
open(sys.argv[2], "wb").write(cpio)
