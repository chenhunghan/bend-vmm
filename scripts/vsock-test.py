#!/usr/bin/env python3
"""Drives the guest vsock tests from the host side (scripts/check-mac.sh).

Serves <base>_1234 (the guest's client connects there and gets PONG-HOST),
runs the VM, and once the guest prints VSOCK-SERVER-READY connects through
<base> with "CONNECT 5000" to the guest's server. Prints the VM's output and
HOST-VSOCK-OK or HOST-VSOCK-FAIL.

usage: vsock-test.py <base> <bend-vmm args...>
"""
import os, socket, subprocess, sys, threading, time

base, args = sys.argv[1], sys.argv[2:]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
if os.path.exists(base + "_1234"):
    os.unlink(base + "_1234")
srv.bind(base + "_1234")
srv.listen(4)

def serve():
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        c.recv(64)
        c.sendall(b"PONG-HOST\n")
        c.close()

threading.Thread(target=serve, daemon=True).start()
vm = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
result = "HOST-VSOCK-FAIL"
deadline = time.time() + 60
for raw in vm.stdout:
    line = raw.decode(errors="replace")
    sys.stdout.write(line)
    if "VSOCK-SERVER-READY" in line:
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.settimeout(10)
            c.connect(base)
            c.sendall(b"CONNECT 5000\n")
            ok = c.recv(64)
            c.sendall(b"hello\n")
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = c.recv(64)
                if not chunk:
                    break
                reply += chunk
            if ok.startswith(b"OK ") and reply == b"PONG hello\n":
                result = "HOST-VSOCK-OK"
            else:
                result = "HOST-VSOCK-FAIL got %r %r" % (ok, reply)
            c.close()
        except Exception as e:
            result = "HOST-VSOCK-FAIL %s" % e
    if time.time() > deadline:
        vm.kill()
        break
vm.wait()
print(result)
srv.close()
