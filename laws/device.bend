import Base
import ../src/lib/u64.bend as U
import ../src/virtio/device.bend as D

# Frozen spec for src/virtio/device.bend (its queue behaviour is pinned by
# tests/device.bend on the simulator).

def w(x: U32) -> U.U64:
  U.U64{0, x}

def val_of(r: D.Dev & U32) -> U32:
  match r:
    case (d, v):
      v

def rd(d: D.Dev, off: U32) -> U32:
  val_of(D.Dev.read(d, off, 4))

law device.rng_id:
  {rd(D.Dev.new(D.RngKind{}), 8) == 4 : U32}

law device.blk_id:
  {rd(D.Dev.new(D.BlkKind{0, w(2048)}), 8) == 2 : U32}

law device.version_1_offered:
  # DeviceFeatures with selector 0: no feature in bits 0..31 is offered.
  {val_of(D.Dev.read(D.Dev.new(D.RngKind{}), 16, 4)) == 0 : U32}

law device.queue_size:
  {rd(D.Dev.new(D.RngKind{}), 52) == 256 : U32}

law device.blk_capacity:
  {rd(D.Dev.new(D.BlkKind{0, w(2048)}), 256) == 2048 : U32}

law device.irq_low:
  {D.Dev.irq(D.Dev.new(D.BlkKind{0, w(1)})) == False{} : Bool}
