import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ./layout.bend as X

# The ACPI tables of an x86_64 guest (ACPI 6.x), all at X86.acpi() in the
# BIOS area: the RSDP, the XSDT, a FADT for hardware-reduced ACPI, the MADT
# (the local APICs, the IOAPIC, the interrupt overrides) and a DSDT (the
# virtio-mmio devices and the \_S5 sleep type). No PCI, no SCI events: the
# guest powers off and resets through the FADT's sleep control and reset
# registers, ports the port machine (src/x86/pio.bend) answers:
#   sleep control 1536 (0x600): SLP_EN (32) | SLP_TYP 5 << 2: power off
#   sleep status  1537 (0x601)
#   reset         1538 (0x602): the reset value 1 resets
# Each table: the 36-byte header (signature, length, revision, checksum,
# OEM "BENDVM", table "BENDVMM ", revision 1, creator "BEND" revision 1),
# bytes summing to 0 mod 256.

def Acpi.sleep_port() -> U32:
  1536

def Acpi.status_port() -> U32:
  1537

def Acpi.reset_port() -> U32:
  1538

def Acpi.reset_value() -> U32:
  1

def Acpi.s5() -> U32:
  5

def Acpi.sum(bs: +List<U32>) -> U32:
  match bs:
    case Nil{}:
      0
    case Con{b, rest}:
      ((b + Acpi.sum(rest) : U32) .&. 255 : U32)

# The byte that makes bs sum to 0.
def Acpi.fix(+bs: +List<U32>) -> U32:
  ((256 - Acpi.sum(bs) : U32) .&. 255 : U32)

def Acpi.str(s: String) -> +List<U32>:
  B.Bytes.of_string(s)

# bs with byte off set to v (bs is long enough).
def Acpi.set(+bs: +List<U32>, +off: Nat, v: U32) -> +List<U32>:
  List.append(&2, U32, List.take(&2, U32, bs, off), v <> List.drop(&2, U32, bs, Nat.add(off, 1n)))

# A table: header (checksum at byte 9 fixed last) then the body.
def Acpi.table(sig: String, rev: U32, +body: +List<U32>) -> +List<U32>:
  +len = (36 + U32.from_nat(List.length(&2, U32, body)) : U32)
  +h = List.append(&2, U32, Acpi.str(sig), List.append(&2, U32, B.Bytes.le32(len), [rev, 0]))
  +oem = List.append(&2, U32, Acpi.str("BENDVM"), List.append(&2, U32, Acpi.str("BENDVMM "), List.append(&2, U32, B.Bytes.le32(1), List.append(&2, U32, Acpi.str("BEND"), B.Bytes.le32(1)))))
  +t = List.append(&2, U32, h, List.append(&2, U32, oem, body))
  Acpi.set(t, 9n, Acpi.fix(t))

# A generic address structure for an 8-bit IO port.
def Acpi.gas_io(+port: U32) -> +List<U32>:
  List.append(&2, U32, [1, 8, 0, 1], B.Bytes.le64(U.U64{0, port}))

# The RSDP (revision 2, 36 bytes): its first 20 bytes sum to 0, and so do
# all 36.
def Acpi.rsdp(+xsdt: U32) -> +List<U32>:
  +a = List.append(&2, U32, Acpi.str("RSD PTR "), List.append(&2, U32, [0], List.append(&2, U32, Acpi.str("BENDVM"), List.append(&2, U32, [2], B.Bytes.le32(0)))))
  +a1 = Acpi.set(a, 8n, Acpi.fix(a))
  +b = List.append(&2, U32, a1, List.append(&2, U32, B.Bytes.le32(36), List.append(&2, U32, B.Bytes.le64(U.U64{0, xsdt}), [0, 0, 0, 0])))
  Acpi.set(b, 32n, Acpi.fix(b))

def Acpi.ptrs(ps: +List<U32>) -> +List<U32>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      List.append(&2, U32, B.Bytes.le64(U.U64{0, p}), Acpi.ptrs(rest))

def Acpi.xsdt(ps: +List<U32>) -> +List<U32>:
  Acpi.table("XSDT", 1, Acpi.ptrs(ps))

