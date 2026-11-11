import Base

# The share descriptor cache (laws/fdcache.bend): the model of host/hvf.c's
# hvf_fdc_find, hvf_fdc_put and hvf_fdc_flush, for the C-to-Bend migration
# (C_TO_BEND.md). Files a 9p share reads and writes stay open, by share,
# relative path and direction, in 16 slots. A hit marks its slot used now;
# a new file takes the least recently used slot (an empty one first, the
# lowest such) and closes the descriptor it held; every operation that can
# change what a path names empties the share's slots first (flush). No IO:
# answers say which descriptors the host closes.

type Slot is Data:
  Slot{used: U32, share: U32, wr: Bool, rel: String, fd: U32}

type Cache is Data:
  Cache{tick: U32, slots: +List<Slot>}

# A lookup: the descriptor (Fdc.none on a miss) and the cache after it.
type Found is Data:
  Found{fd: U32, cache: Cache}

# A put or a flush: the descriptors to close and the cache after it.
type Freed is Data:
  Freed{closed: +List<U32>, cache: Cache}

def Fdc.size() -> Nat:
  16n

def Fdc.none() -> U32:
  4294967295

def Fdc.empty.go(n: Nat) -> +List<Slot>:
  match n:
    case 0n:
      []
    case 1n+k:
      Con{Slot{0, 0, False{}, "", 0}, Fdc.empty.go(k)}

def Fdc.empty() -> Cache:
  Cache{0, Fdc.empty.go(Fdc.size())}

def Fdc.is(+s: Slot, +share: U32, +rel: String, +wr: Bool) -> Bool:
  match s:
    case Slot{+used, sh, w, r, fd}:
      Bool.not(U32.is_eq(used, 0)) && U32.is_eq(sh, share) && Bool.not(Bool.xor(w, wr)) && String.eq(r, rel)

def Fdc.touch(+s: Slot, +now: U32) -> Slot:
  match s:
    case Slot{u, sh, w, r, fd}:
      Slot{now, sh, w, r, fd}

# The slot that matches, marked used at `now`, and its descriptor; the
# first match wins (there is at most one).
def Fdc.find.go(slots: +List<Slot>, +share: U32, +rel: String, +wr: Bool, +now: U32) -> +List<Slot>:
  match slots:
    case Nil{}:
      []
    case Con{+s, +rest}:
      Bool.pick(+List<Slot>, Fdc.is(s, share, rel, wr),
        Con{Fdc.touch(s, now), rest},
        Con{s, Fdc.find.go(rest, share, rel, wr, now)})

def Fdc.fd_of(slots: +List<Slot>, +share: U32, +rel: String, +wr: Bool) -> U32:
  match slots:
    case Nil{}:
      Fdc.none()
    case Con{+s, +rest}:
      match s:
        case Slot{u, sh, w, r, +fd}:
          Bool.pick(U32, Fdc.is(Slot{u, sh, w, r, fd}, share, rel, wr), fd, Fdc.fd_of(rest, share, rel, wr))

# A lookup (hvf_fdc_find): a hit marks its slot used now (the tick moves
# on); a miss changes nothing.
def Fdc.find(+c: Cache, +share: U32, +rel: String, +wr: Bool) -> Found:
  match c:
    case Cache{+tick, +slots}:
      +fd = Fdc.fd_of(slots, share, rel, wr)
      +now = (tick + 1 : U32)
      Bool.pick(Found, U32.is_eq(fd, Fdc.none()), Found{fd, Cache{tick, slots}},
        Found{fd, Cache{now, Fdc.find.go(slots, share, rel, wr, now)}})

# The least used mark over the slots (an empty slot's is 0).
def Fdc.least(slots: +List<Slot>, +m: U32) -> U32:
  match slots:
    case Nil{}:
      m
    case Con{s, rest}:
      match s:
        case Slot{+u, sh, w, r, fd}:
          Fdc.least(rest, U32.min(u, m))

def Fdc.keep(+s: Slot, +d: Freed) -> Freed:
  match d:
    case Freed{closed, c}:
      match c:
        case Cache{t, slots}:
          Freed{closed, Cache{t, Con{s, slots}}}

def Fdc.flush.add(mine: Bool, +fd: U32, +s: Slot, +d: Freed) -> Freed:
  match d:
    case Freed{closed, c}:
      Fdc.keep(s, Freed{Bool.pick(+List<U32>, mine, Con{fd, closed}, closed), c})

