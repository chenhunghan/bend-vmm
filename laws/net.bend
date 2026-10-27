import Base
import ../src/virtio/net.bend as N

# src/virtio/net.bend: tests/net.bend pins its behaviour on the simulator.
# Importing it keeps its TODOs visible to the gate.

# Proposed: a plain transmit frame is read through Bend up to a 64 KiB TSO
# segment with its Ethernet header (65550) after the 12-byte virtio_net_hdr;
# the rest of a longer chain is dropped.
law net.max_tx:
  {N.Net.max_tx() == 65562 : U32}
