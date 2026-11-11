import Base

# Host transfers (laws/transfer.bend): the model of host/hvf.c's short-IO
# loop (hvf_iov_io, hvf_disk_copy_run) and its staged send buffers
# (hvf_stage_run, hvf_stage_free), for the C-to-Bend migration
# (C_TO_BEND.md). No IO: the host does the calls; this says what it does
# with each answer.
#
# A transfer of `want` bytes moves them in calls that each answer a count,
# end of file (0), or an error:
#   an interrupted call (EINTR)              -> the same call again, no
#                                              byte lost or repeated
#   a count                                  -> on from the next byte, done
#                                              when all moved
#   end of file, or an error after progress  -> stop with what moved (a read
#                                              zero-fills the rest)
#   an error before any byte moved           -> fail
# The request's answer (hvf_disk_copy_run): a failure is an error, and so is
# a write that stopped short; a short read is not (its tail reads as zeros).

type Io is Data:
  IoGot{n: U32}
  IoEof{}
  IoErr{errno: U32}

type Next is Data:
  XMore{done: U32}
  XRetry{}
  XStop{done: U32}
  XFail{errno: U32}

def Xfer.eintr() -> U32:
  4

def Xfer.after_err(+done: U32, +errno: U32) -> Next:
  Bool.pick(Next, U32.is_eq(errno, Xfer.eintr()), XRetry{},
    Bool.pick(Next, U32.is_eq(done, 0), XFail{errno}, XStop{done}))

def Xfer.after_got(+want: U32, +done: U32, +n: U32) -> Next:
  # a count past what was asked is the host's bug; take no more than want
  +d = U32.min((done + n : U32), want)
  Bool.pick(Next, U32.is_eq(n, 0), XStop{done}, Bool.pick(Next, U32.is_eq(d, want), XStop{want}, XMore{d}))

def Xfer.after(+want: U32, +done: U32, +io: Io) -> Next:
  match io:
    case IoGot{n}:
      Xfer.after_got(want, done, n)
    case IoEof{}:
      XStop{done}
    case IoErr{errno}:
      Xfer.after_err(done, errno)

# Feeds one call's answer to a transfer in progress (XMore{done}); a
# stopped or failed transfer takes no more calls.
def Xfer.retry_at(+done: U32, +nx: Next) -> Next:
  match nx:
    case XRetry{}:
      XMore{done}
    case XMore{d}:
      XMore{d}
    case XStop{d}:
      XStop{d}
    case XFail{e}:
      XFail{e}

def Xfer.feed(+want: U32, +st: Next, +io: Io) -> Next:
  match st:
    case XMore{+done}:
      Xfer.retry_at(done, Xfer.after(want, done, io))
    case XRetry{}:
      XRetry{}
    case XStop{d}:
      XStop{d}
    case XFail{e}:
      XFail{e}

# A whole transfer over the calls' answers, in order, from nothing moved.
def Xfer.go(ios: +List<Io>, +want: U32, +st: Next) -> Next:
  match ios:
    case Nil{}:
      st
    case Con{+io, rest}:
      Xfer.go(rest, want, Xfer.feed(want, st, io))

def Xfer.run(+ios: +List<Io>, +want: U32) -> Next:
  Xfer.go(ios, want, XMore{0})

# The count a transfer moved (0 for a failure).
def Xfer.moved(+st: Next) -> U32:
  match st:
    case XMore{d}:
      d
    case XRetry{}:
      0
    case XStop{d}:
      d
    case XFail{e}:
      0

# The request's answer: 0, or an error (4294967295): a failure, or a write
# (out) that moved less than want.
def Xfer.status(+out: Bool, +want: U32, +st: Next) -> U32:
  match st:
    case XFail{e}:
      4294967295
    case XRetry{}:
      4294967295
    case XMore{d}:
      Bool.pick(U32, out && U32.is_lt(d, want), 4294967295, 0)
    case XStop{d}:
      Bool.pick(U32, out && U32.is_lt(d, want), 4294967295, 0)

# The bytes a read leaves to zero-fill: what did not move.
def Xfer.zero_fill(+out: Bool, +want: U32, +st: Next) -> U32:
  Bool.pick(U32, out, 0, (want - U32.min(Xfer.moved(st), want) : U32))

# Staged send buffers (hvf_stage_run): a guest's segment is copied into a
# slot of `cap` (4096) when handed over, and the slot is freed exactly once:
# sent (tcp_send_staged, which frees it after the send) or dropped
# (stage_drop). Freeing a free slot does nothing (free(NULL)). A new stage
# takes the next free slot round from `next`; none free: none (4294967295).
type Stages is Data:
  Stages{cap: U32, next: U32, live: +List<U32>}

def Stage.none() -> U32:
  4294967295

def Stage.live(xs: +List<U32>, +s: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      U32.is_eq(x, s) || Stage.live(rest, s)

# The first free slot from `from`, trying at most `tries` slots.
def Stage.pick(tries: Nat, +cap: U32, +live: +List<U32>, +from: U32) -> U32:
  match tries:
    case 0n:
      Stage.none()
    case 1n+k:
      +s = (from % cap : U32)
      Bool.pick(U32, Stage.live(live, s), Stage.pick(k, cap, live, (from + 1 : U32)), s)

# A new stage: the slot taken (or none) and the table after it.
type Staged is Data:
  Staged{slot: U32, table: Stages}

def Stage.add(+slot: U32, +cap: U32, +next: U32, +live: +List<U32>) -> Staged:
  Bool.pick(Staged, U32.is_eq(slot, Stage.none()), Staged{slot, Stages{cap, (next + cap : U32), live}},
    Staged{slot, Stages{cap, (slot + 1 : U32), Con{slot, live}}})

def Stage.take(+t: Stages, tries: Nat) -> Staged:
  match t:
    case Stages{+cap, +next, +live}:
      Stage.add(Stage.pick(tries, cap, live, next), cap, next, live)

def Stage.remove(xs: +List<U32>, +s: U32) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{+x, rest}:
      +more = Stage.remove(rest, s)
      Bool.pick(+List<U32>, U32.is_eq(x, s), more, Con{x, more})

# A send or a drop: the slot is free after it, whichever it was.
def Stage.free(+t: Stages, +s: U32) -> Stages:
  match t:
    case Stages{cap, next, live}:
      Stages{cap, next, Stage.remove(live, s)}

def Stage.count(+t: Stages) -> U32:
  match t:
    case Stages{c, n, live}:
      U32.from_nat(List.length(&2, U32, live))
