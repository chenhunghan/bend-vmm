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

# Hysteresis. Free memory 80 MiB above a 256 MiB floor (inside
# slack + band) leaves the target; 160 MiB above grows it by 96 MiB (free
# stays 64 MiB above the floor).
law balauto.band:
  {A.Auto.target(A.Stats{86016, 524288, 86016}, 1000) == 1000 : U32}

law balauto.grow_leaves_slack:
  {A.Auto.target(A.Stats{106496, 524288, 106496}, 1000) == 25576 : U32}

# The clock. It counts up to Auto.start_ms() and stops there;
# an automatic balloon polls from then on, never before, and never without
# it; the clock stops only for a machine with neither the automatic balloon
# nor RAM to settle.
law balauto.later_counts:
  {A.Auto.later(4000) == 6000 : U32}

law balauto.later_stops:
  {A.Auto.later(29000) == 30000 : U32}

law balauto.polls_after_start:
  {A.Auto.polls(True{}, 30000) == True{} : Bool}

law balauto.polls_not_before:
  {A.Auto.polls(True{}, 28000) == False{} : Bool}

law balauto.polls_not_off:
  {A.Auto.polls(False{}, 30000) == False{} : Bool}

law balauto.ticks_settle:
  {A.Auto.ticks(False{}, 0) == True{} : Bool}

law balauto.ticks_stop:
  {A.Auto.ticks(False{}, 4294967295) == False{} : Bool}

# Proposed (bend-vk8s footprint audit, 2026-11-20): --balloon auto,max=PCT,
# and the guest's own deflate answered at once.
# The cap in percent; 50 is Auto.most.
law balauto.most_of_half:
  {A.Auto.most_of(524289, 50) == A.Auto.most(524289) : U32}

law balauto.most_of_75:
  {A.Auto.most_of(524288, 75) == 393216 : U32}

# 1 TiB of RAM at 90%: no overflow.
law balauto.most_of_huge:
  {A.Auto.most_of(268435456, 90) == 241591910 : U32}

law balauto.pct_ok:
  {A.Auto.pct_ok(10) && A.Auto.pct_ok(90) && Bool.not(A.Auto.pct_ok(9)) && Bool.not(A.Auto.pct_ok(91)) == True{} : Bool}

# 1 GiB free in a 2 GiB guest holding 900 MiB in the balloon: at 75% it
# grows by a step, past half the RAM.
law balauto.grow_75:
  {A.Auto.target_at(A.Stats{262144, 524288, 300000}, 230400, 75) == 295936 : U32}

# The guest took pages back (it holds 100000 of a 120000 target): the
# target drops a step below what it holds.
law balauto.oom:
  {A.Auto.oom(120000, 100000) == 34464 : U32}

law balauto.oom_all:
  {A.Auto.oom(60000, 50000) == 0 : U32}

# It holds the target (or more, deflating toward it): unchanged.
law balauto.oom_none:
  {U32.is_eq(A.Auto.oom(100000, 100000), 100000) && U32.is_eq(A.Auto.oom(100000, 120000), 100000) == True{} : Bool}
