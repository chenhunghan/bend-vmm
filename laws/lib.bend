import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B

# Frozen spec for src/lib (u64.bend, bytes.bend).

law lib.add_carry:
  {U.U64.add(U.U64{0, 4294967295}, U.U64{0, 1}) == U.U64{1, 0} : U.U64}

law lib.sub_borrow:
  {U.U64.sub(U.U64{1, 0}, U.U64{0, 1}) == U.U64{0, 4294967295} : U.U64}

law lib.le32:
  {B.Bytes.le32(287454020) == [68, 51, 34, 17] : +List<U32>}

law lib.be32:
  {B.Bytes.be32(287454020) == [17, 34, 51, 68] : +List<U32>}

law lib.show_hex:
  {U.U64.show_hex(U.U64{1, 15}) == "0x10000000f" : String}

# General laws.

law lib.add_zero:
  for a: U.U64
  {U.U64.add(a, U.U64.zero()) == a : U.U64}

law lib.add_comm:
  for a: U.U64
  for b: U.U64
  {U.U64.add(a, b) == U.U64.add(b, a) : U.U64}

law lib.sub_self:
  for a: U.U64
  {U.U64.sub(a, a) == U.U64.zero() : U.U64}

law lib.le32_length:
  for x: U32
  {List.length(&2, U32, B.Bytes.le32(x)) == 4n : Nat}

law lib.le32_roundtrip:
  for x: U32
  {B.Bytes.read_le32(B.Bytes.le32(x)) == x : U32}

law lib.be32_roundtrip:
  for x: U32
  {B.Bytes.read_be32(B.Bytes.be32(x)) == x : U32}

law lib.slice_length:
  for bs: +List<U32>
  for n: Nat
  {Nat.is_le(List.length(&2, U32, B.Bytes.slice(bs, 0n, n)), n) == True{} : Bool}
