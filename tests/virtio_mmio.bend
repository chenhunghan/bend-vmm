import Base
import ../src/lib/u64.bend as U
import ../src/virtio/mmio.bend as M
import ../src/virtio/queue.bend as Q
import ./t.bend as T

# The virtio-mmio transport: behaviour past the laws (the probe sequence
# Linux's virtio_mmio driver performs, feature words, several queues, config
# reads of every size and past the end, write-only and unknown registers,
# reset, interrupt bits).

def dev() -> M.VirtioMmio:
  M.VirtioMmio.new(4, U.U64{1, 0}, 1n, 256, [1, 2, 3, 4])

# A virtio-blk-like device: two queues of 128 and 6 config bytes.
def dev2() -> M.VirtioMmio:
  M.VirtioMmio.new(2, U.U64{1, 2147483649}, 2n, 128, [10, 20, 30, 40, 50, 60])

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

def rdn(s: M.VirtioMmio, off: U32, size: U32) -> U32:
  val_of(M.VirtioMmio.read(s, off, size))

def wr(s: M.VirtioMmio, off: U32, v: U32) -> M.VirtioMmio:
  wst_of(M.VirtioMmio.write(s, off, v))

def ev(s: M.VirtioMmio, off: U32, v: U32) -> M.MmioEvent:
  ev_of(M.VirtioMmio.write(s, off, v))

def show_ev(e: M.MmioEvent) -> String:
  match e:
    case M.NoEvent{}:
      "NoEvent"
    case M.Notify{q}:
      "Notify " ++ U32.show(q)
    case M.DeviceReset{}:
      "DeviceReset"
    case M.DriverOk{}:
      "DriverOk"

def show_u64(a: U.U64) -> String:
  match a:
    case U.U64{h, l}:
      U32.show(h) ++ ":" ++ U32.show(l)

def show_cfg(m: Maybe<&2, M.QueueCfg>) -> String:
  match m:
    case None{}:
      "None"
    case Some{c}:
      match c:
        case M.QueueCfg{nm, n, r, d, dr, dv}:
          U32.show(nm) ++ " " ++ U32.show(n) ++ " " ++ Bool.show(r) ++ " " ++ show_u64(d) ++ " " ++ show_u64(dr) ++ " " ++ show_u64(dv)

def eq_ev(name: String, got: M.MmioEvent, want: M.MmioEvent) -> IO(Unit):
  T.eq_str(name, show_ev(got), show_ev(want))

def eq_cfg(name: String, got: Maybe<&2, M.QueueCfg>, want: String) -> IO(Unit):
  T.eq_str(name, show_cfg(got), want)

# Linux's probe and virtio_dev_probe up to DRIVER_OK, on queue 0 of dev().
def linux_ready() -> M.VirtioMmio:
  +s0 = wr(dev(), 112, 0)
  +s1 = wr(wr(s0, 112, 1), 112, 3)
  +s2 = wr(wr(wr(wr(s1, 36, 1), 32, 1), 36, 0), 32, 0)
  +s3 = wr(s2, 112, 11)
  +s4 = wr(wr(s3, 48, 0), 56, 256)
  +s5 = wr(wr(wr(wr(s4, 128, 4096), 132, 0), 144, 8192), 148, 0)
  +s6 = wr(wr(wr(s5, 160, 12288), 164, 1), 68, 1)
  wr(s6, 112, 15)

