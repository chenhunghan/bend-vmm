import Base
import ../src/lib/u64.bend as U
import ../src/host/range.bend as R

# Spec for src/host/range.bend: guest ranges the host moves bytes through,
# and where a short transfer resumes (C_TO_BEND.md, the pure models).
# RAM at 1 GiB (1073741824), 256 MiB (268435456) long.

def ram_base() -> U.U64:
  U.U64{0, 1073741824}

def ram_size() -> U.U64:
  U.U64{0, 268435456}

def two() -> +List<R.Piece>:
  [R.Piece{U.U64{0, 100}, 10}, R.Piece{U.U64{0, 200}, 20}]

# The last page of RAM fits; a byte more does not; nor a byte below.
law range.last_page:
  {R.Range.fits(ram_base(), ram_size(), U.U64{0, 1342173184}, U.U64{0, 4096}) == True{} : Bool}

law range.past_end:
  {R.Range.fits(ram_base(), ram_size(), U.U64{0, 1342173184}, U.U64{0, 4097}) == False{} : Bool}

law range.below:
  {R.Range.fits(ram_base(), ram_size(), U.U64{0, 1073741823}, U.U64{0, 1}) == False{} : Bool}

# A range whose end wraps past 2^64 never fits, even a mapping of all but
# one byte of the address space (gpa + len would wrap to 16).
law range.no_wrap:
  {R.Range.fits(U.U64{0, 0}, U.U64{4294967295, 4294967295}, U.U64{4294967295, 4294967280}, U.U64{0, 32}) == False{} : Bool}

# All of RAM, and an empty range at its end, fit.
law range.whole:
  {R.Range.fits(ram_base(), ram_size(), ram_base(), ram_size()) == True{} : Bool}

law range.empty_at_end:
  {R.Range.fits(ram_base(), ram_size(), U.U64{0, 1342177280}, U.U64{0, 0}) == True{} : Bool}

# One piece outside RAM fails the whole request.
law range.one_out:
  {R.Range.all_fit(ram_base(), ram_size(), [R.Piece{U.U64{0, 1073741824}, 10}, R.Piece{U.U64{0, 4096}, 10}]) == False{} : Bool}

# A split covers the same bytes, contiguously, in pieces of at most max.
law range.split_total:
  {R.Range.total(R.Range.split(8n, 4096, U.U64{0, 100}, 10000)) == U.U64{0, 10000} : U.U64}

law range.split_contiguous:
  {R.Range.contiguous(R.Range.split(8n, 4096, U.U64{0, 100}, 10000)) == True{} : Bool}

law range.split_pieces:
  {R.Range.split(8n, 4096, U.U64{0, 100}, 10000) == [R.Piece{U.U64{0, 100}, 4096}, R.Piece{U.U64{0, 4196}, 4096}, R.Piece{U.U64{0, 8292}, 1808}] : +List<R.Piece>}

# A short transfer resumes at the exact next byte: inside a piece, at a
# piece's end, and past everything.
law range.advance_mid:
  {R.Range.advance(two(), 15) == [R.Piece{U.U64{0, 205}, 15}] : +List<R.Piece>}

law range.advance_piece:
  {R.Range.advance(two(), 10) == [R.Piece{U.U64{0, 200}, 20}] : +List<R.Piece>}

law range.advance_all:
  {R.Range.advance(two(), 30) == [] : +List<R.Piece>}

law range.advance_total:
  {R.Range.total(R.Range.advance(two(), 7)) == U.U64{0, 23} : U.U64}

# Nothing moved: the request is unchanged, whatever it is.
law range.advance_zero:
  for ps: +List<R.Piece>
  {R.Range.advance(ps, 0) == ps : +List<R.Piece>}
