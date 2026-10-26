import Base
import ../src/lib/u64.bend as U
import ../src/virtio/mmio.bend as M

# Frozen spec for src/virtio/mmio.bend. The sample is a virtio-rng (device
# id 4) offering VIRTIO_F_VERSION_1 (feature bit 32) and one queue of 256.

def dev() -> M.VirtioMmio:
  M.VirtioMmio.new(4, U.U64{1, 0}, 1n, 256, [1, 2, 3, 4])

def val_of(r: M.VirtioMmio & U32) -> U32:
  match r:
    case (s, v):
      v

def wst_of(r: M.VirtioMmio & M.MmioEvent) -> M.VirtioMmio:
  match r:
    case (s, e):
      s

def ev_of(r: M.VirtioMmio & M.MmioEvent) -> M.MmioEvent:
  match r:
    case (s, e):
      e

def rd(s: M.VirtioMmio, off: U32) -> U32:
  val_of(M.VirtioMmio.read(s, off, 4))

def wr(s: M.VirtioMmio, off: U32, v: U32) -> M.VirtioMmio:
  wst_of(M.VirtioMmio.write(s, off, v))

def ev(s: M.VirtioMmio, off: U32, v: U32) -> M.MmioEvent:
  ev_of(M.VirtioMmio.write(s, off, v))

law virtio_mmio.magic:
  {rd(dev(), 0) == 1953655158 : U32}

law virtio_mmio.version:
  {rd(dev(), 4) == 2 : U32}

law virtio_mmio.device_id:
  {rd(dev(), 8) == 4 : U32}

law virtio_mmio.vendor_id:
  {rd(dev(), 12) == 1145980226 : U32}

law virtio_mmio.features_low:
  {rd(dev(), 16) == 0 : U32}

law virtio_mmio.features_high:
  {rd(wr(dev(), 20, 1), 16) == 1 : U32}

law virtio_mmio.features_sel_out_of_range:
  {rd(wr(dev(), 20, 2), 16) == 0 : U32}

law virtio_mmio.queue_num_max:
  {rd(dev(), 52) == 256 : U32}

law virtio_mmio.queue_num_max_missing_queue:
  {rd(wr(dev(), 48, 1), 52) == 0 : U32}

law virtio_mmio.queue_ready_roundtrip:
  {rd(wr(dev(), 68, 1), 68) == 1 : U32}

law virtio_mmio.status_roundtrip:
  {rd(wr(dev(), 112, 3), 112) == 3 : U32}

law virtio_mmio.notify:
  {ev(dev(), 80, 0) == M.Notify{0} : M.MmioEvent}

law virtio_mmio.reset_event:
  {ev(wr(dev(), 112, 3), 112, 0) == M.DeviceReset{} : M.MmioEvent}

law virtio_mmio.driver_ok_event:
  {ev(wr(dev(), 112, 11), 112, 15) == M.DriverOk{} : M.MmioEvent}

law virtio_mmio.reset_clears:
  {wr(wr(wr(dev(), 112, 3), 68, 1), 112, 0) == dev() : M.VirtioMmio}

law virtio_mmio.queue_desc:
  {M.VirtioMmio.queue(wr(wr(dev(), 128, 4096), 132, 1), 0) == Some{M.QueueCfg{256, 0, False{}, U.U64{1, 4096}, U.U64{0, 0}, U.U64{0, 0}}} : Maybe<&2, M.QueueCfg>}

law virtio_mmio.queue_missing:
  {M.VirtioMmio.queue(dev(), 1) == None{} : Maybe<&2, M.QueueCfg>}

law virtio_mmio.interrupt:
  {rd(M.VirtioMmio.raise(dev(), 1), 96) == 1 : U32}

law virtio_mmio.interrupt_ack:
  {M.VirtioMmio.irq(wr(M.VirtioMmio.raise(dev(), 3), 100, 3)) == False{} : Bool}

law virtio_mmio.irq_raised:
  {M.VirtioMmio.irq(M.VirtioMmio.raise(dev(), 2)) == True{} : Bool}

law virtio_mmio.config_byte:
  {val_of(M.VirtioMmio.read(dev(), 257, 1)) == 2 : U32}

law virtio_mmio.config_word:
  {val_of(M.VirtioMmio.read(dev(), 256, 4)) == 67305985 : U32}
