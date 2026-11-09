import Base
import ../src/virtio/net.bend as N

# src/virtio/net.bend: tests/net.bend pins its behaviour on the simulator.
# Importing it keeps its TODOs visible to the gate.

# Proposed: a plain transmit frame is read through Bend up to a 64 KiB TSO
# segment with its Ethernet header (65550) after the 12-byte virtio_net_hdr;
# the rest of a longer chain is dropped.
law net.max_tx:
  {N.Net.max_tx() == 65562 : U32}

# Proposed: a host frame's GSO size is its segment size (the guest's MSS):
# 4000 bytes in 1410-byte segments get gso_type TCPV4, hdr_len 54 and
# gso_size 1410; a payload within one segment gets no GSO.
law net.host_hdr_mss:
  {N.Net.host_hdr_of(1410, 54, 4000) == [2, 1, 54, 0, 130, 5, 0, 0, 0, 0, 1, 0] : +List<U32>}

law net.host_hdr_one_segment:
  {N.Net.host_hdr_of(1410, 54, 1400) == [2, 0, 54, 0, 0, 0, 0, 0, 0, 0, 1, 0] : +List<U32>}
