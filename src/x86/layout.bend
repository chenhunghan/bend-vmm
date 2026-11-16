import Base
import ../lib/u64.bend as U
import ../vmm/layout.bend as L

# The x86_64 guest's physical memory map (KVM on a Linux x86_64 host).
# Guest RAM is one host mapping, seen by the guest in two pieces around the
# 32-bit device hole (host/hvf.c's hvf_ptr does the same arithmetic):
#   RAM low            0 .. min(size, 3 GiB): the first 3 GiB of RAM
#   virtio-mmio slots  3489660928 (0xD000_0000), 512 bytes each, 32 slots
#   IOAPIC             4273995776 (0xFEC0_0000) (KVM's, in the kernel)
#   local APICs        4276092928 (0xFEE0_0000) (KVM's, in the kernel)
#   RAM high           4294967296 (0x1_0000_0000) upward: RAM past 3 GiB
# Inside low RAM, the boot structures (X86.zero_page and the rest below),
# the ACPI tables at 917504 (0xE_0000), the kernel at its preferred address
# (the setup header's pref_address, 16 MiB on every kernel since 2.6.31).
#
# The machine (src/vmm/machine.bend) decodes the arm64 map: a trapped
# access to virtio slot n here becomes one to L.Layout.virtio_slot(n)
# (X86.to_bus), and its interrupt (L.Layout.virtio_intid(n)) goes to the
# IOAPIC pin X86.gsi_of says.

# 3 GiB (0xC000_0000): low RAM ends here at most.
def X86.low_max() -> U.U64:
  U.U64{0, 3221225472}

# 4 GiB: RAM past low_max continues here.
def X86.high_base() -> U.U64:
  U.U64{1, 0}

# Low RAM: [0, min(size, 3 GiB)).
def X86.low_size(+size: U.U64) -> U.U64:
  Bool.pick(U.U64, U.U64.is_lt(size, X86.low_max()), size, X86.low_max())

# RAM past 3 GiB, mapped at 4 GiB (0 when RAM fits below).
def X86.high_size(+size: U.U64) -> U.U64:
  U.U64.sub(size, X86.low_size(size))

def X86.virtio_base() -> U.U64:
  U.U64{0, 3489660928}

# Base address of virtio slot n (512 bytes each).
def X86.virtio_slot(n: U32) -> U.U64:
  U.U64.add(X86.virtio_base(), U.U64.shl(9n, U.U64{0, n}))

def X86.ioapic_base() -> U32:
  4273995776

def X86.lapic_base() -> U32:
  4276092928

# A trapped guest address as the machine's bus sees it: the virtio slots
# move to L.Layout.virtio_base(); any other address goes to the machine's
# "no device" (0, which no bus device holds).
def X86.to_bus(+gpa: U.U64) -> U.U64:
  +off = U.U64.sub(gpa, X86.virtio_base())
  +span = U.U64.shl(9n, U.U64{0, L.Layout.virtio_slots()})
  Bool.pick(U.U64, L.Bus.holds(X86.virtio_base(), span, gpa), U.U64.add(L.Layout.virtio_base(), off), U.U64.zero())

# IOAPIC pins (GSIs) for the virtio slots: the ISA lines no legacy device
# here uses (0 timer, 1 keyboard, 2 cascade, 3 and 4 serial, 8 CMOS clock,
# 9 ACPI SCI are taken), then 16..23. 17 slots get a line; the others none.
def X86.virtio_gsis() -> +List<U32>:
  [5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]

# The COM1 16550's line.
def X86.uart_gsi() -> U32:
  4

# 255: no line.
def X86.no_gsi() -> U32:
  255

# The GSI of virtio slot n, or no_gsi.
def X86.slot_gsi(n: U32) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, X86.virtio_gsis(), U32.to_nat(n)), X86.no_gsi())

# How many virtio slots have a line.
def X86.slots_with_lines() -> U32:
  U32.from_nat(List.length(&2, U32, X86.virtio_gsis()))

