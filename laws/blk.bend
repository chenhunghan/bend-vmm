import Base
import ../src/lib/u64.bend as U
import ../src/virtio/blk.bend as K

# Frozen spec for src/virtio/blk.bend (request handling is pinned by
# tests/blk.bend on the simulator).

law blk.config:
  {K.Blk.config(U.U64{1, 2}) == [2, 0, 0, 0, 1, 0, 0, 0] : +List<U32>}

# Proposed: the offered feature words (VERSION_1, FLUSH, and RO when
# read-only) and the request kind of FLUSH (type 4).
law blk.features_rw:
  {K.Blk.features(False{}) == U.U64{1, 512} : U.U64}

law blk.features_ro:
  {K.Blk.features(True{}) == U.U64{1, 544} : U.U64}

law blk.kind_flush:
  {K.Blk.kind(4) == 3n : Nat}
