import Base
import ../src/host/fdcache.bend as F
import ./t.bend as T

# src/host/fdcache.bend under a long pseudo-random workload (2 shares, 24
# names, both directions; lookups, opens after a miss, and share flushes):
# never more than 16 files open, an open closes at most one, and every
# descriptor ever opened is either still cached or closed exactly once.

def lcg(+x: U32) -> U32:
  ((x * 1103515245 : U32) + 12345 : U32)

# The run's tally: opens, closes, the most closed by one step, and whether
# a closed descriptor was ever found again.
type Tally is Data:
  Tally{opens: U32, closes: U32, worst: U32, stale: Bool, seed: U32, next_fd: U32, cache: F.Cache, closed: +List<U32>}

def has(xs: +List<U32>, +x: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{y, rest}:
      U32.is_eq(y, x) || has(rest, x)

def len(xs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, xs))

# One step: a flush 1 time in 16, else a lookup, and an open on a miss.
def step(+t: Tally) -> Tally:
  match t:
    case Tally{+opens, +closes, +worst, +stale, +seed, +nfd, +c, +closed}:
      +r = lcg(seed)
      +share = ((r >> 8n : U32) .&. 1 : U32)
      +name = U32.show(((r >> 9n : U32) % 24 : U32))
      +wr = U32.is_eq(((r >> 14n : U32) .&. 1 : U32), 1)
      +flush = U32.is_eq(((r >> 16n : U32) .&. 15 : U32), 0)
      +fl = F.Fdc.flush(c, share)
      +lk = F.Fdc.find(c, share, name, wr)
      +hit = Bool.not(U32.is_eq(F.Fdc.look_fd(lk), F.Fdc.none()))
      +pt = F.Fdc.put(F.Fdc.look_cache(lk), share, name, wr, nfd)
      +gone = Bool.pick(+List<U32>, flush, F.Fdc.done_closed(fl), Bool.pick(+List<U32>, hit, [], F.Fdc.done_closed(pt)))
      Tally{
        Bool.pick(U32, flush || hit, opens, (opens + 1 : U32)),
        (closes + len(gone) : U32),
        Bool.pick(U32, flush, worst, U32.max(worst, len(gone))),
        stale || (hit && has(closed, F.Fdc.look_fd(lk))),
        r,
        Bool.pick(U32, flush || hit, nfd, (nfd + 1 : U32)),
        Bool.pick(F.Cache, flush, F.Fdc.done_cache(fl), Bool.pick(F.Cache, hit, F.Fdc.look_cache(lk), F.Fdc.done_cache(pt))),
        List.append(&2, U32, gone, closed)}

def run(n: Nat, +t: Tally) -> Tally:
  match n:
    case 0n:
      t
    case 1n+k:
      run(k, step(t))

def distinct(xs: +List<U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +rest}:
      Bool.not(has(rest, x)) && distinct(rest)

def report(+t: Tally) -> IO(Unit):
  match t:
    case Tally{+opens, +closes, +worst, stale, s, nfd, +c, +closed}:
      +open = F.Fdc.count(F.Fdc.slots(c))
      do IO<Unit>:
        T.ok("fdcache: the workload opened files and evicted some", U32.is_lt(20, opens) && U32.is_lt(0, closes))
        T.ok("fdcache: never more than 16 open", U32.is_le(open, 16))
        T.ok("fdcache: an open closes at most one file", U32.is_le(worst, 1))
        T.eq_u32("fdcache: every opened file is open or closed once", (open + closes : U32), opens)
        T.ok("fdcache: no descriptor closed twice", distinct(closed))
        T.ok("fdcache: a closed descriptor is never found", Bool.not(stale))

def main() -> IO(Unit):
  report(run(400n, Tally{0, 0, 0, False{}, 2024, 1000, F.Fdc.empty(), []}))
