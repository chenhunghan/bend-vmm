import Base
import ../lib/u64.bend as U

# The guest physical memory map and the MMIO bus that routes trapped
# accesses to device models. The map follows QEMU's arm "virt" machine so
# stock arm64 kernels need nothing special:
#   GIC distributor    134217728 (0x0800_0000), 64 KiB
#   GIC redistributors 134873088 (0x080A_0000), 128 KiB per CPU
#   PL011 UART         150994944 (0x0900_0000), 4 KiB, SPI 1 (INTID 33)
#   virtio-mmio slots  167772160 (0x0A00_0000), 512 bytes each, 32 slots;
#                      slot n uses SPI 16 + n (INTID 48 + n)
#   RAM                1073741824 (0x4000_0000) upward
# Every device region in a Bus must be disjoint; RAM is not on the bus (the
# host maps it, so it never traps).

def Layout.gicd_base() -> U.U64:
  U.U64{0, 134217728}

def Layout.gicr_base() -> U.U64:
  U.U64{0, 134873088}

def Layout.uart_base() -> U.U64:
  U.U64{0, 150994944}

def Layout.uart_intid() -> U32:
  33

def Layout.virtio_base() -> U.U64:
  U.U64{0, 167772160}

def Layout.virtio_slot_size() -> U32:
  512

def Layout.virtio_slots() -> U32:
  32

def Layout.ram_base() -> U.U64:
  U.U64{0, 1073741824}

# Base address of virtio slot n.
def Layout.virtio_slot(n: U32) -> U.U64:
  ?TODO

# INTID of virtio slot n.
def Layout.virtio_intid(n: U32) -> U32:
  ?TODO

# A device region: [base, base+size) belongs to device number dev.
type Region is Data:
  Region{base: U.U64, size: U.U64, dev: U32}

# Where an address landed: the device and the offset inside its region.
type Hit is Data:
  Hit{dev: U32, offset: U.U64}

# The region holding addr, if any.
def Bus.find(regions: +List<Region>, addr: U.U64) -> Maybe<&2, Hit>:
  ?TODO

# True when no two regions overlap (and no region wraps past 2^64).
def Bus.disjoint(regions: +List<Region>) -> Bool:
  ?TODO
