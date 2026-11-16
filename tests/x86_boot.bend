import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/x86/layout.bend as X
import ../src/x86/boot.bend as Bz
import ./t.bend as T

# Tests for src/x86/boot.bend and src/x86/layout.bend. A synthetic setup
# header: setup_sects 27, version 2.15 (0x020F), XLF_KERNEL_64,
# pref_address 16 MiB, init_size 48 MiB, initrd_addr_max 0x7FFF_FFFF,
# cmdline_size 2047, the jump at 0x200 ending the header at 0x26C.

def head() -> +List<U32>:
  +z = B.Bytes.zeros(1024n)
  +a = Bz.Bz.put(z, 497n, [27])
  +b = Bz.Bz.put(a, 510n, [85, 170, 235, 106, 72, 100, 114, 83, 15, 2])
  +c = Bz.Bz.put(b, 556n, B.Bytes.le32(2147483647))
  +d = Bz.Bz.put(c, 566n, [1, 0, 255, 7, 0, 0])
  +e = Bz.Bz.put(d, 600n, [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3])
  e

def show_info(m: Maybe<&2, Bz.BzInfo>) -> String:
  match m:
    case None{}:
      "None"
    case Some{Bz.BzInfo{s, v, p, i, r, c, h}}:
      "sects=" ++ U32.show(s) ++ " version=" ++ U32.show(v) ++ " pref=" ++ U.U64.show_hex(p) ++ " init=" ++ U32.show(i) ++ " max=" ++ U32.show(r) ++ " cmdline=" ++ U32.show(c) ++ " end=" ++ U32.show(h)

def show_layout(m: Maybe<&2, Bz.BzLayout>) -> String:
  match m:
    case None{}:
      "None"
    case Some{Bz.BzLayout{l, k, r, n}}:
      "load=" ++ U.U64.show_hex(l) ++ " kernel=" ++ U.U64.show_hex(k) ++ " initrd=" ++ U32.show(r) ++ " len=" ++ U32.show(n)

def info() -> Bz.BzInfo:
  Maybe.default(&2, Bz.BzInfo, Bz.Bz.parse(head()), Bz.BzInfo{0, 0, U.U64.zero(), 0, 0, 0, 0})

def gib(n: U32) -> U.U64:
  U.U64.shl(30n, U.U64{0, n})

def show_e820(es: +List<Bz.E820>) -> String:
  match es:
    case Nil{}:
      ""
    case Con{Bz.E820{b, s, k}, rest}:
      U.U64.show_hex(b) ++ "+" ++ U.U64.show_hex(s) ++ ":" ++ U32.show(k) ++ " " ++ show_e820(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("parse", show_info(Bz.Bz.parse(head())), "sects=27 version=527 pref=0x1000000 init=50331648 max=2147483647 cmdline=2047 end=620")
    T.eq_str("parse short", show_info(Bz.Bz.parse(List.take(&2, U32, head(), 1000n))), "None")
    T.eq_str("parse no 64-bit entry", show_info(Bz.Bz.parse(Bz.Bz.put(head(), 566n, [0]))), "None")
    T.eq_str("parse old protocol", show_info(Bz.Bz.parse(Bz.Bz.put(head(), 518n, [11, 2]))), "None")
    T.eq_str("parse bad magic", show_info(Bz.Bz.parse(Bz.Bz.put(head(), 514n, [0]))), "None")
    T.eq_u32("setup_len", Bz.Bz.setup_len(info()), 14336)
    # 2 GiB of RAM, a 10 MiB file, a 20 MiB initrd: the initrd ends at 1 GiB
    T.eq_str("layout", show_layout(Bz.Bz.layout(info(), gib(2), 10485760, 20971520)), "load=0xffc800 kernel=0x1000000 initrd=1052770304 len=20971520")
    # 128 MiB: the initrd ends at RAM's end
    T.eq_str("layout small", show_layout(Bz.Bz.layout(info(), U.U64{0, 134217728}, 10485760, 4096)), "load=0xffc800 kernel=0x1000000 initrd=134213632 len=4096")
    # the initrd would overlap the kernel's init_size
    T.eq_str("layout too small", show_layout(Bz.Bz.layout(info(), U.U64{0, 83886080}, 10485760, 33554432)), "None")
    T.eq_str("e820 2 GiB", show_e820(Bz.Bz.e820(gib(2))), "0x0+0x9fc00:1 0x9fc00+0x60400:2 0x100000+0x7ff00000:1 ")
    T.eq_str("e820 4 GiB", show_e820(Bz.Bz.e820(gib(4))), "0x0+0x9fc00:1 0x9fc00+0x60400:2 0x100000+0xbff00000:1 0x100000000+0x40000000:1 ")
    T.eq_u32("zero page length", U32.from_nat(List.length(&2, U32, Bz.Bz.zero_page(info(), head(), gib(2), Bz.BzLayout{U.U64.zero(), U.U64.zero(), 4096, 8192}, 917504))), 4096)
    +zp : +List<U32> = Bz.Bz.zero_page(info(), head(), gib(2), Bz.BzLayout{U.U64.zero(), U.U64.zero(), 4096, 8192}, 917504)
    T.eq_str("zero page fields", List.show(~&2, ~U32, ~U32.show, [Bz.Bz.u8(zp, 497n), Bz.Bz.u8(zp, 528n), Bz.Bz.u32(zp, 536n), Bz.Bz.u32(zp, 540n), Bz.Bz.u32(zp, 552n), Bz.Bz.u32(zp, 112n), Bz.Bz.u8(zp, 488n), Bz.Bz.u32(zp, 740n), Bz.Bz.u32(zp, 514n), Bz.Bz.u8(zp, 620n)]), "[27, 255, 4096, 8192, 131072, 917504, 3, 654336, 1400005704, 0]")
    T.eq_u32("pd length", U32.from_nat(List.length(&2, U32, Bz.Boot.pd())), 4096)
    T.eq_u32("pd entry 1", Bz.Bz.u32(Bz.Boot.pd(), 8n), 2097283)
    T.eq_u32("regs words", U32.from_nat(List.length(&2, U32, Bz.Boot.regs(16777216))), 126)
    T.eq_str("cmdline cut", List.show(~&2, ~U32, ~U32.show, Bz.Bz.cmdline(Bz.BzInfo{0, 0, U.U64.zero(), 0, 0, 3, 0}, "abcdef")), "[97, 98, 99, 0]")
    T.eq_u32("gsi uart", X.X86.gsi_at(33), 4)
    T.eq_u32("gsi slot 0", X.X86.gsi_at(48), 5)
    T.eq_u32("gsi slot 16", X.X86.gsi_at(64), 23)
    T.eq_u32("gsi slot 17", X.X86.gsi_at(65), 255)
    T.eq_u32("gsi other", X.X86.gsi_at(34), 255)
    T.eq_u32("gsi table", U32.from_nat(List.length(&2, U32, X.X86.gsi_table())), 80)
    T.eq_str("to_bus slot 3", U.U64.show_hex(X.X86.to_bus(U.U64{0, 3489662464})), "0xa000600")
    T.eq_str("to_bus outside", U.U64.show_hex(X.X86.to_bus(U.U64{0, 3489677312})), "0x0")
