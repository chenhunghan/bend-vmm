import Base
import ../src/lib/inflate.bend as I

# Spec for src/lib/inflate.bend: DEFLATE and gzip decoding as the host
# accepts it (host/hvf.c, hvf_inflate over zlib). The vectors come from
# zlib. Laws that decode with the fixed or a dynamic code run the verdict
# kernel out of fuel (the 288-symbol code is built each time), so those
# vectors are in tests/inflate.bend (made from zlib by
# tests/oracles/inflate.py, which also checks a larger random corpus).

def ok_len(+r: I.Res) -> U32:
  match r:
    case I.ROk{+out}:
      U32.from_nat(List.length(&2, U32, out))
    case I.RErr{c}:
      4294967295

def err_of(+r: I.Res) -> U32:
  match r:
    case I.ROk{out}:
      0
    case I.RErr{c}:
      c

# A stored block, and one whose NLEN is not ~LEN.
law inflate.stored:
  {I.Inflate.raw([1, 5, 0, 250, 255, 104, 101, 108, 108, 111], 64) == I.ROk{[104, 101, 108, 108, 111]} : I.Res}

law inflate.stored_bad_nlen:
  {err_of(I.Inflate.raw([1, 5, 0, 251, 255, 104, 101, 108, 108, 111], 64)) == 3 : U32}

# Block type 3 does not exist.
law inflate.btype3:
  {err_of(I.Inflate.raw([7, 0, 0], 64)) == 2 : U32}

law inflate.empty_input:
  {err_of(I.Inflate.raw([], 64)) == 1 : U32}

law inflate.gzip_reserved_flag:
  {err_of(I.Inflate.gunzip([31, 139, 8, 32, 0, 0, 0, 0, 0, 3, 203, 200, 4, 0, 172, 42, 147, 216, 2, 0, 0, 0], 64)) == 20 : U32}

# CRC-32's check value ("123456789").
law inflate.crc32:
  {I.Crc.of([49, 50, 51, 52, 53, 54, 55, 56, 57]) == 3421780262 : U32}

# The bit reader takes bits low first, across bytes.
law inflate.bits:
  {I.Got.v(I.Bits.get(12, I.Bits.of([171, 205]))) == 3499 : U32}

# Canonical codes (RFC 1951's example: lengths 3 3 3 3 3 2 4 4 for A..H):
# F is 00, A is 010, G is 1110.
law inflate.huff_short:
  {I.Huff.decode(I.Huff.of([3, 3, 3, 3, 3, 2, 4, 4]), I.Bits.of([0])) == I.Sym{5, I.Bits{0, 6, [], False{}}} : I.Sym}

law inflate.huff_three:
  {I.Huff.decode(I.Huff.of([3, 3, 3, 3, 3, 2, 4, 4]), I.Bits.of([2])) == I.Sym{0, I.Bits{0, 5, [], False{}}} : I.Sym}

law inflate.huff_four:
  {I.Huff.decode(I.Huff.of([3, 3, 3, 3, 3, 2, 4, 4]), I.Bits.of([7])) == I.Sym{6, I.Bits{0, 4, [], False{}}} : I.Sym}

# zlib's rules for a code: over-subscribed is bad; incomplete only for a
# single code of length 1 (not for the code-length code).
law inflate.huff_over:
  {I.Huff.ok(False{}, I.Huff.of([1, 1, 1])) == False{} : Bool}

law inflate.huff_incomplete:
  {I.Huff.ok(False{}, I.Huff.of([2, 2, 2])) == False{} : Bool}

law inflate.huff_single:
  {I.Huff.ok(False{}, I.Huff.of([0, 1])) && Bool.not(I.Huff.ok(True{}, I.Huff.of([0, 1]))) == True{} : Bool}
