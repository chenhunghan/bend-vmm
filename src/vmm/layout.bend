import Base
import ../lib/u64.bend as U

# The guest physical memory map and the MMIO bus that routes trapped
# accesses to device models. The map follows QEMU's arm "virt" machine where
# it can, except for the GIC redistributors: Hypervisor.framework's GIC
# reserves a 32 MiB redistributor region, which at QEMU's 0x080A_0000 would
# swallow the UART and the virtio slots, so it sits at 0x0C00_0000:
#   flash bank 0       0 (0x0000_0000), 64 MiB: UEFI firmware (--firmware),
#                      host memory, read-only and executable
#   flash bank 1       67108864 (0x0400_0000), 64 MiB: UEFI variables, a
#                      CFI flash (src/dev/pflash.bend)
#   GIC distributor    134217728 (0x0800_0000), 64 KiB
#   GIC redistributors 201326592 (0x0C00_0000), 32 MiB region, 128 KiB per CPU
#   PL011 UART         150994944 (0x0900_0000), 4 KiB, SPI 1 (INTID 33)
#   PL031 RTC          151060480 (0x0901_0000), 4 KiB, SPI 2 (INTID 34)
#   virtio-mmio slots  167772160 (0x0A00_0000), 512 bytes each, 32 slots;
#                      slot n uses SPI 16 + n (INTID 48 + n)
#   framebuffer        268435456 (0x1000_0000), 16 MiB (with --display)
#   RAM                1073741824 (0x4000_0000) upward
# Every device region in a Bus must be disjoint; RAM is not on the bus (the
# host maps it, so it never traps).

def Layout.gicd_base() -> U.U64:
  U.U64{0, 134217728}

def Layout.gicr_base() -> U.U64:
  U.U64{0, 201326592}

# Size of the redistributor region Hypervisor.framework reserves (32 MiB).
def Layout.gicr_region_size() -> U.U64:
  U.U64{0, 33554432}

def Layout.uart_base() -> U.U64:
  U.U64{0, 150994944}

def Layout.uart_intid() -> U32:
  33

# PL031 RTC: 4 KiB at 0x0901_0000, SPI 2 (INTID 34).
def Layout.rtc_base() -> U.U64:
  U.U64{0, 151060480}

def Layout.rtc_intid() -> U32:
  34

# The framebuffer (--display): 16 MiB of host memory at 0x1000_0000, below
# RAM and clear of every device.
def Layout.fb_base() -> U.U64:
  U.U64{0, 268435456}

def Layout.fb_size() -> U32:
  16777216

# The two 64 MiB flash banks of a UEFI boot (--firmware).
def Layout.flash0_base() -> U.U64:
  U.U64{0, 0}

def Layout.flash1_base() -> U.U64:
  U.U64{0, 67108864}

def Layout.flash_size() -> U32:
  67108864

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
  # n * 512 as a 64-bit shift, so a large n carries into the high word.
  U.U64.add(Layout.virtio_base(), U.U64.shl(9n, U.U64{0, n}))

# INTID of virtio slot n.
def Layout.virtio_intid(n: U32) -> U32:
  (48 + n : U32)

# A device region: [base, base+size) belongs to device number dev.
type Region is Data:
  Region{base: U.U64, size: U.U64, dev: U32}

# Where an address landed: the device and the offset inside its region.
type Hit is Data:
  Hit{dev: U32, offset: U.U64}

# True when addr lies in [base, base+size). The test compares the offset
# addr - base with size, so it needs no end address and holds for a region
# that ends at 2^64.
def Bus.holds(+base: U.U64, size: U.U64, +addr: U.U64) -> Bool:
  U.U64.is_le(base, addr) && U.U64.is_lt(U.U64.sub(addr, base), size)

# Hit{dev, addr - base} when the region holds addr.
def Bus.hit(r: Region, +addr: U.U64) -> Maybe<&2, Hit>:
  match r:
    case Region{+base, size, dev}:
      Bool.pick(Maybe<&2, Hit>, Bus.holds(base, size, addr), Some{Hit{dev, U.U64.sub(addr, base)}}, None{})

# The region holding addr, if any. When regions overlap, the first one wins.
def Bus.find(regions: +List<Region>, +addr: U.U64) -> Maybe<&2, Hit>:
  match regions:
    case Nil{}:
      None{}
    case Con{r, rest}:
      Maybe.or(&2, Hit, Bus.hit(r, addr), Bus.find(rest, addr))

# True when the region ends at or below 2^64: size <= 2^64 - base, that is
# size - 1 <= not(base) for a non-empty region. An empty region never wraps.
def Bus.fits(r: Region) -> Bool:
  match r:
    case Region{base, +size, dev}:
      U.U64.is_zero(size) || U.U64.is_le(U.U64.sub(size, U.U64{0, 1}), U.U64.not(base))

# True when two regions share an address. Two non-empty regions overlap iff
# one holds the base of the other; an empty region overlaps nothing.
def Bus.overlap(a: Region, b: Region) -> Bool:
  match a b:
    case Region{+ab, +as, ad} Region{+bb, +bs, bd}:
      used = Bool.not(U.U64.is_zero(as)) && Bool.not(U.U64.is_zero(bs))
      x y = Bus.holds(ab, as, bb) Bus.holds(bb, bs, ab)
      used && (x || y)

# True when r overlaps no region of rest.
def Bus.clear(+r: Region, rest: +List<Region>) -> Bool:
  match rest:
    case Nil{}:
      True{}
    case Con{s, more}:
      Bool.not(Bus.overlap(r, s)) && Bus.clear(r, more)

# True when no two regions overlap (and no region wraps past 2^64).
def Bus.disjoint(regions: +List<Region>) -> Bool:
  match regions:
    case Nil{}:
      True{}
    case Con{+r, +rest}:
      # The head against the rest, and the rest against itself, are
      # independent.
      a b = Bus.clear(r, rest) Bus.disjoint(rest)
      Bus.fits(r) && a && b
