import Base

# The handoff between the Bend event loop and a vCPU thread (laws/handoff.bend):
# the model of host/hvf.c's hvf_vcpu_run, hvf_vcpu_more and hvf_thread, for
# the C-to-Bend migration (C_TO_BEND.md). No IO and no threads: each side is
# a program counter, the shared words are sequentially consistent (the C
# atomics use the default ordering), and a schedule says which side takes
# the next step. Search runs every schedule.
#
# The shared state: `state` (0 idle, 1 a request waits, 2 its answer is
# ready), `parked` (the loop sleeps on the pipe), and the pipe's bytes.
# The loop posts state = 1, spins (checking for 2) a few times, sets
# parked = 1, checks state once more, and else sleeps on the pipe: a wake
# drains it and sleeps again unless the answer is there (a stale byte from
# an earlier answer). The vCPU thread waits for 1, does the work, sets
# state = 2 and, if it then sees parked, writes a byte.
#
# What must hold: the loop never sleeps on an empty pipe once the answer is
# ready and the vCPU thread has finished (a lost completion), and it takes
# the answer exactly once. The order that makes it so: the loop sets parked
# BEFORE its last check of state, and the thread sets state BEFORE it reads
# parked. `late` swaps the loop's two steps, the bug the model must catch.

# The loop's steps: 0 post, 1 spin check (spins left in the side count),
# 2 set parked, 3 last check, 4 sleeping on the pipe, 5 got the answer.
# The thread's: 0 wait for a request, 1 working, 2 set state = 2,
# 3 read parked (and write the pipe), 4 done.
type Hand is Data:
  Hand{lp: U32, spins: U32, tp: U32, state: U32, parked: U32, pipe: U32, taken: U32}

def Hand.start(+spins: U32, +stale: U32) -> Hand:
  Hand{0, spins, 0, 0, 0, stale, 0}

# The event loop's next step, when it can take one (late: parked is set
# after the last check, the wrong order).
def Hand.loop(+late: Bool, +h: Hand) -> Hand:
  match h:
    case Hand{+lp, +spins, tp, +st, +pk, +pipe, +taken}:
      Bool.pick(Hand, U32.is_eq(lp, 0), Hand{1, spins, tp, 1, pk, pipe, taken},
      Bool.pick(Hand, U32.is_eq(lp, 1),
        Bool.pick(Hand, U32.is_eq(st, 2), Hand{5, spins, tp, 0, pk, pipe, (taken + 1 : U32)},
          Bool.pick(Hand, U32.is_eq(spins, 0), Hand{Bool.pick(U32, late, 3, 2), 0, tp, st, pk, pipe, taken},
            Hand{1, (spins - 1 : U32), tp, st, pk, pipe, taken})),
      Bool.pick(Hand, U32.is_eq(lp, 2), Hand{Bool.pick(U32, late, 4, 3), spins, tp, st, 1, pipe, taken},
      Bool.pick(Hand, U32.is_eq(lp, 3),
        Bool.pick(Hand, U32.is_eq(st, 2), Hand{5, spins, tp, 0, 0, pipe, (taken + 1 : U32)},
          Hand{Bool.pick(U32, late, 2, 4), spins, tp, st, pk, pipe, taken}),
      Bool.pick(Hand, U32.is_eq(lp, 4),
        Bool.pick(Hand, U32.is_eq(pipe, 0), Hand{4, spins, tp, st, pk, 0, taken},
          Bool.pick(Hand, U32.is_eq(st, 2), Hand{5, spins, tp, 0, 0, 0, (taken + 1 : U32)},
            Hand{4, spins, tp, st, pk, 0, taken})),
        Hand{lp, spins, tp, st, pk, pipe, taken})))))

# The vCPU thread's next step.
def Hand.thread(+h: Hand) -> Hand:
  match h:
    case Hand{+lp, +spins, +tp, +st, +pk, +pipe, +taken}:
      Bool.pick(Hand, U32.is_eq(tp, 0), Hand{lp, spins, Bool.pick(U32, U32.is_eq(st, 1), 1, 0), st, pk, pipe, taken},
      Bool.pick(Hand, U32.is_eq(tp, 1), Hand{lp, spins, 2, st, pk, pipe, taken},
      Bool.pick(Hand, U32.is_eq(tp, 2), Hand{lp, spins, 3, 2, pk, pipe, taken},
      Bool.pick(Hand, U32.is_eq(tp, 3), Hand{lp, spins, 4, st, pk, (pipe + U32.min(pk, 1) : U32), taken},
        Hand{lp, spins, tp, st, pk, pipe, taken}))))

# Whether a side can still move: the loop until it has the answer (asleep
# only with a byte in the pipe), the thread until it is done (waiting only
# while a request is posted).
def Hand.loop_can(+h: Hand) -> Bool:
  match h:
    case Hand{+lp, s, t, st, pk, +pipe, tk}:
      U32.is_lt(lp, 5) && (Bool.not(U32.is_eq(lp, 4)) || U32.is_lt(0, pipe))

def Hand.thread_can(+h: Hand) -> Bool:
  match h:
    case Hand{lp, s, +tp, +st, pk, p, tk}:
      U32.is_lt(tp, 4) && (Bool.not(U32.is_eq(tp, 0)) || U32.is_eq(st, 1))

