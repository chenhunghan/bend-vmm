#!/usr/bin/env python3
"""Host ends for check-host's NAT fault tests (section 5d), on 127.0.0.1.

usage: netfault.py slow PORT N OUT    one connection read slowly (16 KiB
                                      every 10 ms) until N bytes; writes
                                      the count to OUT, then closes
       netfault.py drop PORT AFTER OUT  the first connection is reset (RST)
                                      after AFTER bytes; the second is read
                                      for 1 MiB; writes "dropped COUNT" to
                                      OUT
"""
import socket, struct, sys, time

def listen(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # a small receive buffer: the host side fills, and the NAT must hold
    # the guest back
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
    s.bind(("127.0.0.1", port))
    s.listen(2)
    return s

def main(argv):
    mode, port, n, out = argv[0], int(argv[1]), int(argv[2]), argv[3]
    s = listen(port)
    s.settimeout(120)
    if mode == "slow":
        c, _ = s.accept()
        open(out + ".start", "w").close()  # (check-host takes the VMM's memory now)
        got = 0
        while got < n:
            b = c.recv(16384)
            if not b:
                break
            got += len(b)
            time.sleep(0.01)
        open(out, "w").write(str(got))
        c.close()
    elif mode == "drop":
        c, _ = s.accept()
        got = 0
        while got < n:
            b = c.recv(65536)
            if not b:
                break
            got += len(b)
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        c.close()
        c, _ = s.accept()
        total = 0
        while total < 1048576:
            b = c.recv(1 << 20)
            if not b:
                break
            total += len(b)
        open(out, "w").write(f"dropped {total}")
        c.close()

if __name__ == "__main__":
    main(sys.argv[1:])
