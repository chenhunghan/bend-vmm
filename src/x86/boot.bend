import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ./layout.bend as X

# Booting an x86_64 Linux bzImage straight into its 64-bit entry (Linux
# Documentation/arch/x86/boot.rst, "64-bit Boot Protocol"): the VMM loads
# the protected-mode kernel at its preferred address, fills a zero page
# (struct boot_params) with the setup header, the command line, the initrd
# and the memory map (e820), identity-maps the first GiB, and starts the
# boot vCPU in long mode at the kernel's address + 512 with RSI pointing at
# the zero page.
#
# The setup header, at these offsets of the file and of the zero page
# (decimal; hex in comments):
#   497 (0x1F1) setup_sects u8 (0 means 4)   510 (0x1FE) boot_flag u16 0xAA55
#   513 (0x201) the jump's offset: the header ends at 514 + this byte
#   514 (0x202) "HdrS"                       518 (0x206) version u16
#   528 (0x210) type_of_loader u8            529 (0x211) loadflags u8
#   536 (0x218) ramdisk_image u32            540 (0x21C) ramdisk_size u32
#   552 (0x228) cmd_line_ptr u32             556 (0x22C) initrd_addr_max u32
#   560 (0x230) kernel_alignment u32         566 (0x236) xloadflags u16
#   568 (0x238) cmdline_size u32             600 (0x258) pref_address u64
#   608 (0x260) init_size u32
# Elsewhere in the zero page: 112 (0x070) acpi_rsdp_addr u64, 488 (0x1E8)
# e820_entries u8, 720 (0x2D0) the e820 table (20-byte entries: addr u64,
# size u64, type u32).

type BzInfo is Data:
  BzInfo{setup_sects: U32, version: U32, pref: U.U64, init_size: U32, initrd_max: U32, cmdline_size: U32, hdr_end: U32}

def Bz.u8(bs: +List<U32>, off: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, bs, off), 0)

