import Base
import ../src/host/transfer.bend as X
import ./t.bend as T

# src/host/transfer.bend under pseudo-random scripts: (1) transfers whose
# calls answer random counts, interruptions, errors and end of file: the
# count moved is the sum of the counts before the first stop, never more
# than asked; (2) a staging table of 8 under random stages and frees: a
# stage never takes a live slot, the table never holds a slot twice, and it
# answers none only when full.

def lcg(+x: U32) -> U32:
  ((x * 1103515245 : U32) + 12345 : U32)

# A call's answer from a random word: mostly counts, sometimes EINTR, an
# error or end of file.
def answer(+r: U32) -> X.Io:
  +k = ((r >> 10n : U32) % 16 : U32)
  Bool.pick(X.Io, U32.is_lt(k, 11), X.IoGot{((r >> 14n : U32) % 300 : U32)},
    Bool.pick(X.Io, U32.is_lt(k, 14), X.IoErr{4}, Bool.pick(X.Io, U32.is_eq(k, 14), X.IoErr{5}, X.IoEof{})))

def script(n: Nat, +r: U32) -> +List<X.Io>:
  match n:
    case 0n:
      []
    case 1n+k:
      Con{answer(r), script(k, lcg(r))}

# The reference: add counts until all moved, a zero count, end of file or
# an error that is not EINTR.
def expect(ios: +List<X.Io>, +want: U32, +done: U32) -> U32:
  match ios:
    case Nil{}:
      done
    case Con{io, rest}:
      match io:
        case X.IoGot{+n}:
          +d = U32.min((done + n : U32), want)
          Bool.pick(U32, U32.is_eq(n, 0) || U32.is_eq(d, want), d, expect(rest, want, d))
        case X.IoEof{}:
          done
        case X.IoErr{+e}:
          Bool.pick(U32, U32.is_eq(e, 4), expect(rest, want, done), done)

def scripts_ok(n: Nat, +r: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      +want = ((r >> 16n : U32) % 2000 : U32)
      +ios = script(12n, lcg(r))
      +got = X.Xfer.moved(X.Xfer.run(ios, want))
      U32.is_eq(got, expect(ios, want, 0)) && U32.is_le(got, want) && scripts_ok(k, lcg(lcg(r)))

def has(xs: +List<U32>, +x: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{y, rest}:
      U32.is_eq(y, x) || has(rest, x)

def distinct(xs: +List<U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +rest}:
      Bool.not(has(rest, x)) && distinct(rest)

def live(+t: X.Stages) -> +List<U32>:
  match t:
    case X.Stages{c, n, l}:
      l

# A stage is good: it took a slot that was free (and now is live), or the
# table was full.
def stage_good(+before: X.Stages, +st: X.Staged) -> Bool:
  match st:
    case X.Staged{+s, +after}:
      Bool.pick(Bool, U32.is_eq(s, X.Stage.none()), U32.is_eq(X.Stage.count(before), 8),
        Bool.not(has(live(before), s)) && has(live(after), s) && U32.is_lt(s, 8))
        && distinct(live(after))

def after(+st: X.Staged) -> X.Stages:
  match st:
    case X.Staged{s, t}:
      t

def stages_ok(n: Nat, +t: X.Stages, +r: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      +st = X.Stage.take(t, 8n)
      +free = U32.is_lt(((r >> 12n : U32) % 8 : U32), 3)
      +victim = ((r >> 16n : U32) % 8 : U32)
      +next = Bool.pick(X.Stages, free, X.Stage.free(t, victim), after(st))
      Bool.pick(Bool, free, True{}, stage_good(t, st)) && stages_ok(k, next, lcg(r))

def main() -> IO(Unit):
  do IO<Unit>:
    T.ok("transfer: 300 random scripts move what the reference says", scripts_ok(300n, 7))
    T.ok("transfer: 400 random stages and frees keep the table sound", stages_ok(400n, X.Stages{8, 0, []}, 99))
