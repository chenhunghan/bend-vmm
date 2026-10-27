import Base
import ../src/virtio/console.bend as C

# src/virtio/console.bend: tests/console.bend pins its behaviour on the
# simulator. Importing it keeps its TODOs visible to the gate.

# Proposed: one transmit chain hands over at most 64 KiB (the rest of a
# longer chain is dropped).
law console.max_tx:
  {C.Con.max_tx() == 65536 : U32}
