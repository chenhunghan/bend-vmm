import Base
import ../src/virtio/rng.bend as R
import ../src/lib/u64.bend as U
import ../src/virtio/queue.bend as Q

# src/virtio/rng.bend has no laws yet: tests/rng.bend pins its behaviour on
# the simulator. Importing it keeps its TODOs visible to the gate.

# Proposed: one chain gets at most 65536 bytes of entropy, however large its
# writable room (even when the lengths would wrap a U32 sum); a smaller room
# gets exactly its size.
law rng.want_capped:
  {R.Rng.want([Q.Desc{U.U64{0, 16384}, 4294967295, 2, 1}, Q.Desc{U.U64{0, 32768}, 2, 2, 0}]) == 65536 : U32}

law rng.want_small:
  {R.Rng.want([Q.Desc{U.U64{0, 16400}, 3, 3, 2}, Q.Desc{U.U64{0, 16408}, 2, 2, 0}]) == 5 : U32}
