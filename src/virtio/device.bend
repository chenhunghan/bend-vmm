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

# VIRTIO_F_VERSION_1: bit 32, so bit 0 of the high word.
def Dev.features() -> U.U64:
  U.U64{1, 0}

# The transport of a fresh device of the given kind.
def Dev.mmio(kind: DevKind) -> M.VirtioMmio:
  match kind:
    case RngKind{}:
      M.VirtioMmio.new(4, Dev.features(), 1n, 256, [])
    case BlkKind{disk, sectors}:
      M.VirtioMmio.new(2, Dev.features(), 1n, 256, Blk.Blk.config(sectors))

def Dev.new(kind: DevKind) -> Dev:
  +kind = kind
  Dev{kind, Dev.mmio(kind), []}

def Dev.read.fin(k: DevKind, qs: +List<Q.Vq>, r: M.VirtioMmio & U32) -> Dev & U32:
  match r:
    case (m, v):
      (Dev{k, m, qs}, v)

def Dev.read(d: Dev, off: U32, size: U32) -> Dev & U32:
  match d:
    case Dev{k, m, qs}:
      Dev.read.fin(k, qs, M.VirtioMmio.read(m, off, size))

# One Q.Vq per queue configuration, in order.
def Dev.build(cs: +List<M.QueueCfg>) -> +List<Q.Vq>:
  match cs:
    case Nil{}:
      []
    case c <> t:
      Q.Vq.from_cfg(c) <> Dev.build(t)

def Dev.cfgs(m: M.VirtioMmio) -> +List<M.QueueCfg>:
  match m:
    case M.VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}:
      qs

# Queue sel of the list; i counts the list position.
def Dev.qget(qs: +List<Q.Vq>, +i: U32, +sel: U32) -> Maybe<&2, Q.Vq>:
  match qs:
    case Nil{}:
      None{}
    case +h <> t:
      Bool.pick(Maybe<&2, Q.Vq>, U32.is_eq(i, sel), Some{h}, Dev.qget(t, (i + 1 : U32), sel))

# Replaces queue sel of the list by q; i counts the list position.
def Dev.qput(qs: +List<Q.Vq>, +i: U32, +sel: U32, +q: Q.Vq) -> +List<Q.Vq>:
  match qs:
    case Nil{}:
      []
    case +h <> t:
      Bool.pick(Q.Vq, U32.is_eq(i, sel), q, h) <> Dev.qput(t, (i + 1 : U32), sel, q)

# Raises the used-buffer interrupt (status bit 1) when used.
def Dev.raise_if(used: Bool, m: M.VirtioMmio) -> M.VirtioMmio:
  match used:
    case True{}:
      M.VirtioMmio.raise(m, 1)
    case False{}:
      m

# Runs the kind's process on a queue.
def Dev.process(-R: Type, k: DevKind, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  match k:
    case RngKind{}:
      Rng.Rng.process(R, q)
    case BlkKind{disk, sectors}:
      Blk.Blk.process(R, disk, sectors, q)

def Dev.notify.fin(k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, sel: U32, r: Q.Vq & Bool) -> Dev:
  match r:
    case (q, used):
      Dev{k, Dev.raise_if(used, m), Dev.qput(qs, 0, sel, q)}

# Runs the process on queue sel when it exists.
def Dev.notify(-R: Type, mq: Maybe<&2, Q.Vq>, +k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, sel: U32) -> V.Op<R, Dev>:
  match mq:
    case None{}:
      V.Op.pure(R, Dev, Dev{k, m, qs})
    case Some{q}:
      do V.Op<R, Dev>:
        r : Q.Vq & Bool <- Dev.process(R, k, q)
        return Dev.notify.fin(k, m, qs, sel, r)

# Acts on the event of a transport write.
def Dev.on_event(-R: Type, ev: M.MmioEvent, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>) -> V.Op<R, Dev>:
  match ev:
    case M.NoEvent{}:
      V.Op.pure(R, Dev, Dev{k, m, qs})
    case M.DeviceReset{}:
      V.Op.pure(R, Dev, Dev{k, m, []})
    case M.DriverOk{}:
      +m = m
      V.Op.pure(R, Dev, Dev{k, m, Dev.build(Dev.cfgs(m))})
    case M.Notify{+q}:
      +qs = qs
      Dev.notify(R, Dev.qget(qs, 0, q), k, m, qs, q)

def Dev.write.fin(-R: Type, k: DevKind, qs: +List<Q.Vq>, r: M.VirtioMmio & M.MmioEvent) -> V.Op<R, Dev>:
  match r:
    case (m, ev):
      Dev.on_event(R, ev, k, m, qs)

def Dev.write(-R: Type, d: Dev, off: U32, v: U32) -> V.Op<R, Dev>:
  match d:
    case Dev{k, m, qs}:
      Dev.write.fin(R, k, qs, M.VirtioMmio.write(m, off, v))

# The interrupt line's level.
def Dev.irq(d: Dev) -> Bool:
  match d:
    case Dev{k, m, qs}:
      M.VirtioMmio.irq(m)