# A finished handoff: the loop took the answer exactly once, and the shared
# words are back to idle.
def Hand.good(+h: Hand) -> Bool:
  match h:
    case Hand{+lp, s, +tp, +st, +pk, p, +tk}:
      U32.is_eq(lp, 5) && U32.is_eq(tp, 4) && U32.is_eq(st, 0) && U32.is_eq(pk, 0) && U32.is_eq(tk, 1)

# One schedule: 0 the loop steps, 1 the thread (a side that cannot move
# skips its turn).
def Hand.step(+side: U32, +late: Bool, +h: Hand) -> Hand:
  Bool.pick(Hand, U32.is_eq(side, 0),
    Bool.pick(Hand, Hand.loop_can(h), Hand.loop(late, h), h),
    Bool.pick(Hand, Hand.thread_can(h), Hand.thread(h), h))

def Hand.run(sched: +List<U32>, +late: Bool, +h: Hand) -> Hand:
  match sched:
    case Nil{}:
      h
    case Con{side, rest}:
      Hand.run(rest, late, Hand.step(side, late, h))

# Stuck: neither side can move.
def Hand.stuck(+h: Hand) -> Bool:
  Bool.not(Hand.loop_can(h)) && Bool.not(Hand.thread_can(h))

# The states every schedule reaches, by breadth: each round adds the
# successors not yet seen (fuel: the most rounds; the longest schedule is
# shorter than 16 plus the spins).
def Hand.key(+h: Hand) -> U32:
  match h:
    case Hand{lp, s, tp, st, pk, p, tk}:
      (lp + (s * 8 : U32) + (tp * 256 : U32) + (st * 2048 : U32) + (pk * 8192 : U32) + (p * 16384 : U32) + (tk * 1048576 : U32) : U32)

def Hand.when(b: Bool, +h: Hand) -> +List<Hand>:
  match b:
    case True{}:
      [h]
    case False{}:
      []

def Hand.next(+late: Bool, +h: Hand) -> +List<Hand>:
  List.append(&2, Hand, Hand.when(Hand.loop_can(h), Hand.loop(late, h)), Hand.when(Hand.thread_can(h), Hand.thread(h)))

def Hand.mem(xs: +List<Hand>, +k: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      U32.is_eq(Hand.key(x), k) || Hand.mem(rest, k)

def Hand.grow(cands: +List<Hand>, +seen: +List<Hand>) -> +List<Hand>:
  match cands:
    case Nil{}:
      seen
    case Con{+c, rest}:
      Hand.grow(rest, Bool.pick(+List<Hand>, Hand.mem(seen, Hand.key(c)), seen, Con{c, seen}))

def Hand.succs(fr: +List<Hand>, +late: Bool) -> +List<Hand>:
  match fr:
    case Nil{}:
      []
    case Con{h, rest}:
      List.append(&2, Hand, Hand.next(late, h), Hand.succs(rest, late))

def Hand.explore(fuel: Nat, +late: Bool, +frontier: +List<Hand>, +seen: +List<Hand>) -> +List<Hand>:
  match fuel:
    case 0n:
      seen
    case 1n+f:
      +grown = Hand.grow(Hand.succs(frontier, late), seen)
      +added = Nat.sub(List.length(&2, Hand, grown), List.length(&2, Hand, seen))
      Bool.pick(+List<Hand>, Nat.is_eq(added, 0n), seen,
        Hand.explore(f, late, List.take(&2, Hand, grown, added), grown))

# Every reached state where neither side can move is a finished handoff.
def Hand.ends_good(xs: +List<Hand>, +late: Bool) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+h, rest}:
      Bool.pick(Bool, List.is_empty(&2, Hand, Hand.next(late, h)), Hand.good(h), True{}) && Hand.ends_good(rest, late)

# Every schedule from h ends well: no side stuck, no answer lost or taken
# twice.
def Hand.all_good(+late: Bool, +h: Hand) -> Bool:
  Hand.ends_good(Hand.explore(64n, late, [h], [h]), late)

# How many states the schedules reach (for the tests: the search is not
# vacuous).
def Hand.reached(+late: Bool, +h: Hand) -> U32:
  U32.from_nat(List.length(&2, Hand, Hand.explore(64n, late, [h], [h])))

# Register writes and PC advances queued for the next request
# (hvf_vcpu_queue_run, hvf_do): applied in the order posted, all of them,
# before the request runs; a full queue (64) makes the poster wait.
type Write is Data:
  Write{reg: U32, value: U32}

def Queue.cap() -> U32:
  64

def Queue.full(+q: +List<Write>) -> Bool:
  U32.is_le(Queue.cap(), U32.from_nat(List.length(&2, Write, q)))

def Queue.post(+q: +List<Write>, +w: Write) -> +List<Write>:
  Bool.pick(+List<Write>, Queue.full(q), q, List.append(&2, Write, q, [w]))

# A register file as (reg, value) writes, newest first; reading takes the
# newest.
def Queue.apply(q: +List<Write>, +regs: +List<Write>) -> +List<Write>:
  match q:
    case Nil{}:
      regs
    case Con{w, rest}:
      Queue.apply(rest, Con{w, regs})

def Queue.read(regs: +List<Write>, +reg: U32) -> U32:
  match regs:
    case Nil{}:
      0
    case Con{w, rest}:
      match w:
        case Write{+r, +v}:
          Bool.pick(U32, U32.is_eq(r, reg), v, Queue.read(rest, reg))
