#!/usr/bin/env python3
"""A TCP sink for scripts/bench.sh: on 127.0.0.1:PORT, takes each connection's
bytes until N of them arrived (or EOF), then closes it.

usage: sink.py PORT N
"""
import socket, sys

port, want = int(sys.argv[1]), int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
while True:
    c, _ = s.accept()
    got = 0
    while got < want:
        b = c.recv(1 << 20)
        if not b:
            break
        got += len(b)
    c.close()