# The FADT (revision 6, 276 bytes): DSDT and X_DSDT, CENTURY 50 (the CMOS
# century register), IAPC_BOOT_ARCH "no
# VGA" (4) and "MSI not supported" (8), flags WBINVD (1), no fixed power
# (16) and sleep (32) buttons, RESET_REG_SUP (1024), HW_REDUCED_ACPI
# (1 << 20); the reset register and value; the sleep control and status
# registers.
def Acpi.fadt(+dsdt: U32) -> +List<U32>:
  +a = List.append(&2, U32, B.Bytes.le32(0), List.append(&2, U32, B.Bytes.le32(dsdt), B.Bytes.zeros(64n)))
  +b = List.append(&2, U32, a, List.append(&2, U32, [50], List.append(&2, U32, B.Bytes.le16(12), List.append(&2, U32, [0], B.Bytes.le32(1049649)))))
  +c = List.append(&2, U32, b, List.append(&2, U32, Acpi.gas_io(Acpi.reset_port()), List.append(&2, U32, [Acpi.reset_value(), 0, 0, 0], B.Bytes.le64(U.U64.zero()))))
  +d = List.append(&2, U32, c, List.append(&2, U32, B.Bytes.le64(U.U64{0, dsdt}), B.Bytes.zeros(96n)))
  +e = List.append(&2, U32, d, List.append(&2, U32, Acpi.gas_io(Acpi.sleep_port()), List.append(&2, U32, Acpi.gas_io(Acpi.status_port()), Acpi.str("BENDVMM_"))))
  Acpi.table("FACP", 6, e)

# MADT entries: a local APIC per vCPU (enabled), the IOAPIC (id ncpus, GSI
# base 0), the overrides (ISA IRQ 0 to GSI 2; SCI 9 and each virtio ISA
# line level-triggered, active-high: flags 13), LINT1 as NMI on every CPU.
def Acpi.lapics(n: Nat, +i: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, [0, 8, i, i, 1, 0, 0, 0], Acpi.lapics(p, (i + 1 : U32)))

def Acpi.iso(+irq: U32, +gsi: U32, +flags: U32) -> +List<U32>:
  List.append(&2, U32, [2, 10, 0, irq], List.append(&2, U32, B.Bytes.le32(gsi), B.Bytes.le16(flags)))

def Acpi.level_isos(gs: +List<U32>) -> +List<U32>:
  match gs:
    case Nil{}:
      []
    case Con{+g, rest}:
      List.append(&2, U32, Bool.pick(+List<U32>, U32.is_lt(g, 16), Acpi.iso(g, g, 13), []), Acpi.level_isos(rest))

def Acpi.madt(+cpus: U32) -> +List<U32>:
  +head = List.append(&2, U32, B.Bytes.le32(X.X86.lapic_base()), B.Bytes.le32(1))
  +io = List.append(&2, U32, [1, 12, cpus, 0], List.append(&2, U32, B.Bytes.le32(X.X86.ioapic_base()), B.Bytes.le32(0)))
  +isos = List.append(&2, U32, Acpi.iso(0, 2, 0), List.append(&2, U32, Acpi.iso(9, 9, 13), Acpi.level_isos(X.X86.virtio_gsis())))
  +nmi : +List<U32> = [4, 6, 255, 0, 0, 1]
  Acpi.table("APIC", 5, List.append(&2, U32, head, List.append(&2, U32, Acpi.lapics(U32.to_nat(cpus), 0), List.append(&2, U32, io, List.append(&2, U32, isos, nmi)))))

# AML. A package length counts its own bytes: one when the whole is under
# 64, two under 4096, three under 2^20.
def Aml.pkg(+n: U32) -> +List<U32>:
  Bool.pick(+List<U32>, U32.is_lt((n + 1 : U32), 64), [(n + 1 : U32)],
    Bool.pick(+List<U32>, U32.is_lt((n + 2 : U32), 4096), [(64 .|. ((n + 2 : U32) .&. 15) : U32), ((n + 2 : U32) >> 4n : U32)],
      [(128 .|. ((n + 3 : U32) .&. 15) : U32), (((n + 3 : U32) >> 4n : U32) .&. 255 : U32), ((n + 3 : U32) >> 12n : U32)]))

# op, then the package length, then body.
def Aml.wrap(+op: +List<U32>, +body: +List<U32>) -> +List<U32>:
  List.append(&2, U32, op, List.append(&2, U32, Aml.pkg(U32.from_nat(List.length(&2, U32, body))), body))

