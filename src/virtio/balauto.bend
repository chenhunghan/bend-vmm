import Base
import ../lib/bytes.bend as B

# The automatic balloon (--balloon auto, the default): the guest's memory
# statistics (virtio-balloon's stats queue, VIRTIO_BALLOON_F_STATS_VQ) set
# the balloon's target, so memory the guest leaves free comes back to the
# host even when free page reporting has not reported it (Linux reports a
# zone again only after enough pages were freed there: memory freed and
# taken again stays unreported), and the guest gets it back as soon as it
# needs it.
#
# Every Auto.period_ms() the host returns the stats buffer the driver
# posted; the driver posts it again with fresh values, and Auto.target
# moves the target:
#   - free above the floor by more than Auto.slack() + Auto.band(): inflate
#     by the excess over floor + slack (at most Auto.step() a time), never
#     past Auto.most(total);
#   - free below the floor: deflate by the shortfall and Auto.slack() more,
#     at once;
#   - else: as it is.
# The floor is the larger of 256 MiB and 1/10 of the guest's RAM, and the
# balloon holds at most half of it: a burst the guest meets past that takes
# pages back one MiB at a time (DEFLATE_ON_OOM), which is slow (a 1.4 GiB
# burst into a 2 GiB guest ran at a fifth of its speed with a 3/4 cap). The
# guest's own safety net stays: under memory pressure it takes pages back
# from the balloon (VIRTIO_BALLOON_F_DEFLATE_ON_OOM) before it would kill
# anything. Pages are the balloon's 4 KiB units.
#
# Stats (Virtio 1.2 5.5.6.3): the buffer holds 10-byte entries, a u16 tag
# then a u64 value, little-endian; tag 4 is free memory, 5 total memory,
# 6 available memory, in bytes.

type Stats is Data:
  Stats{free: U32, total: U32, avail: U32}

def Auto.none() -> U32:
  # 0xFFFFFFFF: no buffer held
  4294967295

def Auto.period_ms() -> U32:
  2000

# The first poll waits this long after the VM starts: the balloon stays out
# of the guest's way while it boots and starts its work (inflating takes
# guest CPU: an upload in the guest's first seconds ran 19% slower).
def Auto.start_ms() -> U32:
  30000

def Auto.slack() -> U32:
  # 64 MiB
  16384

def Auto.step() -> U32:
  # 256 MiB
  65536

# Hysteresis: the balloon grows only when free memory is above the floor by
# more than Auto.slack() and Auto.band() more, and then leaves Auto.slack()
# free above the floor; it shrinks only below the floor. A guest whose free
# memory moves by tens of MiB (a busy Kubernetes control plane) no longer
# makes the balloon chase it: inflating and deflating every poll cost such a
# VM 20 points of host CPU.
def Auto.band() -> U32:
  # 32 MiB
  8192

def Auto.floor(+total: U32) -> U32:
  # 256 MiB, or 1/10 of the guest's RAM
  U32.max(65536, (total / 10 : U32))

# The most the balloon holds: half the guest's RAM.
def Auto.most(+total: U32) -> U32:
  (total / 2 : U32)

# A byte count in pages, saturated at 2^32 - 1.
def Auto.pages(+lo: U32, +hi: U32) -> U32:
  Bool.pick(U32, U32.is_le(4096, hi), 4294967295, ((hi << 20n : U32) .|. (lo >> 12n : U32) : U32))

def Auto.entry(+tag: U32, +v: U32, +st: Stats) -> Stats:
  match st:
    case Stats{+f, +t, +a}:
      Bool.pick(Stats, U32.is_eq(tag, 4), Stats{v, t, a},
      Bool.pick(Stats, U32.is_eq(tag, 5), Stats{f, v, a},
      Bool.pick(Stats, U32.is_eq(tag, 6), Stats{f, t, v}, Stats{f, t, a})))

# The statistics in a buffer's bytes (entries past the last whole one are
# ignored; a tag not given keeps its value from st).
def Auto.stats.go(fuel: Nat, +bs: +List<U32>, +st: Stats) -> Stats:
  match fuel:
    case 0n:
      st
    case 1n+f:
      Bool.pick(Stats, Nat.is_lt(List.length(&2, U32, bs), 10n), st,
        Auto.stats.go(f, List.drop(&2, U32, bs, 10n),
          Auto.entry(B.Bytes.read_le(2n, bs), Auto.pages(B.Bytes.read_le32(List.drop(&2, U32, bs, 2n)), B.Bytes.read_le32(List.drop(&2, U32, bs, 6n))), st)))

def Auto.stats(+bs: +List<U32>, +st: Stats) -> Stats:
  Auto.stats.go(64n, bs, st)

def Auto.fresh() -> Stats:
  Stats{0, 0, 0}

def Auto.grow(+free: U32, +floor: U32, +target: U32, +most: U32) -> U32:
  U32.min(most, (target + U32.min(((free - floor : U32) - Auto.slack() : U32), Auto.step()) : U32))

def Auto.shrink(+free: U32, +floor: U32, +target: U32) -> U32:
  +want = ((floor - free : U32) + Auto.slack() : U32)
  Bool.pick(U32, U32.is_le(target, want), 0, (target - want : U32))

# The balloon's next target from the guest's statistics and the current
# one: its target, or what it holds when the guest took pages back
# (DEFLATE_ON_OOM) and it holds less (a guest that reported no total:
# unchanged).
def Auto.target(+st: Stats, +target: U32) -> U32:
  match st:
    case Stats{+free, +total, a}:
      +floor = Auto.floor(total)
      Bool.pick(U32, U32.is_zero(total), target,
      Bool.pick(U32, U32.is_lt(((floor + Auto.slack() : U32) + Auto.band() : U32), free), Auto.grow(free, floor, target, Auto.most(total)),
      Bool.pick(U32, U32.is_lt(free, floor), Auto.shrink(free, floor, target), target)))
