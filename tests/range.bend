import Base
import ../src/lib/u64.bend as U
import ../src/host/range.bend as R
import ./t.bend as T

# src/host/range.bend over a sweep: for every request length and split size
# below, the split covers the request contiguously, and resuming after any
# count moved leaves exactly the rest of its bytes, from the next byte.

def lens() -> +List<U32>:
  [1, 7, 512, 4095, 4096, 4097, 10000]

def maxes() -> +List<U32>:
  [512, 1000, 4096, 65536]

def dones() -> +List<U32>:
  [0, 1, 511, 4096, 9999, 10000, 70000]

def gpa() -> U.U64:
  U.U64{1, 4294963200}

def left(+len: U32, +done: U32) -> U32:
  Bool.pick(U32, U32.is_lt(done, len), (len - done : U32), 0)

# The rest starts at gpa + done (when anything is left).
def starts_at(ps: +List<R.Piece>, +at: U.U64) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{p, rest}:
      match p:
        case R.Piece{g, l}:
          U.U64.is_eq(g, at)

def one_done(+len: U32, +max: U32, +done: U32) -> Bool:
  +ps = R.Range.split(24n, max, gpa(), len)
  +rest = R.Range.advance(ps, done)
  U.U64.is_eq(R.Range.total(ps), U.U64{0, len})
    && R.Range.contiguous(ps)
    && U.U64.is_eq(R.Range.total(rest), U.U64{0, left(len, done)})
    && R.Range.contiguous(rest)
    && starts_at(rest, U.U64.add_u32(gpa(), done))

def all_dones(ds: +List<U32>, +len: U32, +max: U32) -> Bool:
  match ds:
    case Nil{}:
      True{}
    case Con{d, rest}:
      one_done(len, max, d) && all_dones(rest, len, max)

def all_maxes(ms: +List<U32>, +len: U32) -> Bool:
  match ms:
    case Nil{}:
      True{}
    case Con{m, rest}:
      all_dones(dones(), len, m) && all_maxes(rest, len)

def all_lens(ls: +List<U32>) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case Con{l, rest}:
      all_maxes(maxes(), l) && all_lens(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    T.ok("range: split then resume, every length, size and count moved", all_lens(lens()))
    T.ok("range: a range ending at 2^64 fits; one byte more does not",
      R.Range.fits(U.U64{4294967295, 0}, U.U64{0, 4294967295}, U.U64{4294967295, 1}, U.U64{0, 4294967294})
        && Bool.not(R.Range.fits(U.U64{4294967295, 0}, U.U64{0, 4294967295}, U.U64{4294967295, 1}, U.U64{0, 4294967295})))