# Name(seg, data).
def Aml.name(seg: String, +data: +List<U32>) -> +List<U32>:
  List.append(&2, U32, [8], List.append(&2, U32, Acpi.str(seg), data))

def Aml.byte(+v: U32) -> +List<U32>:
  [10, v]

def Aml.string(s: String) -> +List<U32>:
  List.append(&2, U32, [13], List.append(&2, U32, Acpi.str(s), [0]))

def Aml.buffer(+bs: +List<U32>) -> +List<U32>:
  Aml.wrap([17], List.append(&2, U32, Aml.byte(U32.from_nat(List.length(&2, U32, bs))), bs))

# Name(_S5_, Package(2) {5, 0}).
def Aml.s5() -> +List<U32>:
  Aml.name("_S5_", Aml.wrap([18], [2, 10, Acpi.s5(), 0]))

def Aml.hex(+d: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 10), (48 + d : U32), (55 + d : U32))

# The device V0nn of slot n (n < 256, two hex digits).
def Aml.seg(+n: U32) -> String:
  String.from_list([Char.from_u32(86), Char.from_u32(48), Char.from_u32(Aml.hex((n >> 4n : U32))), Char.from_u32(Aml.hex((n .&. 15 : U32)))])

# Memory32Fixed(ReadWrite, base, 512), Interrupt(ResourceConsumer, Level,
# ActiveHigh, Exclusive) {gsi}, the end tag.
def Aml.crs(+base: U32, +gsi: U32) -> +List<U32>:
  +mem = List.append(&2, U32, [134, 9, 0, 1], List.append(&2, U32, B.Bytes.le32(base), B.Bytes.le32(512)))
  +irq = List.append(&2, U32, [137, 6, 0, 1, 1], B.Bytes.le32(gsi))
  List.append(&2, U32, mem, List.append(&2, U32, irq, [121, 0]))

# Device (V0nn) { _HID "LNRO0005" (virtio-mmio), _UID n, _CRS }.
def Aml.virtio(+n: U32) -> +List<U32>:
  +body = List.append(&2, U32, Acpi.str(Aml.seg(n)), List.append(&2, U32, Aml.name("_HID", Aml.string("LNRO0005")), List.append(&2, U32, Aml.name("_UID", Aml.byte(n)), Aml.name("_CRS", Aml.buffer(Aml.crs(U.U64.lo(X.X86.virtio_slot(n)), X.X86.slot_gsi(n)))))))
  Aml.wrap([91, 130], body)

def Aml.virtios(k: Nat, +n: U32) -> +List<U32>:
  match k:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Aml.virtio(n), Aml.virtios(p, (n + 1 : U32)))

# The DSDT: \_S5 and Scope (\_SB_) { the first nslots virtio devices }.
def Acpi.dsdt(+nslots: U32) -> +List<U32>:
  +sb = Aml.wrap([16], List.append(&2, U32, [92, 95, 83, 66, 95], Aml.virtios(U32.to_nat(nslots), 0)))
  Acpi.table("DSDT", 2, List.append(&2, U32, Aml.s5(), sb))

def Acpi.len(bs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

def Acpi.pad16(+bs: +List<U32>) -> +List<U32>:
  B.Bytes.pad(4n, bs)

# Every table, laid out from base (16-byte aligned): RSDP, XSDT, FADT,
# MADT, DSDT, each padded to 16 bytes. The RSDP is at base.
def Acpi.tables(+base: U32, +cpus: U32, +nslots: U32) -> +List<U32>:
  +dsdt = Acpi.pad16(Acpi.dsdt(nslots))
  +madt = Acpi.pad16(Acpi.madt(cpus))
  +fadt_at = (base + 112 : U32)
  +fadt = Acpi.pad16(Acpi.fadt((fadt_at + (Acpi.len(B.Bytes.zeros(288n)) + Acpi.len(madt) : U32) : U32)))
  +madt_at = (fadt_at + Acpi.len(fadt) : U32)
  +xsdt = Acpi.pad16(Acpi.xsdt([fadt_at, madt_at]))
  +rsdp = Acpi.pad16(Acpi.rsdp((base + 48 : U32)))
  List.append(&2, U32, rsdp, List.append(&2, U32, xsdt, List.append(&2, U32, fadt, List.append(&2, U32, madt, dsdt))))