def Bz.u16(bs: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_le16(B.Bytes.slice(bs, off, 2n))

def Bz.u32(bs: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_le32(B.Bytes.slice(bs, off, 4n))

# The header bytes a parse needs (the file's first 1024).
def Bz.head_len() -> U32:
  1024

# 0xAA55, "HdrS" (0x5372_6448), version 2.12 (0x020C: the 64-bit entry).
def Bz.boot_flag() -> U32:
  43605

def Bz.magic() -> U32:
  1400005704

def Bz.min_version() -> U32:
  524

def Bz.sects(+n: U32) -> U32:
  Bool.pick(U32, U32.is_zero(n), 4, n)

def Bz.when(-A: Data, ok: Bool, x: A) -> Maybe<&2, A>:
  match ok:
    case True{}:
      Some{x}
    case False{}:
      None{}

def Bz.parse.go(+bs: +List<U32>) -> Maybe<&2, BzInfo>:
  +version = Bz.u16(bs, 518n)
  ok = U32.is_eq(Bz.u16(bs, 510n), Bz.boot_flag()) && U32.is_eq(Bz.u32(bs, 514n), Bz.magic())
    && U32.is_ge(version, Bz.min_version()) && U32.is_ne((Bz.u16(bs, 566n) .&. 1 : U32), 0)
  info : BzInfo = BzInfo{Bz.sects(Bz.u8(bs, 497n)), version, B.Bytes.read_le64(B.Bytes.slice(bs, 600n, 8n)), Bz.u32(bs, 608n), Bz.u32(bs, 556n), Bz.u32(bs, 568n), (514 + Bz.u8(bs, 513n) : U32)}
  Bz.when(BzInfo, ok, info)

# A bzImage whose kernel has a 64-bit entry (protocol 2.12 or later with
# XLF_KERNEL_64), from the file's first 1024 bytes; None for anything else.
def Bz.parse(+bs: +List<U32>) -> Maybe<&2, BzInfo>:
  Bool.pick(Maybe<&2, BzInfo>, Nat.is_le(1024n, List.length(&2, U32, bs)), Bz.parse.go(bs), None{})

# The file's bytes before the protected-mode kernel: (setup_sects + 1) * 512.
def Bz.setup_len(info: BzInfo) -> U32:
  match info:
    case BzInfo{s, v, p, i, r, c, h}:
      ((s + 1 : U32) << 9n : U32)

def Bz.pref(info: BzInfo) -> U.U64:
  match info:
    case BzInfo{s, v, p, i, r, c, h}:
      p

# Where everything goes: the file is loaded whole at kernel - setup_len, so
# the protected-mode kernel lands at its preferred address; the initrd ends
# at a 4 KiB boundary at or below the lowest of low RAM's end, the kernel's
# initrd_addr_max + 1 and 1 GiB (the identity map), clear of the kernel's
# init_size.
type BzLayout is Data:
  BzLayout{load: U.U64, kernel: U.U64, initrd: U32, initrd_len: U32}

def Bz.min(+a: U32, +b: U32) -> U32:
  Bool.pick(U32, U32.is_lt(a, b), a, b)

def Bz.gib1() -> U32:
  1073741824

# The initrd's top: min(low RAM's end, initrd_addr_max + 1, 1 GiB), 4 KiB
# aligned down.
def Bz.initrd_top(+low_end: U32, +max: U32) -> U32:
  +cap = Bool.pick(U32, U32.is_eq(max, 4294967295), max, (max + 1 : U32))
  (Bz.min(Bz.min(low_end, cap), Bz.gib1()) .&. 4294963200 : U32)

# The placement for a file of flen bytes and an initrd of ilen bytes in
# RAM of size bytes; None when it does not fit.
def Bz.layout(info: BzInfo, +size: U.U64, +flen: U32, +ilen: U32) -> Maybe<&2, BzLayout>:
  match info:
    case BzInfo{+s, v, +pref, +init, +max, c, h}:
      +setup = ((s + 1 : U32) << 9n : U32)
      +low = U.U64.lo(X.X86.low_size(size))
      +kernel = U.U64.lo(pref)
      +kend = (kernel + init : U32)
      +top = Bz.initrd_top(low, max)
      +rd = ((top - ilen : U32) .&. 4294963200 : U32)
      +fits_k = U.U64.is_zero(U.U64{U.U64.hi(pref), 0}) && U32.is_ge(kernel, (X.X86.mib1() + setup : U32))
        && U32.is_ge(kend, kernel) && U32.is_le(kend, low) && U32.is_ge(init, (flen - setup : U32))
      +fits_rd = U32.is_ge(top, ilen) && U32.is_ge(rd, kend)
      Bz.when(BzLayout, fits_k && fits_rd && U32.is_ge(flen, setup), BzLayout{U.U64{0, (kernel - setup : U32)}, pref, rd, ilen})

# The memory map (e820 entries: base, size, type 1 RAM or 2 reserved) for
# RAM of size bytes: low RAM below the legacy hole, the hole (the EBDA,
# VGA, the BIOS area with the ACPI tables), the rest of low RAM from 1 MiB,
# and RAM past 3 GiB at 4 GiB.
type E820 is Data:
  E820{base: U.U64, size: U.U64, kind: U32}

def Bz.e820(+size: U.U64) -> +List<E820>:
  +low = X.X86.low_size(size)
  +high = X.X86.high_size(size)
  +rest = U.U64.sub(low, U.U64{0, X.X86.mib1()})
  +hole = (X.X86.mib1() - X.X86.ebda() : U32)
  base : +List<E820> = [E820{U.U64.zero(), U.U64{0, X.X86.ebda()}, 1}, E820{U.U64{0, X.X86.ebda()}, U.U64{0, hole}, 2}, E820{U.U64{0, X.X86.mib1()}, rest, 1}]
  List.append(&2, E820, base, Bool.pick(+List<E820>, U.U64.is_zero(high), [], [E820{X.X86.high_base(), high, 1}]))

def Bz.e820_bytes(es: +List<E820>) -> +List<U32>:
  match es:
    case Nil{}:
      []
    case Con{E820{b, s, k}, rest}:
      List.append(&2, U32, B.Bytes.le64(b), List.append(&2, U32, B.Bytes.le64(s), List.append(&2, U32, B.Bytes.le32(k), Bz.e820_bytes(rest))))

# bs with the bytes at off replaced by put (bs is long enough).
def Bz.put(+bs: +List<U32>, +off: Nat, +put: +List<U32>) -> +List<U32>:
  List.append(&2, U32, List.take(&2, U32, bs, off), List.append(&2, U32, put, List.drop(&2, U32, bs, Nat.add(off, List.length(&2, U32, put)))))

# The zero page (4096 bytes): the file's setup header (bytes 497 up to its
# end), type_of_loader 0xFF (undefined), the command line, the initrd, the
# RSDP's address and the memory map.
def Bz.zero_page(info: BzInfo, +head: +List<U32>, +size: U.U64, +lay: BzLayout, +rsdp: U32) -> +List<U32>:
  match info lay:
    case BzInfo{s, v, p, i, r, c, +hend} BzLayout{ld, k, +rd, +rdlen}:
      +es = Bz.e820(size)
      +hdr = B.Bytes.slice(head, 497n, U32.to_nat((hend - 497 : U32)))
      +z0 = Bz.put(B.Bytes.zeros(4096n), 497n, hdr)
      +z1 = Bz.put(z0, 528n, [255])
      +z2 = Bz.put(z1, 536n, List.append(&2, U32, B.Bytes.le32(rd), B.Bytes.le32(rdlen)))
      +z3 = Bz.put(z2, 552n, B.Bytes.le32(X.X86.cmdline()))
      +z4 = Bz.put(z3, 112n, B.Bytes.le64(U.U64{0, rsdp}))
      +z5 = Bz.put(z4, 488n, [U32.from_nat(List.length(&2, E820, es))])
      Bz.put(z5, 720n, Bz.e820_bytes(es))

# The command line as the kernel reads it: NUL-terminated, cut to the
# header's cmdline_size (a protocol 2.06+ field: every 64-bit kernel has it).
def Bz.cmdline(info: BzInfo, s: String) -> +List<U32>:
  match info:
    case BzInfo{st, v, p, i, r, +c, h}:
      List.append(&2, U32, List.take(&2, U32, B.Bytes.of_string(s), U32.to_nat(c)), [0])

# The GDT at X86.gdt(): null, null, the 64-bit code segment (selector 16,
# __BOOT_CS: 0x00AF_9B00_0000_FFFF), the data segment (selector 24,
# __BOOT_DS: 0x00CF_9300_0000_FFFF), and a 64-bit TSS (selector 32,
# 0x0000_8B00_0000_0067) for the task register VMX insists on.
def Boot.gdt() -> +List<U32>:
  List.append(&2, U32, B.Bytes.zeros(16n), [255, 255, 0, 0, 0, 155, 175, 0, 255, 255, 0, 0, 0, 147, 207, 0, 103, 0, 0, 0, 0, 139, 0, 0])

# Page tables: PML4[0] -> the PDPT, PDPT[0] -> the PD, and the PD maps the
# first GiB in 2 MiB pages (present, writable, large: 0x83).
def Boot.entry(+addr: U32) -> +List<U32>:
  B.Bytes.le64(U.U64{0, (addr .|. 3 : U32)})

def Boot.pml4() -> +List<U32>:
  List.append(&2, U32, Boot.entry(X.X86.pdpt()), B.Bytes.zeros(4088n))

def Boot.pdpt() -> +List<U32>:
  List.append(&2, U32, Boot.entry(X.X86.pd()), B.Bytes.zeros(4088n))

def Boot.pd.go(n: Nat, +i: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, B.Bytes.le64(U.U64{0, ((i << 21n : U32) .|. 131 : U32)}), Boot.pd.go(p, (i + 1 : U32)))

def Boot.pd() -> +List<U32>:
  Boot.pd.go(512n, 0)

# The boot vCPU's registers, as the words Hvf.x86_boot takes (64-bit
# values as hi, lo): rip, rsi, rsp, rflags, cr0, cr3, cr4, efer, the GDT's
# base and limit, the IDT's base and limit, then the segments cs, ds, es,
# fs, gs, ss, tr, ldt, each as base (hi, lo), limit, selector, type,
# present, dpl, db, s, l, g, avl, unusable.
#   cr0 = PG | ET | PE (0x8000_0011), cr4 = PAE (0x20), efer = LME | LMA
#   (0x500), cr3 = the PML4, rflags = 2 (the reserved bit), RSI = the zero
#   page, RIP = the kernel + 512 (startup_64).
def Boot.u64(+x: U32) -> +List<U32>:
  [0, x]

def Boot.seg(+sel: U32, +ty: U32, +s: U32, +l: U32, +db: U32, +limit: U32, +g: U32, +unusable: U32) -> +List<U32>:
  [0, 0, limit, sel, ty, Bool.to_u32(U32.is_zero(unusable)), 0, db, s, l, g, 0, unusable]

def Boot.code() -> +List<U32>:
  Boot.seg(16, 11, 1, 1, 0, 4294967295, 1, 0)

def Boot.data() -> +List<U32>:
  Boot.seg(24, 3, 1, 0, 1, 4294967295, 1, 0)

def Boot.regs(+kernel: U32) -> +List<U32>:
  +d = Boot.data()
  +head = List.append(&2, U32, Boot.u64((kernel + 512 : U32)), List.append(&2, U32, Boot.u64(X.X86.zero_page()), List.append(&2, U32, Boot.u64(X.X86.stack_top()), Boot.u64(2))))
  +ctl = List.append(&2, U32, Boot.u64(2147483665), List.append(&2, U32, Boot.u64(X.X86.pml4()), List.append(&2, U32, Boot.u64(32), Boot.u64(1280))))
  +tables = List.append(&2, U32, Boot.u64(X.X86.gdt()), [39, 0, 0, 0])
  +segs = List.append(&2, U32, Boot.code(), List.append(&2, U32, d, List.append(&2, U32, d, List.append(&2, U32, d, List.append(&2, U32, d, List.append(&2, U32, d, List.append(&2, U32, Boot.seg(32, 11, 0, 0, 0, 103, 0, 0), Boot.seg(0, 2, 0, 0, 0, 65535, 0, 1))))))))
  List.append(&2, U32, head, List.append(&2, U32, ctl, List.append(&2, U32, tables, segs)))

# CPUID: rules the host applies to every leaf KVM supports (Hvf.x86_setup),
# five words each: leaf, register (0 eax, 1 ebx, 2 ecx, 3 edx), bits to
# clear, bits to set, and the shift at which the vCPU's index (its APIC ID)
# goes in (32: none). The index of a subleaf does not matter.
#   leaf 1 ECX bit 31: a hypervisor runs this CPU
#   leaf 1 EBX bits 31..24: the initial APIC ID
#   leaf 11 (0xB) and 31 (0x1F) EDX: the x2APIC ID
def Boot.cpuid_rules() -> +List<U32>:
  [1, 2, 0, 2147483648, 32, 1, 1, 4278190080, 0, 24, 11, 3, 4294967295, 0, 0, 31, 3, 4294967295, 0, 0]
