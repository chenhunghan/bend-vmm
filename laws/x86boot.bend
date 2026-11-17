import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/x86/boot.bend as Bz

# Spec for src/x86/boot.bend: a bzImage's setup header, its placement, the
# memory map, the page tables and the boot registers.

# A setup header: setup_sects 27, version 2.15, XLF_KERNEL_64, pref_address
# 16 MiB, init_size 48 MiB, initrd_addr_max 0x7FFF_FFFF, cmdline_size 2047,
# the header ending at 0x26C.
def head() -> List<&2, U32>:
  Bz.Bz.put(Bz.Bz.put(Bz.Bz.put(Bz.Bz.put(Bz.Bz.put(B.Bytes.zeros(1024n), 497n, [27]), 510n, [85, 170, 235, 106, 72, 100, 114, 83, 15, 2]), 556n, [255, 255, 255, 127]), 566n, [1, 0, 255, 7, 0, 0]), 600n, [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3])

def info() -> Bz.BzInfo:
  Bz.BzInfo{27, 527, U.U64{0, 16777216}, 50331648, 2147483647, 2047, 620}

law x86boot.parse:
  {Bz.Bz.parse(head()) == Some{info()} : Maybe<&2, Bz.BzInfo>}

law x86boot.parse_short:
  {Bz.Bz.parse(List.take(&2, U32, head(), 1000n)) == None{} : Maybe<&2, Bz.BzInfo>}

# protocol 2.11: no 64-bit entry
law x86boot.parse_old:
  {Bz.Bz.parse(Bz.Bz.put(head(), 518n, [11, 2])) == None{} : Maybe<&2, Bz.BzInfo>}

law x86boot.parse_no64:
  {Bz.Bz.parse(Bz.Bz.put(head(), 566n, [0])) == None{} : Maybe<&2, Bz.BzInfo>}

law x86boot.setup_len:
  {Bz.Bz.setup_len(info()) == 14336 : U32}

# 2 GiB of RAM, a 10 MiB file, a 20 MiB initrd ending at 1 GiB
law x86boot.layout:
  {Bz.Bz.layout(info(), U.U64{0, 2147483648}, 10485760, 20971520) == Some{Bz.BzLayout{U.U64{0, 16762880}, U.U64{0, 16777216}, 1052770304, 20971520}} : Maybe<&2, Bz.BzLayout>}

# the initrd would overlap the kernel's init_size
law x86boot.layout_full:
  {Bz.Bz.layout(info(), U.U64{0, 83886080}, 10485760, 33554432) == None{} : Maybe<&2, Bz.BzLayout>}

law x86boot.e820_2g:
  {Bz.Bz.e820(U.U64{0, 2147483648}) == [Bz.E820{U.U64{0, 0}, U.U64{0, 654336}, 1}, Bz.E820{U.U64{0, 654336}, U.U64{0, 394240}, 2}, Bz.E820{U.U64{0, 1048576}, U.U64{0, 2146435072}, 1}] : List<&2, Bz.E820>}

law x86boot.e820_4g:
  {Bz.Bz.e820(U.U64{1, 0}) == [Bz.E820{U.U64{0, 0}, U.U64{0, 654336}, 1}, Bz.E820{U.U64{0, 654336}, U.U64{0, 394240}, 2}, Bz.E820{U.U64{0, 1048576}, U.U64{0, 3220176896}, 1}, Bz.E820{U.U64{1, 0}, U.U64{0, 1073741824}, 1}] : List<&2, Bz.E820>}

law x86boot.cmdline:
  {Bz.Bz.cmdline(Bz.BzInfo{0, 0, U.U64{0, 0}, 0, 0, 3, 0}, "abcdef") == [97, 98, 99, 0] : List<&2, U32>}

law x86boot.gdt:
  {List.length(&2, U32, Bz.Boot.gdt()) == 40n : Nat}

law x86boot.regs:
  {List.length(&2, U32, Bz.Boot.regs(16777216)) == 126n : Nat}

law x86boot.regs_rip:
  {List.take(&2, U32, Bz.Boot.regs(16777216), 4n) == [0, 16777728, 0, 28672] : List<&2, U32>}

law x86boot.cpuid_rules:
  {List.length(&2, U32, Bz.Boot.cpuid_rules()) == 20n : Nat}

law x86boot.default_console:
  {Bz.Bz.cmdline_for("console=ttyAMA0 earlycon=pl011,0x9000000") == "console=ttyS0" : String}

law x86boot.own_cmdline:
  {Bz.Bz.cmdline_for("console=ttyS0 quiet") == "console=ttyS0 quiet" : String}

# the stub writes the FADT's reset value to its reset port
law x86boot.reset_stub:
  {Bz.Boot.reset_stub() == [186, 2, 6, 176, 1, 238, 244, 235, 253] : List<&2, U32>}