# The first slot marked m takes the new file; the descriptor it held, if it
# was in use, is closed.
def Fdc.replace(slots: +List<Slot>, +m: U32, +new: Slot) -> Freed:
  match slots:
    case Nil{}:
      Freed{[], Cache{0, []}}
    case Con{+s, +rest}:
      match s:
        case Slot{+u, +sh, +w, +r, +fd}:
          Bool.pick(Freed, U32.is_eq(u, m),
            Freed{Bool.pick(+List<U32>, U32.is_eq(u, 0), [], [fd]), Cache{0, Con{new, rest}}},
            Fdc.keep(Slot{u, sh, w, r, fd}, Fdc.replace(rest, m, new)))

def Fdc.with_tick(+t: U32, +d: Freed) -> Freed:
  match d:
    case Freed{closed, c}:
      match c:
        case Cache{x, slots}:
          Freed{closed, Cache{t, slots}}

# A new open file (hvf_fdc_put, after a miss).
def Fdc.put(+c: Cache, +share: U32, +rel: String, +wr: Bool, +fd: U32) -> Freed:
  match c:
    case Cache{+tick, +slots}:
      +now = (tick + 1 : U32)
      Fdc.with_tick(now, Fdc.replace(slots, Fdc.least(slots, 4294967295), Slot{now, share, wr, rel, fd}))

# A share's slots emptied (hvf_fdc_flush): each one in use closes.
def Fdc.flush.go(slots: +List<Slot>, +share: U32) -> Freed:
  match slots:
    case Nil{}:
      Freed{[], Cache{0, []}}
    case Con{+s, +rest}:
      match s:
        case Slot{+u, +sh, +w, +r, +fd}:
          +mine = Bool.not(U32.is_eq(u, 0)) && U32.is_eq(sh, share)
          Fdc.flush.add(mine, fd, Slot{Bool.pick(U32, mine, 0, u), sh, w, r, fd}, Fdc.flush.go(rest, share))

def Fdc.flush(+c: Cache, +share: U32) -> Freed:
  match c:
    case Cache{+tick, +slots}:
      Fdc.with_tick(tick, Fdc.flush.go(slots, share))

# How many slots are in use.
def Fdc.count(slots: +List<Slot>) -> U32:
  match slots:
    case Nil{}:
      0
    case Con{s, rest}:
      match s:
        case Slot{+u, sh, w, r, fd}:
          (Bool.to_u32(Bool.not(U32.is_eq(u, 0))) + Fdc.count(rest) : U32)

def Fdc.slots(+c: Cache) -> +List<Slot>:
  match c:
    case Cache{t, slots}:
      slots

def Fdc.done_cache(+d: Freed) -> Cache:
  match d:
    case Freed{x, c}:
      c

def Fdc.done_closed(+d: Freed) -> +List<U32>:
  match d:
    case Freed{x, c}:
      x

def Fdc.look_fd(+l: Found) -> U32:
  match l:
    case Found{fd, c}:
      fd

def Fdc.look_cache(+l: Found) -> Cache:
  match l:
    case Found{fd, c}:
      c

# What the host acts on (C keeps the descriptors and finds an entry by its
# key; these are Bend's decisions, host/fs.bend):

# The host operations that can change what a path names, so the share's
# open files are dropped first (hvf_fs_run's op numbers: 4 create, 5 mkdir,
# 6 remove, 7 rename, 10 symlink).
def Fdc.invalidates(+op: U32) -> Bool:
  U32.is_eq(op, 4) || U32.is_eq(op, 5) || U32.is_eq(op, 6) || U32.is_eq(op, 7) || U32.is_eq(op, 10)

# The slot a newly opened file takes, from each slot's last use as the host
# reports it ([hi, lo] per slot; 0 is an empty slot): the least recently
# used, the first such (as Fdc.replace).
def Fdc.victim.go(ws: +List<U32>, +i: U32, +best: U32, +bhi: U32, +blo: U32) -> U32:
  match ws:
    case Nil{}:
      best
    case Con{+hi, rest}:
      match rest:
        case Nil{}:
          best
        case Con{+lo, more}:
          +less = U32.is_lt(hi, bhi) || (U32.is_eq(hi, bhi) && U32.is_lt(lo, blo))
          Fdc.victim.go(more, (i + 1 : U32), Bool.pick(U32, less, i, best), Bool.pick(U32, less, hi, bhi), Bool.pick(U32, less, lo, blo))

def Fdc.victim(+ws: +List<U32>) -> U32:
  Fdc.victim.go(ws, 0, 0, 4294967295, 4294967295)
