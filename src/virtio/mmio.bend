import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The virtio-mmio transport, version 2 (Virtio 1.2 section 4.2.2), as a pure
# register model. It knows nothing about the device behind it: it reports the
# events (queue notifications, resets) and the device code acts on them.
# Offsets (decimal; hex in comments):
#   MagicValue 0 (0x000) = 1953655158 (0x74726976 "virt")
#   Version 4 (0x004) = 2        DeviceID 8 (0x008)
#   VendorID 12 (0x00c) = 1145980226 (0x444E4542, "BEND" in memory order)
#   DeviceFeatures 16 (0x010)    DeviceFeaturesSel 20 (0x014)
#   DriverFeatures 32 (0x020)    DriverFeaturesSel 36 (0x024)
#   QueueSel 48 (0x030)          QueueNumMax 52 (0x034)    QueueNum 56 (0x038)
#   QueueReady 68 (0x044)        QueueNotify 80 (0x050)
#   InterruptStatus 96 (0x060)   InterruptACK 100 (0x064)  Status 112 (0x070)
#   QueueDescLow 128 (0x080)     QueueDescHigh 132 (0x084)
#   QueueDriverLow 144 (0x090)   QueueDriverHigh 148 (0x094)
#   QueueDeviceLow 160 (0x0a0)   QueueDeviceHigh 164 (0x0a4)
#   ConfigGeneration 252 (0x0fc) Config 256.. (0x100..), little-endian bytes
# Feature selector 0 reads bits 0..31, 1 reads bits 32..63, others read 0.
# Writing 0 to Status resets the device: driver features, status, interrupt
# status and every queue's num/ready/addresses return to their reset values.
# QueueSel past the last queue selects nothing: QueueNumMax reads 0 there and
# writes to queue registers are ignored.

def Mmio.vendor_id() -> U32:
  1145980226

type QueueCfg is Data:
  QueueCfg{num_max: U32, num: U32, ready: Bool, desc: U.U64, driver: U.U64, device: U.U64}

type VirtioMmio is Data:
  VirtioMmio{
    device_id: U32,
    device_features: U.U64,
    driver_features: U.U64,
    device_features_sel: U32,
    driver_features_sel: U32,
    queue_sel: U32,
    queues: +List<QueueCfg>,
    status: U32,
    interrupt_status: U32,
    config_generation: U32,
    config: +List<U32>
  }

# What a register write asks the device to do.
type MmioEvent is Data:
  NoEvent{}
  # The driver wrote QueueNotify with this queue index.
  Notify{queue: U32}
  # The driver wrote 0 to Status.
  DeviceReset{}
  # The driver set DRIVER_OK (status value 4) in this write.
  DriverOk{}

# A device of the given id and features with nqueues queues of num_max
# entries each and the given config space bytes.
def VirtioMmio.new(device_id: U32, features: U.U64, nqueues: Nat, num_max: U32, config: +List<U32>) -> VirtioMmio:
  ?TODO

# Reads a 32-bit register (config space reads may be 1, 2 or 4 bytes: size).
def VirtioMmio.read(s: VirtioMmio, off: U32, size: U32) -> VirtioMmio & U32:
  ?TODO

def VirtioMmio.write(s: VirtioMmio, off: U32, v: U32) -> VirtioMmio & MmioEvent:
  ?TODO

# The configuration of queue q, if it exists.
def VirtioMmio.queue(s: VirtioMmio, q: U32) -> Maybe<&2, QueueCfg>:
  ?TODO

# Sets bits in InterruptStatus (1 = used buffer, 2 = config change).
def VirtioMmio.raise(s: VirtioMmio, bits: U32) -> VirtioMmio:
  ?TODO

# The interrupt line's level: InterruptStatus is non-zero.
def VirtioMmio.irq(s: VirtioMmio) -> Bool:
  ?TODO
