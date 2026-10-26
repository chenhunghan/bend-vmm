import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./mmio.bend as M
import ./queue.bend as Q
import ./rng.bend as Rng
import ./blk.bend as Blk

# A virtio-mmio device: the transport register model plus the device logic
# behind it, as the machine sees it.
#
# Both kinds offer exactly VIRTIO_F_VERSION_1 (feature bit 32) and one queue
# of 256 entries:
#   RngKind: device id 4, empty config space
#   BlkKind: device id 2, config space Blk.config(sectors)
#
# Writes go to the transport (M.VirtioMmio.write), then:
#   DeviceReset: the queue list empties
#   DriverOk:    one Q.Vq per queue, from its QueueCfg (Q.Vq.from_cfg), in order
#   Notify{q}:   when queue q exists, the kind's process runs on it and the
#                updated queue is stored; when it used any chain, interrupt
#                status bit 1 is raised (M.VirtioMmio.raise)
#   NoEvent:     nothing more

type DevKind is Data:
  RngKind{}
  BlkKind{disk: U32, sectors: U.U64}

type Dev is Data:
  Dev{kind: DevKind, mmio: M.VirtioMmio, queues: +List<Q.Vq>}

def Dev.new(kind: DevKind) -> Dev:
  ?TODO

def Dev.read(d: Dev, off: U32, size: U32) -> Dev & U32:
  ?TODO

def Dev.write(-R: Type, d: Dev, off: U32, v: U32) -> V.Op<R, Dev>:
  ?TODO

# The interrupt line's level.
def Dev.irq(d: Dev) -> Bool:
  ?TODO
