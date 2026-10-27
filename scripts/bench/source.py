#!/usr/bin/env python3
"""A TCP source for scripts/bench.sh: on 127.0.0.1:PORT, sends each
connection N bytes, then closes it.

usage: source.py PORT N
"""
import socket, sys

port, n = int(sys.argv[1]), int(sys.argv[2])
chunk = bytes(1 << 20)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
while True:
    c, _ = s.accept()
    left = n
    while left > 0:
        k = c.send(chunk[: min(left, len(chunk))])
        left -= k
    c.close()
