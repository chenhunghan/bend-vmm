import Base

# The host's descriptor budget for guest flows (laws/fds.bend): of the
# process's descriptor limit, NAT connections, UDP flows, vsock and
# forwarded clients may use all but a spare for disks, the control socket,
# shares, pipes and the runtime: 128, or half of a small limit. A new flow
# past the budget is refused (a RST, or a dropped datagram) before the host
# could run out of descriptors.

def Fds.spare() -> U32:
  128

def Fds.room(+limit: U32) -> U32:
  (limit - U32.min((limit / 2 : U32), Fds.spare()) : U32)

# The process's soft descriptor limit, from what the host reports at
# startup (Hvf.nofile): the soft and hard limits (4294967295 for unlimited
# or more), the most descriptors the runtime's poller takes (top: FD_SETSIZE,
# 1024, on macOS; 65536 on Linux), and whether the soft limit must be no
# more than top (exact: macOS's select() fails past FD_SETSIZE, so the
# kernel must never hand out a larger descriptor). It aims at the hard
# limit or top, whichever is lower: exactly that when exact; otherwise only
# ever raised to it, and an unlimited soft limit stays.
def Fds.unlimited() -> U32:
  4294967295

def Fds.soft.go(exact: Bool, +cur: U32, +want: U32) -> U32:
  match exact:
    case True{}:
      want
    case False{}:
      Bool.pick(U32, U32.is_eq(cur, Fds.unlimited()) || U32.is_le(want, cur), cur, want)

def Fds.soft(+cur: U32, +max: U32, +top: U32, exact: Bool) -> U32:
  Fds.soft.go(exact, cur, U32.min(max, top))
