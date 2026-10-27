#!/usr/bin/env python3
"""Drives a console program: waits for each pattern in turn, then types its text.

usage: drive.py <timeout-s> [<pattern> <text>]... -- <cmd> [args...]

The steps run in order; each pattern is searched for in the output after
the previous step's match, so the same pattern may come twice. Text takes
\\n for Enter; it is typed DRIVE_DELAY seconds (default 0.5) after the match,
so a shell that prints and then starts reading gets it. All output goes to
stdout. Exits with the command's status, or 124 when the timeout ends it.
"""
import os, select, subprocess, sys, time

args = sys.argv[1:]
timeout = float(args[0])
sep = args.index("--")
pairs = args[1:sep]
steps = [(pairs[i].encode(), pairs[i + 1].encode().decode("unicode_escape").encode()) for i in range(0, len(pairs), 2)]
cmd = args[sep + 1:]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
fd = p.stdout.fileno()
delay = float(os.environ.get("DRIVE_DELAY", "0.5"))
t0, out, pos, due = time.monotonic(), b"", 0, None
while True:
    left = timeout - (time.monotonic() - t0)
    if left <= 0:
        p.kill()
        sys.exit(124)
    r, _, _ = select.select([fd], [], [], min(left, 0.2))
    if r:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.flush()
        out += chunk
    if steps and due is None:
        i = out.find(steps[0][0], pos)
        if i >= 0:
            pos, due = i + len(steps[0][0]), time.monotonic() + delay
    if due is not None and time.monotonic() >= due:
        try:
            p.stdin.write(steps[0][1])
            p.stdin.flush()
        except BrokenPipeError:
            pass
        steps.pop(0)
        due = None
sys.exit(p.wait())
