import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/device.bend as D
import ./t.bend as T

# The generic virtio-mmio device driven through Dev.read and Dev.write the
# way Linux's virtio_mmio driver probes it, with an rng behind it, on
# simulated guest memory. Layout (decimal): memory 4096..16416; descriptor
# table 4096, available ring 8192, used ring 12288. One request: d0 = 16384,
# 4 bytes, WRITE. The simulator's entropy is 0, 1, 2, ...

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def mem() -> S.Sim:
  +s = S.Sim.new(u64(4096), 12320n)
  s = S.Sim.write(s, u64(4096), [0, 64, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0])
  S.Sim.write(s, u64(8192), [0, 0, 1, 0, 0, 0])

def val_of(r: D.Dev & U32) -> U32:
  match r:
    case (d, v):
      v

def rd(d: D.Dev, off: U32) -> U32:
  val_of(D.Dev.read(d, off, 4))

def nq(d: D.Dev) -> U32:
  match d:
    case D.Dev{k, m, qs, st}:
      U32.from_nat(List.length(&2, Q.Vq, qs))

# The first queue's state, or a zero queue when there is none.
def q0(d: D.Dev) -> Q.Vq:
  match d:
    case D.Dev{k, m, qs, st}:
      match qs:
        case Nil{}:
          Q.Vq{0, u64(0), u64(0), u64(0), 0, 0}
        case q <> t:
          q

# Observations, each a list of register values at one step of the probe.
type Out is Data:
  Out{neg: +List<U32>, setup: +List<U32>, built: Q.Vq, notify: +List<U32>, ack: +List<U32>, reset: +List<U32>, after: Q.Vq}

# The device after a write (Dev.write also answers what goes to the host).
def wr(d: D.Dev, off: U32, v: U32) -> V.Op<Out, D.Dev>:
  do V.Op<Out, D.Dev>:
    o : D.DevOut <- D.Dev.write(Out, d, off, v)
    return D.DevOut.dev(o)

def probe() -> V.Op<Out, Out>:
  do V.Op<Out, Out>:
    # reset, ACKNOWLEDGE, DRIVER
    d : D.Dev <- wr(D.Dev.new(D.RngKind{}), 112, 0)
    d : D.Dev <- wr(d, 112, 1)
    d : D.Dev <- wr(d, 112, 3)
    # feature negotiation: VERSION_1 is bit 32
    +d : D.Dev <- wr(d, 20, 1)
    +hi : U32 = rd(d, 16)
    +d : D.Dev <- wr(d, 20, 0)
    +lo : U32 = rd(d, 16)
    d : D.Dev <- wr(d, 36, 1)
    d : D.Dev <- wr(d, 32, 1)
    d : D.Dev <- wr(d, 36, 0)
    d : D.Dev <- wr(d, 32, 0)
    +d : D.Dev <- wr(d, 112, 11)
    neg : +List<U32> = [hi, lo, rd(d, 112)]
    # queue 0: 8 entries at 4096 / 8192 / 12288
    +d : D.Dev <- wr(d, 48, 0)
    +max : U32 = rd(d, 52)
    d : D.Dev <- wr(d, 56, 8)
    d : D.Dev <- wr(d, 128, 4096)
    d : D.Dev <- wr(d, 132, 0)
    d : D.Dev <- wr(d, 144, 8192)
    d : D.Dev <- wr(d, 148, 0)
    d : D.Dev <- wr(d, 160, 12288)
    d : D.Dev <- wr(d, 164, 0)
    +d : D.Dev <- wr(d, 68, 1)
    +ready : U32 = rd(d, 68)
    +before : U32 = nq(d)
    +d : D.Dev <- wr(d, 112, 15)
    setup : +List<U32> = [max, ready, before, nq(d)]
    built : Q.Vq = q0(d)
    # the request is posted in mem(): notify queue 0
    +d : D.Dev <- wr(d, 80, 0)
    notify : +List<U32> = [rd(d, 96), Bool.to_u32(D.Dev.irq(d))]
    +after : Q.Vq = q0(d)
    +d : D.Dev <- wr(d, 100, 1)
    ack : +List<U32> = [rd(d, 96), Bool.to_u32(D.Dev.irq(d))]
    # a notify of a missing queue does nothing
    +d : D.Dev <- wr(d, 80, 5)
    +isr5 : U32 = rd(d, 96)
    # reset clears the queues; a notify then does nothing
    +d : D.Dev <- wr(d, 112, 0)
    +d : D.Dev <- wr(d, 80, 0)
    reset : +List<U32> = [isr5, nq(d), rd(d, 112), rd(d, 68), rd(d, 96)]
    return Out{neg, setup, built, notify, ack, reset, after}

