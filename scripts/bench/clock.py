#!/usr/bin/env python3
"""Runs a command and times its output.

usage: clock.py <timeout-s> <pattern>[|<pattern>...] <cmd> [args...]

Prints `AT <pattern> <seconds>` when a pattern first appears in the output,
passes through every line starting with BENCH, and ends with
`TOTAL <seconds>` (or `TIMEOUT`). Patterns are plain substrings.
"""
import os, subprocess, sys, time, select

timeout, pats, cmd = float(sys.argv[1]), sys.argv[2].split("|"), sys.argv[3:]
t0 = time.monotonic()
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
seen, buf = set(), b""
fd = p.stdout.fileno()
while True:
    left = timeout - (time.monotonic() - t0)
    if left <= 0:
        p.kill(); print("TIMEOUT", flush=True); sys.exit(1)
    r, _, _ = select.select([fd], [], [], min(left, 0.5))
    if not r:
        continue
    chunk = os.read(fd, 65536)
    now = time.monotonic() - t0
    if not chunk:
        break
    buf += chunk
    for pat in pats:
        if pat not in seen and pat.encode() in buf:
            seen.add(pat); print("AT %s %.3f" % (pat, now), flush=True)
    *lines, buf = buf.split(b"\n")
    for line in lines:
        line = line.replace(b"\r", b"")
        if line.startswith(b"BENCH"):
            print(line.decode(errors="replace"), flush=True)
    keep = max(len(p) for p in pats)
    buf = buf[-max(keep, 4096):]
p.wait()
print("TOTAL %.3f" % (time.monotonic() - t0), flush=True)
