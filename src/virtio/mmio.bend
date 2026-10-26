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

# x when b holds, else y.
def Mmio.pick(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

def Mmio.pick_ev(b: Bool, x: MmioEvent, y: MmioEvent) -> MmioEvent:
  match b:
    case True{}:
      x
    case False{}:
      y

def Mmio.pick_b(b: Bool, x: Bool, y: Bool) -> Bool:
  match b:
    case True{}:
      x
    case False{}:
      y

def Mmio.pick_n(b: Bool, x: Nat, y: Nat) -> Nat:
  match b:
    case True{}:
      x
    case False{}:
      y

def Mmio.pick_l(b: Bool, x: +List<U32>, y: +List<U32>) -> +List<U32>:
  match b:
    case True{}:
      x
    case False{}:
      y

def Mmio.pick_q(b: Bool, x: QueueCfg, y: QueueCfg) -> QueueCfg:
  match b:
    case True{}:
      x
    case False{}:
      y

# A 64-bit queue address whose low half sits at offset lo and high half at
# lo + 4: a write to either replaces that half.
def Mmio.half(+off: U32, +lo: U32, +v: U32, a: U.U64) -> U.U64:
  match a:
    case U.U64{h, l}:
      U.U64{Mmio.pick(U32.is_eq(off, (lo + 4 : U32)), v, h), Mmio.pick(U32.is_eq(off, lo), v, l)}

# A queue register write (QueueNum, QueueReady, the six address halves).
def Mmio.qwrite(c: QueueCfg, +off: U32, +v: U32) -> QueueCfg:
  match c:
    case QueueCfg{nm, n, r, d, dr, dv}:
      ready = Mmio.pick_b(U32.is_eq(off, 68), U32.is_ne((v .&. 1 : U32), 0), r)
      QueueCfg{
        nm,
        Mmio.pick(U32.is_eq(off, 56), v, n),
        ready,
        Mmio.half(off, 128, v, d),
        Mmio.half(off, 144, v, dr),
        Mmio.half(off, 160, v, dv)
      }

# Applies a queue register write to queue sel; i counts the list position.
def Mmio.qset(qs: +List<QueueCfg>, +i: U32, +sel: U32, +off: U32, +v: U32) -> +List<QueueCfg>:
  match qs:
    case Nil{}:
      []
    case +h <> t:
      Mmio.pick_q(U32.is_eq(i, sel), Mmio.qwrite(h, off, v), h) <> Mmio.qset(t, (i + 1 : U32), sel, off, v)

def Mmio.qget.go(here: Bool, h: QueueCfg, r: Maybe<&2, QueueCfg>) -> Maybe<&2, QueueCfg>:
  match here:
    case True{}:
      Some{h}
    case False{}:
      r

# Queue sel; i counts the list position.
def Mmio.qget(qs: +List<QueueCfg>, +i: U32, +sel: U32) -> Maybe<&2, QueueCfg>:
  match qs:
    case Nil{}:
      None{}
    case h <> t:
      Mmio.qget.go(U32.is_eq(i, sel), h, Mmio.qget(t, (i + 1 : U32), sel))

# A queue's reset values: num 0, not ready, addresses 0.
def Mmio.qreset(qs: +List<QueueCfg>) -> +List<QueueCfg>:
  match qs:
    case Nil{}:
      []
    case h <> t:
      match h:
        case QueueCfg{nm, n, r, d, dr, dv}:
          QueueCfg{nm, 0, False{}, U.U64{0, 0}, U.U64{0, 0}, U.U64{0, 0}} <> Mmio.qreset(t)

# QueueNumMax and QueueReady of the selected queue; 0 for a missing one.
def Mmio.qread(m: Maybe<&2, QueueCfg>, +off: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{c}:
      match c:
        case QueueCfg{nm, n, r, d, dr, dv}:
          Mmio.pick(U32.is_eq(off, 52), nm, Mmio.pick(U32.is_eq(off, 68), Bool.to_u32(r), 0))

# The 32-bit feature word sel: 0 low, 1 high, others 0.
def Mmio.word(+sel: U32, a: U.U64) -> U32:
  match a:
    case U.U64{h, l}:
      Mmio.pick(U32.is_eq(sel, 0), l, Mmio.pick(U32.is_eq(sel, 1), h, 0))

# A DriverFeatures write (when on) to the word sel; other selectors drop it.
def Mmio.set_word(on: Bool, +sel: U32, +v: U32, a: U.U64) -> U.U64:
  match on:
    case True{}:
      match a:
        case U.U64{h, l}:
          U.U64{Mmio.pick(U32.is_eq(sel, 1), v, h), Mmio.pick(U32.is_eq(sel, 0), v, l)}
    case False{}:
      a

# Config bytes from offset k on.
def Mmio.cfg_from(cfg: +List<U32>, +k: U32) -> +List<U32>:
  match cfg:
    case Nil{}:
      []
    case h <> +t:
      Mmio.pick_l(U32.is_eq(k, 0), h <> t, Mmio.cfg_from(t, (k - 1 : U32)))

# The byte count of a config access: 1, 2, else 4.
def Mmio.width(+size: U32) -> Nat:
  Mmio.pick_n(U32.is_eq(size, 1), 1n, Mmio.pick_n(U32.is_eq(size, 2), 2n, 4n))

# A side-effect-free read. Write-only and unknown registers read 0; the
# shared memory length and base (176..188, 0xb0..0xbc) read -1: no region.
def Mmio.peek(s: VirtioMmio, +off: U32, +size: U32) -> U32:
  match s:
    case VirtioMmio{id, df, drf, +dsel, drsel, +qsel, qs, st, ist, cg, cfg}:
      regs = (
        Mmio.pick(U32.is_eq(off, 0), 1953655158,
        Mmio.pick(U32.is_eq(off, 4), 2,
        Mmio.pick(U32.is_eq(off, 8), id,
        Mmio.pick(U32.is_eq(off, 12), Mmio.vendor_id(),
        Mmio.pick(U32.is_eq(off, 16), Mmio.word(dsel, df),
        Mmio.pick(U32.is_eq(off, 52) || U32.is_eq(off, 68), Mmio.qread(Mmio.qget(qs, 0, qsel), off),
        Mmio.pick(U32.is_eq(off, 96), ist,
        Mmio.pick(U32.is_eq(off, 112), st,
        Mmio.pick(U32.is_eq(off, 252), cg,
        Mmio.pick((176 <= off : U32) && (off <= 188 : U32) && U32.is_eq((off .&. 3 : U32), 0), 4294967295, 0)))))))))))
      Mmio.pick((256 <= off : U32), B.Bytes.read_le(Mmio.width(size), Mmio.cfg_from(cfg, (off - 256 : U32))), regs)

def Mmio.status(s: VirtioMmio) -> U32:
  match s:
    case VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
      st

# The event of a Status write of v over the old status: 0 resets, a write
# that newly sets DRIVER_OK (4) reports it.
def Mmio.status_ev(zero: Bool, +old: U32, +v: U32) -> MmioEvent:
  match zero:
    case True{}:
      DeviceReset{}
    case False{}:
      Mmio.pick_ev(U32.is_ne((v .&. 4 : U32), 0) && U32.is_eq((old .&. 4 : U32), 0), DriverOk{}, NoEvent{})

def Mmio.event(+old: U32, +off: U32, +v: U32) -> MmioEvent:
  Mmio.pick_ev(U32.is_eq(off, 80), Notify{v},
  Mmio.pick_ev(U32.is_eq(off, 112), Mmio.status_ev(U32.is_eq(v, 0), old, v), NoEvent{}))

# The reset of the driver's side of the device (when on).
def Mmio.reset_if(on: Bool, s: VirtioMmio) -> VirtioMmio:
  match on:
    case True{}:
      match s:
        case VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
          VirtioMmio{id, df, U.U64{0, 0}, dsel, drsel, qsel, Mmio.qreset(qs), 0, 0, cg, cfg}
    case False{}:
      s

# The state after a write. InterruptACK clears the acked bits; writes to
# read-only registers and config space are dropped.
def Mmio.next(s: VirtioMmio, +off: U32, +v: U32) -> VirtioMmio:
  match s:
    case VirtioMmio{id, df, drf, +dsel, +drsel, +qsel, qs, +st, +ist, cg, cfg}:
      st2 : VirtioMmio = VirtioMmio{
        id,
        df,
        Mmio.set_word(U32.is_eq(off, 32), drsel, v, drf),
        Mmio.pick(U32.is_eq(off, 20), v, dsel),
        Mmio.pick(U32.is_eq(off, 36), v, drsel),
        Mmio.pick(U32.is_eq(off, 48), v, qsel),
        Mmio.qset(qs, 0, qsel, off, v),
        Mmio.pick(U32.is_eq(off, 112), v, st),
        Mmio.pick(U32.is_eq(off, 100), (ist .&. U32.not(v) : U32), ist),
        cg,
        cfg
      }
      Mmio.reset_if(U32.is_eq(off, 112) && U32.is_eq(v, 0), st2)

# A device of the given id and features with nqueues queues of num_max
# entries each and the given config space bytes.
def VirtioMmio.new(device_id: U32, features: U.U64, nqueues: Nat, num_max: U32, config: +List<U32>) -> VirtioMmio:
  q : QueueCfg = QueueCfg{num_max, 0, False{}, U.U64{0, 0}, U.U64{0, 0}, U.U64{0, 0}}
  VirtioMmio{device_id, features, U.U64{0, 0}, 0, 0, 0, List.replicate(QueueCfg, nqueues, q), 0, 0, 0, config}

# Reads a 32-bit register (config space reads may be 1, 2 or 4 bytes: size).
def VirtioMmio.read(s: VirtioMmio, off: U32, size: U32) -> VirtioMmio & U32:
  +s = s
  (s, Mmio.peek(s, off, size))

# The new state and the event are independent: compute them in parallel.
def VirtioMmio.write(s: VirtioMmio, off: U32, v: U32) -> VirtioMmio & MmioEvent:
  +s = s
  +off = off
  +v = v
  ns e = Mmio.next(s, off, v) Mmio.event(Mmio.status(s), off, v)
  (ns, e)

# The configuration of queue q, if it exists.
def VirtioMmio.queue(s: VirtioMmio, q: U32) -> Maybe<&2, QueueCfg>:
  match s:
    case VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
      Mmio.qget(qs, 0, q)

# Sets bits in InterruptStatus (1 = used buffer, 2 = config change).
def VirtioMmio.raise(s: VirtioMmio, bits: U32) -> VirtioMmio:
  match s:
    case VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
      VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, (ist .|. bits : U32), cg, cfg}

# The interrupt line's level: InterruptStatus is non-zero.
def VirtioMmio.irq(s: VirtioMmio) -> Bool:
  match s:
    case VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
      U32.is_ne(ist, 0)