def check(r: Maybe<&1, S.Sim & Out>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("device ran", False{})
    case Some{(+s, o)}:
      match o:
        case Out{neg, setup, built, notify, ack, reset, after}:
          do IO<Unit>:
            T.eq_str("device features hi, lo, status", show(neg), "[1, 0, 11]")
            T.eq_str("device queue num_max, ready, queues before and after DRIVER_OK", show(setup), "[256, 1, 0, 1]")
            T.ok("device queue built", Q.Vq.is_eq(built, Q.Vq{8, u64(4096), u64(8192), u64(12288), 0, 0}))
            T.eq_str("device rng buffer", show(S.Sim.read(s, u64(16384), 5)), "[0, 1, 2, 3, 0]")
            T.eq_str("device used ring", show(S.Sim.read(s, u64(12288), 12)), "[0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0]")
            T.ok("device queue advanced", Q.Vq.is_eq(after, Q.Vq{8, u64(4096), u64(8192), u64(12288), 1, 1}))
            T.eq_str("device notify InterruptStatus, irq", show(notify), "[1, 1]")
            T.eq_str("device ack InterruptStatus, irq", show(ack), "[0, 0]")
            T.eq_str("device reset: isr after bad notify, queues, status, ready, isr", show(reset), "[0, 0, 0, 0, 0]")

def ids() -> IO(Unit):
  +r = D.Dev.new(D.RngKind{})
  +b = D.Dev.new(D.BlkKind{0, u64(2048)})
  do IO<Unit>:
    T.eq_u32("device magic", rd(r, 0), 1953655158)
    T.eq_u32("device version", rd(r, 4), 2)
    T.eq_u32("device rng id", rd(r, 8), 4)
    T.eq_u32("device vendor", rd(r, 12), 1145980226)
    T.eq_u32("device queue num_max", rd(r, 52), 256)
    T.eq_u32("device rng no config", rd(r, 256), 0)
    T.eq_u32("device blk id", rd(b, 8), 2)
    T.eq_u32("device blk capacity", rd(b, 256), 2048)
    T.eq_u32("device blk capacity high", rd(b, 260), 0)
    T.ok("device irq low", Bool.not(D.Dev.irq(r)))

# DeviceFeatures words (selector 1, then 0) and the id and capacity of a kind.
def feats(k: D.DevKind) -> V.Op<+List<U32>, +List<U32>>:
  do V.Op<+List<U32>, +List<U32>>:
    o : D.DevOut <- D.Dev.write(+List<U32>, D.Dev.new(k), 20, 1)
    +d : D.Dev = D.DevOut.dev(o)
    +hi : U32 = rd(d, 16)
    o : D.DevOut <- D.Dev.write(+List<U32>, d, 20, 0)
    +d : D.Dev = D.DevOut.dev(o)
    return [hi, rd(d, 16), rd(d, 8), rd(d, 256)]

def feats_of(r: Maybe<&1, S.Sim & +List<U32>>) -> +List<U32>:
  match r:
    case None{}:
      []
    case Some{(s, xs)}:
      xs

def kinds() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("device rng features hi, lo, id, config", show(feats_of(S.Sim.exec(+List<U32>, mem(), feats(D.RngKind{})))), "[1, 0, 4, 0]")
    T.eq_str("device blk features hi, lo, id, capacity", show(feats_of(S.Sim.exec(+List<U32>, mem(), feats(D.BlkKind{0, u64(2048)})))), "[1, 518, 2, 2048]")
    T.eq_str("device blk ro features hi, lo, id, capacity", show(feats_of(S.Sim.exec(+List<U32>, mem(), feats(D.BlkRoKind{0, u64(2048)})))), "[1, 550, 2, 2048]")

def main() -> IO(Unit):
  do IO<Unit>:
    ids()
    kinds()
    check(S.Sim.exec(Out, mem(), probe()))
