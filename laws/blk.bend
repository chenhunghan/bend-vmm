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

# Proposed: one request moves at most 16 MiB (a longer one is IOERR, the disk
# untouched), and the device offers SIZE_MAX (bit 1) and SEG_MAX (bit 2) with
# size_max 128 KiB and seg_max 128, whose product is that cap, so Linux never
# builds a longer request.
law blk.len_ok_max:
  {K.Blk.len_ok(16777216) == True{} : Bool}

law blk.len_ok_past_max:
  {K.Blk.len_ok(16777217) == False{} : Bool}

law blk.limits_cover_max:
  {(K.Blk.size_max() * K.Blk.seg_max() : U32) == K.Blk.max_len() : U32}

law blk.offered_rw:
  {K.Blk.offered(False{}) == U.U64{1, 518} : U.U64}

law blk.offered_ro:
  {K.Blk.offered(True{}) == U.U64{1, 550} : U.U64}

law blk.config_limits:
  {K.Blk.config_limits(U.U64{1, 2}) == [2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 128, 0, 0, 0] : +List<U32>}
