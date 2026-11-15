import Base
import ../src/virtio/balauto.bend as A

# Spec for src/virtio/balauto.bend: the automatic balloon's statistics and
# target. Pages are 4 KiB; a 2 GiB guest has 524288.

# The floor: 256 MiB, or 1/10 of RAM when that is more.
law balauto.floor_small:
  {A.Auto.floor(262144) == 65536 : U32}

law balauto.floor_large:
  {A.Auto.floor(4194304) == 419430 : U32}

# The balloon holds at most half the guest's RAM.
law balauto.most:
  {A.Auto.most(524288) == 262144 : U32}

# 1 GiB free in a 2 GiB guest: inflate by one step (256 MiB).
law balauto.grow:
  {A.Auto.target(A.Stats{262144, 524288, 300000}, 0) == 65536 : U32}

# Just above the floor (within the slack): as it is.
law balauto.steady:
  {A.Auto.target(A.Stats{70000, 524288, 300000}, 100000) == 100000 : U32}

# 64 MiB free (below the 256 MiB floor): deflate by the shortfall and the
# slack at once.
law balauto.shrink:
  {A.Auto.target(A.Stats{16384, 524288, 20000}, 100000) == 34464 : U32}

# Deflating never goes below 0.
law balauto.shrink_all:
  {A.Auto.target(A.Stats{0, 524288, 0}, 1000) == 0 : U32}

# Inflating stops at half the guest's RAM.
law balauto.capped:
  {A.Auto.target(A.Stats{500000, 524288, 500000}, 260000) == 262144 : U32}

# No statistics yet (total 0): as it is.
law balauto.no_stats:
  {A.Auto.target(A.Auto.fresh(), 1234) == 1234 : U32}

# Bytes to pages, saturated.
law balauto.pages:
  {A.Auto.pages(1073741824, 0) == 262144 : U32}

law balauto.pages_huge:
  {A.Auto.pages(0, 4096) == 4294967295 : U32}

# A buffer of three entries (free 1 GiB, total 2 GiB, a tag it ignores) and
# a cut one.
law balauto.stats:
  {A.Auto.stats([4, 0, 0, 0, 0, 64, 0, 0, 0, 0, 5, 0, 0, 0, 0, 128, 0, 0, 0, 0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 6, 0, 1], A.Auto.fresh())
    == A.Stats{262144, 524288, 0} : A.Stats}

# Polls every 2 s, the first 30 s after the VM starts.
law balauto.period:
  {A.Auto.period_ms() == 2000 : U32}

law balauto.start:
  {A.Auto.start_ms() == 30000 : U32}
