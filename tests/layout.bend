import Base
import ../src/lib/u64.bend as U
import ../src/vmm/layout.bend as L
import ./t.bend as T

# Tests for src/vmm/layout.bend beyond its laws. Addresses are decimal with
# their hex in the comment.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def h(a: U.U64) -> String:
  U.U64.show_hex(a)

def b(x: Bool) -> String:
  match x:
    case True{}:
      "T"
    case False{}:
      "F"

def show(m: Maybe<&2, L.Hit>) -> String:
  match m:
    case None{}:
      "None"
    case Some{L.Hit{dev, off}}:
      "Hit " ++ U32.show(dev) ++ " " ++ h(off)

def r(base: U.U64, size: U.U64, dev: U32) -> L.Region:
  L.Region{base, size, dev}

# The top of the address space: 0xFFFF_FFFF_FFFF_FF00.
def top() -> U.U64:
  U.U64{4294967295, 4294967040}

# The whole device map: GICD (0), GICR (1), UART (2), then the 32 virtio slots
# (3..34).
def slots(n: Nat) -> +List<L.Region>:
  match n:
    case 0n:
      []
    case 1n+p:
      +p = p
      +i = U32.from_nat(p)
      r(L.Layout.virtio_slot(i), w(L.Layout.virtio_slot_size()), (i + 3 : U32)) <> slots(p)

def machine() -> +List<L.Region>:
  r(L.Layout.gicd_base(), w(65536), 0) <> r(L.Layout.gicr_base(), L.Layout.gicr_region_size(), 1) <> r(L.Layout.uart_base(), w(4096), 2) <> slots(32n)

def find(rs: +List<L.Region>, a: U.U64) -> String:
  show(L.Bus.find(rs, a))

def main() -> IO(Unit):
  do IO<Unit>:
    # Slot addresses and INTIDs.
    T.eq_str("slot 1", h(L.Layout.virtio_slot(1)), "0xa000200")
    T.eq_str("slot 31", h(L.Layout.virtio_slot(31)), "0xa003e00")
    # n * 512 past 2^32 carries into the high word: 2^23 * 512 = 2^32.
    T.eq_str("slot carries", h(L.Layout.virtio_slot(8388608)), "0x10a000000")
    T.eq_u32("intid 0", L.Layout.virtio_intid(0), 48)
    T.eq_u32("intid 31", L.Layout.virtio_intid(31), 79)
    T.eq_u32("intid is spi 16+n", L.Layout.virtio_intid(1), 49)
    # Find: the first byte, the last byte and the bytes around a region.
    T.eq_str("find base", find(machine(), L.Layout.uart_base()), "Hit 2 0x0")
    # 0x0900_0FFF
    T.eq_str("find last byte", find(machine(), w(150999039)), "Hit 2 0xfff")
    # 0x08FF_FFFF
    T.eq_str("find below", find(machine(), w(150994943)), "None")
    T.eq_str("find empty", find([], w(0)), "None")
    # 0x0A00_3FFF: last byte of slot 31
    T.eq_str("find slot 31", find(machine(), w(167788543)), "Hit 34 0x1ff")
    # 0x0A00_4000: one past slot 31
    T.eq_str("find past slots", find(machine(), w(167788544)), "None")
    # 0x0DFF_FFFF: last byte of the redistributor region
    T.eq_str("find gicr end", find(machine(), w(234881023)), "Hit 1 0x1ffffff")
    T.eq_str("find gicr out", find(machine(), w(234881024)), "None")
    T.eq_str("find ram", find(machine(), L.Layout.ram_base()), "None")
    # A region that ends exactly at 2^64.
    T.eq_str("find at 2^64-1", find([r(top(), w(256), 7)], U.U64{4294967295, 4294967295}), "Hit 7 0xff")
    # A region whose end wraps holds no low addresses.
    T.eq_str("find wrap low", find([r(top(), w(512), 7)], w(16)), "None")
    # An empty region holds nothing.
    T.eq_str("find size 0", find([r(w(4096), w(0), 7)], w(4096)), "None")
    # A region larger than 2^32 bytes.
    T.eq_str("find big", find([r(w(0), U.U64{2, 0}, 7)], U.U64{1, 5}), "Hit 7 0x100000005")
    # Overlapping regions: the first one wins.
    T.eq_str("find first wins", find([r(w(0), w(16), 1), r(w(8), w(16), 2)], w(9)), "Hit 1 0x9")
    # Disjoint.
    T.eq_str("machine disjoint", b(L.Bus.disjoint(machine())), "T")
    T.eq_str("empty disjoint", b(L.Bus.disjoint([])), "T")
    T.eq_str("ends at 2^64", b(L.Bus.disjoint([r(top(), w(256), 0)])), "T")
    T.eq_str("wraps by one", b(L.Bus.disjoint([r(top(), w(257), 0)])), "F")
    T.eq_str("all of memory", b(L.Bus.disjoint([r(w(0), U.U64{4294967295, 4294967295}, 0)])), "T")
    T.eq_str("size 0 inside", b(L.Bus.disjoint([r(w(4096), w(4096), 0), r(w(5000), w(0), 1)])), "T")
    T.eq_str("same base", b(L.Bus.disjoint([r(w(4096), w(16), 0), r(w(4096), w(16), 1)])), "F")
    T.eq_str("unsorted overlap", b(L.Bus.disjoint([r(w(8192), w(16), 0), r(w(4096), w(8192), 1)])), "F")
    T.eq_str("unsorted disjoint", b(L.Bus.disjoint([r(w(8192), w(16), 0), r(w(4096), w(4096), 1)])), "T")
    T.eq_str("first and last overlap", b(L.Bus.disjoint([r(w(0), w(16), 0), r(w(64), w(16), 1), r(w(15), w(1), 2)])), "F")
    T.eq_str("overlap across hi", b(L.Bus.disjoint([r(U.U64{0, 4294967040}, w(512), 0), r(U.U64{1, 0}, w(16), 1)])), "F")
    T.eq_str("touch across hi", b(L.Bus.disjoint([r(U.U64{0, 4294967040}, w(256), 0), r(U.U64{1, 0}, w(16), 1)])), "T")
    T.eq_str("machine with ram is not", b(L.Bus.disjoint(r(w(167772160), w(1024), 99) <> machine())), "F")