def main() -> IO(Unit):
  do IO<Unit>:
    # Identification registers, as virtio_mmio_probe reads them.
    T.eq_u32("magic", rd(dev2(), 0), 1953655158)
    T.eq_u32("version", rd(dev2(), 4), 2)
    T.eq_u32("device id blk", rd(dev2(), 8), 2)
    T.eq_u32("vendor id", rd(dev2(), 12), M.Mmio.vendor_id())
    # Feature words: selector 0 low, 1 high, others 0.
    T.eq_u32("features low", rd(dev2(), 16), 2147483649)
    T.eq_u32("features high", rd(wr(dev2(), 20, 1), 16), 1)
    T.eq_u32("features sel 7", rd(wr(dev2(), 20, 7), 16), 0)
    T.eq_u32("features sel back to 0", rd(wr(wr(dev2(), 20, 1), 20, 0), 16), 2147483649)
    # DriverFeatures is write-only: it reads 0, and a write makes no event.
    T.eq_u32("driver features reads 0", rd(wr(dev(), 32, 5), 32), 0)
    eq_ev("driver features no event", ev(dev(), 32, 5), M.NoEvent{})
    T.eq_u32("features sel reads 0", rd(wr(dev(), 20, 1), 20), 0)
    # Status and events.
    eq_ev("reset from 0", ev(dev(), 112, 0), M.DeviceReset{})
    eq_ev("status ack no event", ev(dev(), 112, 1), M.NoEvent{})
    eq_ev("driver ok again no event", ev(wr(wr(dev(), 112, 11), 112, 15), 112, 15), M.NoEvent{})
    eq_ev("driver ok straight", ev(dev(), 112, 4), M.DriverOk{})
    eq_ev("notify queue 3", ev(dev(), 80, 3), M.Notify{3})
    T.eq_u32("notify keeps status", rd(wr(wr(dev(), 112, 3), 80, 0), 112), 3)
    # Linux's whole setup, then the queue it configured.
    T.eq_u32("linux status", rd(linux_ready(), 112), 15)
    T.eq_u32("linux ready", rd(linux_ready(), 68), 1)
    eq_cfg("linux queue", M.VirtioMmio.queue(linux_ready(), 0), "256 256 True 0:4096 0:8192 1:12288")
    eq_ev("linux driver ok", ev(wr(wr(dev(), 112, 11), 68, 1), 112, 15), M.DriverOk{})
    # Reset after DRIVER_OK clears every queue, keeps the device offer.
    eq_cfg("reset queue", M.VirtioMmio.queue(wr(linux_ready(), 112, 0), 0), "256 0 False 0:0 0:0 0:0")
    T.eq_u32("reset status", rd(wr(linux_ready(), 112, 0), 112), 0)
    T.eq_u32("reset keeps features", rd(wr(wr(linux_ready(), 112, 0), 20, 1), 16), 1)
    T.eq_u32("reset clears interrupt", rd(wr(M.VirtioMmio.raise(dev(), 3), 112, 0), 96), 0)
    # Queue registers follow QueueSel.
    T.eq_u32("sel 1 num max", rd(wr(dev2(), 48, 1), 52), 128)
    T.eq_u32("sel 2 num max", rd(wr(dev2(), 48, 2), 52), 0)
    T.eq_u32("queue sel reads 0", rd(wr(dev2(), 48, 1), 48), 0)
    eq_cfg("sel 1 num", M.VirtioMmio.queue(wr(wr(dev2(), 48, 1), 56, 64), 1), "128 64 False 0:0 0:0 0:0")
    eq_cfg("sel 1 leaves 0", M.VirtioMmio.queue(wr(wr(dev2(), 48, 1), 56, 64), 0), "128 0 False 0:0 0:0 0:0")
    eq_cfg("sel 1 ready", M.VirtioMmio.queue(wr(wr(dev2(), 48, 1), 68, 1), 1), "128 0 True 0:0 0:0 0:0")
    T.eq_u32("sel 1 ready reads", rd(wr(wr(wr(dev2(), 48, 1), 68, 1), 48, 0), 68), 0)
    T.eq_u32("missing queue ready reads 0", rd(wr(wr(dev(), 48, 1), 68, 1), 68), 0)
    eq_cfg("missing queue write ignored", M.VirtioMmio.queue(wr(wr(dev(), 48, 1), 56, 16), 0), "256 0 False 0:0 0:0 0:0")
    eq_cfg("queue 2 missing", M.VirtioMmio.queue(dev2(), 2), "None")
    T.eq_u32("ready 0 clears", rd(wr(wr(dev(), 68, 1), 68, 0), 68), 0)
    T.eq_u32("queue num write-only", rd(wr(dev(), 56, 128), 56), 0)
    T.eq_u32("queue desc write-only", rd(wr(dev(), 128, 4096), 128), 0)
    # Interrupts: raise ORs bits, ACK clears only the acked ones.
    T.eq_u32("raise ors", rd(M.VirtioMmio.raise(M.VirtioMmio.raise(dev(), 1), 2), 96), 3)
    T.eq_u32("ack one bit", rd(wr(M.VirtioMmio.raise(dev(), 3), 100, 1), 96), 2)
    T.ok("ack one keeps irq", M.VirtioMmio.irq(wr(M.VirtioMmio.raise(dev(), 3), 100, 1)))
    T.ok("idle no irq", Bool.not(M.VirtioMmio.irq(dev())))
    T.eq_u32("ack reads 0", rd(M.VirtioMmio.raise(dev(), 1), 100), 0)
    eq_ev("ack no event", ev(M.VirtioMmio.raise(dev(), 1), 100, 1), M.NoEvent{})
    # Config space: little-endian, 1/2/4 bytes, zero past the end.
    T.eq_u32("config u8 last", rdn(dev2(), 261, 1), 60)
    T.eq_u32("config u16", rdn(dev2(), 258, 2), 10270)
    T.eq_u32("config u32 at 4", rdn(dev2(), 260, 4), 15410)
    T.eq_u32("config u32 tail", rdn(dev(), 258, 4), 1027)
    T.eq_u32("config past end", rdn(dev(), 300, 4), 0)
    T.eq_u32("config u8 past end", rdn(dev(), 260, 1), 0)
    T.eq_u32("config write ignored", rdn(wr(dev(), 256, 99), 256, 1), 1)
    T.eq_u32("config generation", rd(dev(), 252), 0)
    # Shared memory regions: none (length -1).
    T.eq_u32("shm len low", rd(dev(), 176), 4294967295)
    T.eq_u32("shm len high", rd(dev(), 180), 4294967295)
    # Unknown and read-only registers.
    T.eq_u32("unknown reads 0", rd(dev(), 200), 0)
    T.eq_u32("magic read-only", rd(wr(dev(), 0, 5), 0), 1953655158)
    eq_ev("unknown write no event", ev(dev(), 200, 1), M.NoEvent{})
    # QueueNum past QueueNumMax: the write is dropped (a guest number must
    # not size the device's loops); Vq.from_cfg clamps as a second line.
    eq_cfg("queue num over max dropped", M.VirtioMmio.queue(wr(wr(dev(), 56, 16), 56, 257), 0), "256 16 False 0:0 0:0 0:0")
    eq_cfg("queue num huge dropped", M.VirtioMmio.queue(wr(dev(), 56, 4294967295), 0), "256 0 False 0:0 0:0 0:0")
    eq_cfg("queue num at max kept", M.VirtioMmio.queue(wr(dev(), 56, 256), 0), "256 256 False 0:0 0:0 0:0")
    T.ok("from_cfg clamps num", Q.Vq.is_eq(Q.Vq.from_cfg(M.QueueCfg{256, 65535, True{}, U.U64{0, 1}, U.U64{0, 2}, U.U64{0, 3}}), Q.Vq{256, U.U64{0, 1}, U.U64{0, 2}, U.U64{0, 3}, 0, 0}))
