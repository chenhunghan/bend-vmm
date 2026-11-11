import Base
import ../src/host/fdcache.bend as F

# Spec for src/host/fdcache.bend: the 9p share descriptor cache, 16 slots,
# least recently used (C_TO_BEND.md, the pure models).

# Files "0", "1", ... opened in order in share 0, descriptors 100, 101, ...
def opened(n: Nat) -> F.Cache:
  match n:
    case 0n:
      F.Fdc.empty()
    case 1n+(+k):
      F.Fdc.done_cache(F.Fdc.put(opened(k), 0, U32.show(U32.from_nat(k)), False{}, (100 + U32.from_nat(k) : U32)))

def last_closed(n: Nat) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+(+k):
      F.Fdc.done_closed(F.Fdc.put(opened(k), 0, U32.show(U32.from_nat(k)), False{}, (100 + U32.from_nat(k) : U32)))

def find_fd(+c: F.Cache, +share: U32, +rel: String, +wr: Bool) -> U32:
  F.Fdc.look_fd(F.Fdc.find(c, share, rel, wr))

# A file is found by share, path and direction, and only so.
law fdcache.hit:
  {find_fd(opened(3n), 0, "1", False{}) == 101 : U32}

law fdcache.other_direction:
  {find_fd(opened(3n), 0, "1", True{}) == 4294967295 : U32}

law fdcache.other_share:
  {find_fd(opened(3n), 1, "1", False{}) == 4294967295 : U32}

# Until all 16 slots are in use, opening closes nothing; then each new file
# closes exactly one: the least recently used.
law fdcache.fills_first:
  {last_closed(16n) == [] : +List<U32>}

law fdcache.evicts_one:
  {last_closed(17n) == [100] : +List<U32>}

law fdcache.full_stays_full:
  {F.Fdc.count(F.Fdc.slots(opened(17n))) == 16 : U32}

# A hit makes its file the most recently used: the next eviction skips it.
law fdcache.hit_refreshes:
  {F.Fdc.done_closed(F.Fdc.put(F.Fdc.look_cache(F.Fdc.find(opened(16n), 0, "0", False{})), 0, "new", False{}, 200)) == [101] : +List<U32>}

# Emptying a share (before anything that changes what a path names) closes
# each of its open files once, and leaves other shares' files open.
law fdcache.flush_share:
  {F.Fdc.done_closed(F.Fdc.flush(F.Fdc.done_cache(F.Fdc.put(opened(2n), 1, "x", False{}, 300)), 0)) == [100, 101] : +List<U32>}

law fdcache.flush_keeps_others:
  {find_fd(F.Fdc.done_cache(F.Fdc.flush(F.Fdc.done_cache(F.Fdc.put(opened(2n), 1, "x", False{}, 300)), 0)), 1, "x", False{}) == 300 : U32}

law fdcache.flush_then_miss:
  {find_fd(F.Fdc.done_cache(F.Fdc.flush(opened(2n), 0)), 0, "0", False{}) == 4294967295 : U32}
