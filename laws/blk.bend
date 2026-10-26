import Base
import ../src/lib/u64.bend as U
import ../src/virtio/blk.bend as K

# Frozen spec for src/virtio/blk.bend (request handling is pinned by
# tests/blk.bend on the simulator).

law blk.config:
  {K.Blk.config(U.U64{1, 2}) == [2, 0, 0, 0, 1, 0, 0, 0] : +List<U32>}