# The machine's interrupt numbers (INTIDs) as IOAPIC pins: the table the
# host keeps (Hvf.x86_setup), indexed by INTID 0..79: L.Layout.uart_intid()
# is the 16550's line (X86.uart_gsi), virtio slot n's INTID is its GSI,
# everything else no_gsi.
def X86.gsi_at(+intid: U32) -> U32:
  +slot = (intid - L.Layout.virtio_intid(0) : U32)
  Bool.pick(U32, U32.is_eq(intid, L.Layout.uart_intid()), X86.uart_gsi(),
    Bool.pick(U32, U32.is_ge(intid, L.Layout.virtio_intid(0)), X86.slot_gsi(slot), X86.no_gsi()))

def X86.gsi_table.go(n: Nat, +i: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      X86.gsi_at(i) <> X86.gsi_table.go(p, (i + 1 : U32))

def X86.gsi_table() -> +List<U32>:
  X86.gsi_table.go(80n, 0)

# Boot structures in low RAM (decimal; hex in comments).
#   GDT 1280 (0x500), the zero page (boot_params) 28672 (0x7000),
#   the boot stack's top 36848 (0x8FF0),
#   page tables: PML4 36864 (0x9000), PDPT 40960 (0xA000), PD 45056 (0xB000),
#   the command line 131072 (0x2_0000), the ACPI tables 917504 (0xE_0000).
def X86.gdt() -> U32:
  1280

def X86.zero_page() -> U32:
  28672

def X86.stack_top() -> U32:
  36848

def X86.pml4() -> U32:
  36864

def X86.pdpt() -> U32:
  40960

def X86.pd() -> U32:
  45056

def X86.cmdline() -> U32:
  131072

def X86.acpi() -> U32:
  917504

# The legacy hole: [654336, 1048576) (0x9_FC00 .. 0x10_0000) is not RAM to
# the guest (the EBDA, the VGA window, the BIOS area with the ACPI tables).
def X86.ebda() -> U32:
  654336

def X86.mib1() -> U32:
  1048576

# KVM's own pieces of the machine, as the words Hvf.x86_setup takes: RAM's
# low end and high base (hi, lo each: X86.low_max, X86.high_base), where
# VMX's identity-map page (4278173696, 0xFEFF_C000) and its three TSS pages
# (4278177792, 0xFEFF_D000) go (in the hole below 4 GiB, clear of the
# IOAPIC and the local APICs), the local APIC's LINT0 delivery mode
# (7 ExtINT: the PIC's line, as a PC's firmware leaves it) and LINT1's
# (4 NMI), and the PIT's flags (1: KVM_PIT_SPEAKER_DUMMY, port 0x61 is
# KVM's).
def X86.kvm_words() -> +List<U32>:
  [0, 3221225472, 1, 0, 4278173696, 4278177792, 7, 4, 1]

# What an x86_64 snapshot keeps (Hvf.snap_plans), in the order a restore
# applies it. Per vCPU: the registers (1), the FPU and vector state (3,
# XSAVE), XCR0 (4), the segment and control registers (2: after the
# registers, before the MSRs that depend on EFER), the local APIC (6: after
# the APIC base in 2, before the MSRs: KVM drops a TSC deadline written
# while the APIC timer is not in TSC-deadline mode, and the restored timer
# would never fire), the MSRs KVM lists (5), the run state (7: an AP
# waiting for its SIPI stays waiting), pending events (8), the debug
# registers (9). For the VM: the PICs (20, 21), the IOAPIC (22), the PIT
# (23), KVM's clock (24: kvmclock goes on from where it was), the port
# machine (25, src/x86/pio.bend's Pio.saved).
def X86.cpu_plan() -> +List<U32>:
  [1, 3, 4, 2, 6, 5, 7, 8, 9]

def X86.vm_plan() -> +List<U32>:
  [20, 21, 22, 23, 24, 25]
