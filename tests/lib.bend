import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ./t.bend as T

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("u64 hex zero", U.U64.show_hex(U.U64.zero()), "0x0")
    T.eq_str("u64 hex lo", U.U64.show_hex(U.U64{0, 3735928559}), "0xdeadbeef")
    T.eq_str("u64 hex hi", U.U64.show_hex(U.U64{1, 15}), "0x10000000f")
    T.eq_str("u64 add carry", U.U64.show_hex(U.U64.add(U.U64{0, 4294967295}, U.U64{0, 1})), "0x100000000")
    T.eq_str("u64 sub borrow", U.U64.show_hex(U.U64.sub(U.U64{1, 0}, U.U64{0, 1})), "0xffffffff")
    T.eq_str("u64 shl 36", U.U64.show_hex(U.U64.shl(36n, U.U64{0, 1})), "0x1000000000")
    T.eq_str("u64 shr 33", U.U64.show_hex(U.U64.shr(33n, U.U64{6, 0})), "0x3")
    T.eq_u32("u64 bits", U.U64.bits(U.U64{0, 2415919104}, 26n, 6n), 36)
    T.eq_str("u64 align", U.U64.show_hex(U.U64.align_up(12n, U.U64{0, 4097})), "0x2000")
    T.ok("u64 lt", U.U64.is_lt(U.U64{0, 4294967295}, U.U64{1, 0}))
    T.eq_str("bytes le32", show(B.Bytes.le32(287454020)), "[68, 51, 34, 17]")
    T.eq_str("bytes be32", show(B.Bytes.be32(287454020)), "[17, 34, 51, 68]")
    T.eq_u32("bytes read_le32", B.Bytes.read_le32([68, 51, 34, 17]), 287454020)
    T.eq_u32("bytes read_be32", B.Bytes.read_be32([17, 34, 51, 68]), 287454020)
    T.eq_str("bytes le64", show(B.Bytes.le64(U.U64{1, 2})), "[2, 0, 0, 0, 1, 0, 0, 0]")
    T.eq_str("bytes read_le64", U.U64.show_hex(B.Bytes.read_le64([2, 0, 0, 0, 1, 0, 0, 0])), "0x100000002")
    T.eq_str("bytes cstring", show(B.Bytes.of_cstring("ok")), "[111, 107, 0]")
    T.eq_str("bytes pad", show(B.Bytes.pad(2n, [1, 2, 3, 4, 5])), "[1, 2, 3, 4, 5, 0, 0, 0]")
    T.eq_str("bytes pad aligned", show(B.Bytes.pad(2n, [1, 2, 3, 4])), "[1, 2, 3, 4]")
