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
