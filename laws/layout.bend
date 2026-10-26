import Base
import ../src/lib/u64.bend as U
import ../src/vmm/layout.bend as L

# Frozen spec for src/vmm/layout.bend.

def w(x: U32) -> U.U64:
  U.U64{0, x}

# UART (dev 0), virtio slots 0 and 1 (devs 1, 2).
def bus() -> +List<L.Region>:
  [L.Region{w(150994944), w(4096), 0}, L.Region{w(167772160), w(512), 1}, L.Region{w(167772672), w(512), 2}]

law layout.virtio_slot0:
  {L.Layout.virtio_slot(0) == w(167772160) : U.U64}

law layout.virtio_slot3:
  # 0x0A00_0600
  {L.Layout.virtio_slot(3) == w(167773696) : U.U64}

law layout.virtio_intid:
  {L.Layout.virtio_intid(5) == 53 : U32}

law layout.find_uart:
  {L.Bus.find(bus(), w(150994968)) == Some{L.Hit{0, w(24)}} : Maybe<&2, L.Hit>}

law layout.find_second_slot:
  {L.Bus.find(bus(), w(167772784)) == Some{L.Hit{2, w(112)}} : Maybe<&2, L.Hit>}

law layout.find_end_exclusive:
  # 0x0900_1000 is one past the UART
  {L.Bus.find(bus(), w(150999040)) == None{} : Maybe<&2, L.Hit>}

law layout.find_high_word:
  {L.Bus.find(bus(), U.U64{1, 150994944}) == None{} : Maybe<&2, L.Hit>}

law layout.find_ram:
  {L.Bus.find(bus(), L.Layout.ram_base()) == None{} : Maybe<&2, L.Hit>}

law layout.disjoint:
  {L.Bus.disjoint(bus()) == True{} : Bool}

law layout.overlap:
  {L.Bus.disjoint([L.Region{w(4096), w(4096), 0}, L.Region{w(8191), w(16), 1}]) == False{} : Bool}

law layout.touching_is_disjoint:
  {L.Bus.disjoint([L.Region{w(4096), w(4096), 0}, L.Region{w(8192), w(16), 1}]) == True{} : Bool}

law layout.wraps:
  {L.Bus.disjoint([L.Region{U.U64{4294967295, 4294967040}, w(512), 0}]) == False{} : Bool}

# General: find on an empty bus finds nothing.
law layout.find_empty:
  for a: U.U64
  {L.Bus.find([], a) == None{} : Maybe<&2, L.Hit>}
