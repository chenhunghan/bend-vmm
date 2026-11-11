import Base
import ../lib/u64.bend as U

# Guest ranges as the host moves bytes through them (laws/range.bend): the
# model of host/hvf.c's hvf_ptr and hvf_iov_io, for the C-to-Bend migration
# (C_TO_BEND.md). No IO: the host still does the copy; this says which
# ranges it may touch and where a short transfer resumes.
#
# A range [gpa, gpa+len) fits a mapping [base, base+size) when gpa >= base,
# len <= size and gpa - base <= size - len: no sum is formed, so nothing can
# wrap at 2^64 (hvf_ptr's check, word for word).

type Piece is Data:
  Piece{gpa: U.U64, len: U32}

def Range.fits(+base: U.U64, +size: U.U64, +gpa: U.U64, +len: U.U64) -> Bool:
  U.U64.is_le(base, gpa) && U.U64.is_le(len, size) && U.U64.is_le(U.U64.sub(gpa, base), U.U64.sub(size, len))

def Range.fits_piece(+base: U.U64, +size: U.U64, p: Piece) -> Bool:
  match p:
    case Piece{gpa, len}:
      Range.fits(base, size, gpa, U.U64.from_u32(len))

# Every piece of a request fits (hvf_iovs: one that leaves RAM fails the
# whole request, before any byte moves).
def Range.all_fit(+base: U.U64, +size: U.U64, ps: +List<Piece>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{p, rest}:
      Range.fits_piece(base, size, p) && Range.all_fit(base, size, rest)

# The bytes a request names.
def Range.total(ps: +List<Piece>) -> U.U64:
  match ps:
    case Nil{}:
      U.U64.zero()
    case Con{p, rest}:
      match p:
        case Piece{g, len}:
          U.U64.add_u32(Range.total(rest), len)

# What is left of a request after a transfer moved `done` of its bytes, from
# the exact next byte: whole pieces drop, a piece cut short keeps its tail
# (hvf_iov_io's skip, then the piece-by-piece retry). Past the total: [].
def Range.rest_piece(+done: U32, +g: U.U64, +len: U32, +rest: +List<Piece>) -> +List<Piece>:
  Bool.pick(+List<Piece>, U32.is_lt(done, len),
    Con{Piece{U.U64.add_u32(g, done), (len - done : U32)}, rest}, rest)

def Range.advance(ps: +List<Piece>, +done: U32) -> +List<Piece>:
  match ps:
    case Nil{}:
      []
    case Con{p, +rest}:
      match p:
        case Piece{+g, +len}:
          Bool.pick(+List<Piece>, U32.is_eq(done, 0), Con{Piece{g, len}, rest},
            Bool.pick(+List<Piece>, U32.is_lt(done, len), Range.rest_piece(done, g, len, rest),
              Range.advance(rest, (done - len : U32))))

# A range cut into pieces of at most `max` bytes, in order, covering the same
# bytes (fuel: the most pieces).
def Range.split(fuel: Nat, +max: U32, +gpa: U.U64, +len: U32) -> +List<Piece>:
  match fuel:
    case 0n:
      []
    case 1n+f:
      Bool.pick(+List<Piece>, U32.is_eq(len, 0), [],
        Bool.pick(+List<Piece>, U32.is_le(len, max), [Piece{gpa, len}],
          Con{Piece{gpa, max}, Range.split(f, max, U.U64.add_u32(gpa, max), (len - max : U32))}))

# Each piece starts where the one before it ends.
def Range.contiguous.go(ps: +List<Piece>, +next: U.U64) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{p, rest}:
      match p:
        case Piece{+g, len}:
          U.U64.is_eq(next, g) && Range.contiguous.go(rest, U.U64.add_u32(g, len))

def Range.contiguous(ps: +List<Piece>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{p, rest}:
      match p:
        case Piece{+g, len}:
          Range.contiguous.go(rest, U.U64.add_u32(g, len))
