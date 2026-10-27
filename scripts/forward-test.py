#!/usr/bin/env python3
"""The host half of check-host's port forwarding check (--forward).

usage: forward-test.py <timeout-s> <port> <bulk-port> <bytes>

1. Connects to 127.0.0.1:<port> until a guest server answers a line
   (`echo forward-ok | nc -l -p 8080` in the guest), and prints it as
   `HOST-FWD-LINE <line>`.
2. Connects to 127.0.0.1:<bulk-port> until the guest server greets with a
   line (`echo go | nc -l -p 8081 | wc -c`), sends <bytes> bytes, half-closes
   and reads to the end; prints `HOST-FWD-SENT <bytes>`.

Until the guest listens, a connection is accepted on the host and then reset
(the guest's RST) or closed: each attempt is retried until the timeout.
"""
import socket, sys, time

timeout, port, bulk_port, size = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
t0 = time.monotonic()


def left():
    return timeout - (time.monotonic() - t0)


def line(port):
    """A connection whose peer sent a full line, and the line (else None)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=max(left(), 1))
    got = b""
    while not got.endswith(b"\n"):
        b = s.recv(4096)
        if not b:
            s.close()
            return None, None
        got += b
    return s, got.decode(errors="replace").strip()


def retry(port):
    while left() > 0:
        try:
            s, got = line(port)
            if s:
                return s, got
        except OSError:
            pass
        time.sleep(0.5)
    print("HOST-FWD-TIMEOUT %d" % port, flush=True)
    sys.exit(1)


s, got = retry(port)
s.close()
print("HOST-FWD-LINE " + got, flush=True)
s, got = retry(bulk_port)
chunk = bytes(range(256)) * 4096
try:
    sent = 0
    while sent < size:
        sent += s.send(chunk[: min(len(chunk), size - sent)])
    s.shutdown(socket.SHUT_WR)
    while s.recv(65536):
        pass
    s.close()
except OSError as e:
    print("HOST-FWD-FAILED after %d bytes: %s" % (sent, e), flush=True)
    sys.exit(1)
print("HOST-FWD-SENT %d" % size, flush=True)
