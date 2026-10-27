import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./mmio.bend as M
import ./queue.bend as Q
import ./rng.bend as Rng
import ./blk.bend as Blk
import ./console.bend as Con
import ./net.bend as N
import ../fs/p9.bend as P
import ./vsock.bend as Vs
import ./input.bend as In

# A virtio-mmio device: the transport register model plus the device logic
# behind it, as the machine sees it.
#
# Every kind offers VIRTIO_F_VERSION_1 (feature bit 32); queues hold 256
# entries:
#   RngKind:     device id 4, one queue, empty config space, no other feature
#   BlkKind:     device id 2, one queue, config space Blk.config(sectors),
#                also VIRTIO_BLK_F_FLUSH (Blk.features(False))
#   BlkRoKind:   a read-only BlkKind, also VIRTIO_BLK_F_RO
#                (Blk.features(True)); OUT requests answer IOERR
#   ConsoleKind: virtio-console, device id 3, two queues (0 receiveq0,
#                1 transmitq0), empty config space, no other feature
#   InputKind:   virtio-input, device id 18, two queues (0 eventq, 1
#                statusq), a keyboard or (tablet) a tablet; its config
#                space follows the driver's select/subsel writes
#                (In.Input.config)
#   NetKind:     virtio-net, device id 1, two queues (0 receiveq1,
#                1 transmitq1), also VIRTIO_NET_F_MAC, GUEST_CSUM and
#                GUEST_TSO4 (U.U64{1, 162}: see src/virtio/net.bend), config
#                space N.Net.config(mac)
#   P9Kind:      virtio-9p on host share `share`, device id 9, one queue,
#                also VIRTIO_9P_MOUNT_TAG (U.U64{1, 1}), config space
#                P.P9.config(tag)
#
# Dev.state holds what a kind keeps between passes: the console input not
# yet delivered, the frames for the guest not yet delivered (at most
# Dev.max_frames(), the oldest dropped first), the 9p server's state.
#
# Writes go to the transport (M.VirtioMmio.write), then:
#   DeviceReset: the queue list empties
#   DriverOk:    one Q.Vq per queue, from its QueueCfg (Q.Vq.from_cfg), in order
#   Notify{q}:   when queue q exists, the kind's pass runs on it and the
#                updated queue is stored; when it used any chain, interrupt
#                status bit 1 is raised (M.VirtioMmio.raise). Passes:
#                  Rng, Blk, BlkRo: Dev.process on its queue
#                  Console: queue 1 Con.tx (its bytes go to DevOut.console),
#                    queue 0 Con.rx with the pending input
#                  Net: queue 1 Net.tx (its frames go to DevOut.frames),
#                    queue 0 Net.rx with the pending frames
#                  P9: queue 0 P9.process
#   NoEvent:     nothing more

type DevKind is Data:
  RngKind{}
  BlkKind{disk: U32, sectors: U.U64}
  BlkRoKind{disk: U32, sectors: U.U64}
  ConsoleKind{}
  NetKind{mac: +List<U32>}
  P9Kind{share: U32, tag: String}
  VsockKind{cid: U.U64}
  InputKind{tablet: Bool}

# The per-kind state of a device.
type DevState is Data:
  NoState{}
  # Console input not yet delivered.
  ConState{input: +List<U32>}
  # Frames for the guest not yet delivered, oldest first.
  NetState{frames: +List<+List<U32>>}
  P9Dev{p9: P.P9State}
  VsState{vs: Vs.Vsock}
  InDev{input: In.InputState}

type Dev is Data:
  Dev{kind: DevKind, mmio: M.VirtioMmio, queues: +List<Q.Vq>, state: DevState}

# The device after a write, the bytes the guest wrote to hvc0 and the frames
# the guest transmitted, in order.
type DevOut is Data:
  DevOut{dev: Dev, console: +List<U32>, frames: +List<+List<U32>>, vsock: +List<V.VsockCmd>}

# VIRTIO_F_VERSION_1: bit 32, so bit 0 of the high word (the rng features).
def Dev.features() -> U.U64:
  U.U64{1, 0}

# The most frames a net device keeps for the guest.
def Dev.max_frames() -> Nat:
  256n

# The transport of a fresh device of the given kind.
def Dev.mmio(kind: DevKind) -> M.VirtioMmio:
  match kind:
    case RngKind{}:
      M.VirtioMmio.new(4, Dev.features(), 1n, 256, [])
    case BlkKind{disk, sectors}:
      M.VirtioMmio.new(2, Blk.Blk.features(False{}), 1n, 256, Blk.Blk.config(sectors))
    case BlkRoKind{disk, sectors}:
      M.VirtioMmio.new(2, Blk.Blk.features(True{}), 1n, 256, Blk.Blk.config(sectors))
    case ConsoleKind{}:
      M.VirtioMmio.new(3, Dev.features(), 2n, 256, [])
    case NetKind{mac}:
      M.VirtioMmio.new(1, U.U64{1, 162}, 2n, 256, N.Net.config(mac))
    case P9Kind{share, tag}:
      M.VirtioMmio.new(9, U.U64{1, 1}, 1n, 256, P.P9.config(tag))
    case VsockKind{cid}:
      M.VirtioMmio.new(19, Dev.features(), 3n, 256, Vs.Vs.config(cid))
    case InputKind{tablet}:
      M.VirtioMmio.new(18, Dev.features(), 2n, 256, In.Input.config(tablet, 0, 0))

# The state of a fresh device of the given kind.
def Dev.state(kind: DevKind) -> DevState:
  match kind:
    case RngKind{}:
      NoState{}
    case BlkKind{disk, sectors}:
      NoState{}
    case BlkRoKind{disk, sectors}:
      NoState{}
    case ConsoleKind{}:
      ConState{[]}
    case NetKind{mac}:
      NetState{[]}
    case P9Kind{share, tag}:
      P9Dev{P.P9State.new()}
    case VsockKind{cid}:
      VsState{Vs.Vsock.new(cid)}
    case InputKind{tablet}:
      InDev{In.InputState.new()}

def Dev.new(kind: DevKind) -> Dev:
  +kind = kind
  Dev{kind, Dev.mmio(kind), [], Dev.state(kind)}

def Dev.read.fin(k: DevKind, qs: +List<Q.Vq>, st: DevState, r: M.VirtioMmio & U32) -> Dev & U32:
  match r:
    case (m, v):
      (Dev{k, m, qs, st}, v)

def Dev.read(d: Dev, off: U32, size: U32) -> Dev & U32:
  match d:
    case Dev{k, m, qs, st}:
      Dev.read.fin(k, qs, st, M.VirtioMmio.read(m, off, size))

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

# Runs the process of a kind without state on a queue. The kinds with state
# (console, net, 9p) run their passes in Dev.pass instead; here they use no
# chain.
def Dev.process(-R: Type, k: DevKind, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  match k:
    case RngKind{}:
      Rng.Rng.process(R, q)
    case BlkKind{disk, sectors}:
      Blk.Blk.process(R, disk, sectors, q)
    case BlkRoKind{disk, sectors}:
      Blk.Blk.serve(R, disk, sectors, True{}, q)
    case ConsoleKind{}:
      V.Op.pure(R, Q.Vq & Bool, (q, False{}))
    case NetKind{mac}:
      V.Op.pure(R, Q.Vq & Bool, (q, False{}))
    case P9Kind{share, tag}:
      V.Op.pure(R, Q.Vq & Bool, (q, False{}))
    case VsockKind{cid}:
      V.Op.pure(R, Q.Vq & Bool, (q, False{}))
    case InputKind{tablet}:
      V.Op.pure(R, Q.Vq & Bool, (q, False{}))

# The pending console input of a state (none for other kinds).
def Dev.input_of(st: DevState) -> +List<U32>:
  match st:
    case ConState{bs}:
      bs
    case NoState{}:
      []
    case NetState{fs}:
      []
    case P9Dev{p}:
      []
    case VsState{v}:
      []
    case InDev{i}:
      []

# The pending frames of a state (none for other kinds).
def Dev.frames_of(st: DevState) -> +List<+List<U32>>:
  match st:
    case NetState{fs}:
      fs
    case NoState{}:
      []
    case ConState{bs}:
      []
    case P9Dev{p}:
      []
    case VsState{v}:
      []
    case InDev{i}:
      []

# The 9p server state of a state (a fresh one for other kinds).
def Dev.p9_of(st: DevState) -> P.P9State:
  match st:
    case P9Dev{p}:
      p
    case NoState{}:
      P.P9State.new()
    case ConState{bs}:
      P.P9State.new()
    case NetState{fs}:
      P.P9State.new()
    case VsState{v}:
      P.P9State.new()
    case InDev{i}:
      P.P9State.new()

# The last Dev.max_frames() frames.
def Dev.cap(+fs: +List<+List<U32>>) -> +List<+List<U32>>:
  List.drop(&2, +List<U32>, fs, Nat.sub(List.length(&2, +List<U32>, fs), Dev.max_frames()))

# What a pass on one queue did: the queue, the new state, the bytes for the
# host console, the frames for the host, and whether it used any chain.
type Pass is Data:
  Pass{q: Q.Vq, state: DevState, console: +List<U32>, frames: +List<+List<U32>>, vsock: +List<V.VsockCmd>, used: Bool}

def Dev.pass.plain(st: DevState, r: Q.Vq & Bool) -> Pass:
  match r:
    case (q, used):
      Pass{q, st, [], [], [], used}

def Dev.pass.con_tx(st: DevState, r: Con.ConTx) -> Pass:
  match r:
    case Con.ConTx{q, bs, used}:
      Pass{q, st, bs, [], [], used}

def Dev.pass.con_rx(r: Con.ConRx) -> Pass:
  match r:
    case Con.ConRx{q, left, used}:
      Pass{q, ConState{left}, [], [], [], used}

def Dev.pass.net_tx(st: DevState, r: N.NetTx) -> Pass:
  match r:
    case N.NetTx{q, fs, used}:
      Pass{q, st, [], fs, [], used}

def Dev.pass.net_rx(r: N.NetRx) -> Pass:
  match r:
    case N.NetRx{q, left, used}:
      Pass{q, NetState{left}, [], [], [], used}

def Dev.pass.p9(r: P.P9Pass) -> Pass:
  match r:
    case P.P9Pass{s, q, used}:
      Pass{q, P9Dev{s}, [], [], [], used}

# The console's pass: transmitq0 (tx) or receiveq0.
def Dev.pass.con(-R: Type, tx: Bool, st: DevState, q: Q.Vq) -> V.Op<R, Pass>:
  match tx:
    case True{}:
      do V.Op<R, Pass>:
        r : Con.ConTx <- Con.Con.tx(R, q)
        return Dev.pass.con_tx(st, r)
    case False{}:
      do V.Op<R, Pass>:
        r : Con.ConRx <- Con.Con.rx(R, q, Dev.input_of(st))
        return Dev.pass.con_rx(r)

# The net device's pass: transmitq1 (tx) or receiveq1.
def Dev.pass.net(-R: Type, tx: Bool, st: DevState, q: Q.Vq) -> V.Op<R, Pass>:
  match tx:
    case True{}:
      do V.Op<R, Pass>:
        r : N.NetTx <- N.Net.tx(R, q)
        return Dev.pass.net_tx(st, r)
    case False{}:
      do V.Op<R, Pass>:
        r : N.NetRx <- N.Net.rx(R, q, Dev.frames_of(st))
        return Dev.pass.net_rx(r)

# The vsock state of a state (a fresh one, CID 3, for other kinds).
def Dev.vs_of(st: DevState) -> Vs.Vsock:
  match st:
    case VsState{v}:
      v
    case NoState{}:
      Vs.Vsock.new(U.U64{0, 3})
    case ConState{bs}:
      Vs.Vsock.new(U.U64{0, 3})
    case NetState{fs}:
      Vs.Vsock.new(U.U64{0, 3})
    case P9Dev{p}:
      Vs.Vsock.new(U.U64{0, 3})
    case InDev{i}:
      Vs.Vsock.new(U.U64{0, 3})

def Dev.pass.vs_tx(r: Vs.VsTx) -> Pass:
  match r:
    case Vs.VsTx{v, q, cmds, used}:
      Pass{q, VsState{v}, [], [], cmds, used}

def Dev.pass.vs_rx(r: Vs.VsRx) -> Pass:
  match r:
    case Vs.VsRx{v, q, used}:
      Pass{q, VsState{v}, [], [], [], used}

# The vsock device's pass: tx (queue 1), rx (queue 0); the event queue (2)
# is never used.
def Dev.pass.vsock(-R: Type, tx: Bool, rx: Bool, st: DevState, q: Q.Vq) -> V.Op<R, Pass>:
  match tx rx:
    case True{} _:
      do V.Op<R, Pass>:
        r : Vs.VsTx <- Vs.Vsock.tx(R, Dev.vs_of(st), q)
        return Dev.pass.vs_tx(r)
    case False{} True{}:
      do V.Op<R, Pass>:
        r : Vs.VsRx <- Vs.Vsock.rx(R, Dev.vs_of(st), q)
        return Dev.pass.vs_rx(r)
    case False{} False{}:
      V.Op.pure(R, Pass, Pass{q, st, [], [], [], False{}})

# The input state of a state (a fresh one for other kinds).
def Dev.in_of(st: DevState) -> In.InputState:
  match st:
    case InDev{i}:
      i
    case _:
      In.InputState.new()

def Dev.pass.in_rx(r: In.InRx) -> Pass:
  match r:
    case In.InRx{s, q, used}:
      Pass{q, InDev{s}, [], [], [], used}

def Dev.pass.in_status(st: DevState, r: Con.ConTx) -> Pass:
  match r:
    case Con.ConTx{q, bs, used}:
      Pass{q, st, [], [], [], used}

# The input device's pass: eventq (ev) gets the pending events; statusq
# chains are taken and dropped.
def Dev.pass.input(-R: Type, ev: Bool, st: DevState, q: Q.Vq) -> V.Op<R, Pass>:
  match ev:
    case True{}:
      do V.Op<R, Pass>:
        r : In.InRx <- In.Input.rx(R, Dev.in_of(st), q)
        return Dev.pass.in_rx(r)
    case False{}:
      do V.Op<R, Pass>:
        r : Con.ConTx <- Con.Con.tx(R, q)
        return Dev.pass.in_status(st, r)

# Runs the kind's pass on queue sel (q).
def Dev.pass(-R: Type, k: DevKind, st: DevState, +sel: U32, q: Q.Vq) -> V.Op<R, Pass>:
  match k:
    case ConsoleKind{}:
      Dev.pass.con(R, U32.is_eq(sel, 1), st, q)
    case NetKind{mac}:
      Dev.pass.net(R, U32.is_eq(sel, 1), st, q)
    case P9Kind{share, tag}:
      do V.Op<R, Pass>:
        r : P.P9Pass <- P.P9.process(R, share, Dev.p9_of(st), q)
        return Dev.pass.p9(r)
    case VsockKind{cid}:
      Dev.pass.vsock(R, U32.is_eq(sel, 1), U32.is_eq(sel, 0), st, q)
    case InputKind{tablet}:
      Dev.pass.input(R, U32.is_eq(sel, 0), st, q)
    case RngKind{}:
      do V.Op<R, Pass>:
        r : Q.Vq & Bool <- Dev.process(R, RngKind{}, q)
        return Dev.pass.plain(st, r)
    case BlkKind{disk, sectors}:
      do V.Op<R, Pass>:
        r : Q.Vq & Bool <- Dev.process(R, BlkKind{disk, sectors}, q)
        return Dev.pass.plain(st, r)
    case BlkRoKind{disk, sectors}:
      do V.Op<R, Pass>:
        r : Q.Vq & Bool <- Dev.process(R, BlkRoKind{disk, sectors}, q)
        return Dev.pass.plain(st, r)

# A device with nothing for the host.
def Dev.out(d: Dev) -> DevOut:
  DevOut{d, [], [], []}

def Dev.notify.fin(k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, sel: U32, r: Pass) -> DevOut:
  match r:
    case Pass{q, st, bs, fs, vc, used}:
      DevOut{Dev{k, Dev.raise_if(used, m), Dev.qput(qs, 0, sel, q), st}, bs, fs, vc}

# Runs the pass on queue sel when it exists.
def Dev.notify(-R: Type, mq: Maybe<&2, Q.Vq>, +k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState, +sel: U32) -> V.Op<R, DevOut>:
  match mq:
    case None{}:
      V.Op.pure(R, DevOut, Dev.out(Dev{k, m, qs, st}))
    case Some{q}:
      do V.Op<R, DevOut>:
        r : Pass <- Dev.pass(R, k, st, sel, q)
        return Dev.notify.fin(k, m, qs, sel, r)

# Acts on the event of a transport write.
def DevOut.dev(o: DevOut) -> Dev:
  match o:
    case DevOut{d, bs, fs, vc}:
      d

def Dev.flush(-R: Type, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState) -> V.Op<R, Dev>:
  +qs = qs
  do V.Op<R, Dev>:
    o : DevOut <- Dev.notify(R, Dev.qget(qs, 0, 0), k, m, qs, st, 0)
    return DevOut.dev(o)

def Dev.after.vsock(-R: Type, again: Bool, o: DevOut) -> V.Op<R, DevOut>:
  match again:
    case False{}:
      V.Op.pure(R, DevOut, o)
    case True{}:
      match o:
        case DevOut{Dev{k, m, qs, st}, bs, fs, vc}:
          do V.Op<R, DevOut>:
            d : Dev <- Dev.flush(R, k, m, qs, st)
            return DevOut{d, bs, fs, vc}

def Dev.is_vsock(k: DevKind) -> Bool:
  match k:
    case VsockKind{cid}:
      True{}
    case _:
      False{}

def Dev.on_event(-R: Type, ev: M.MmioEvent, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState) -> V.Op<R, DevOut>:
  match ev:
    case M.NoEvent{}:
      V.Op.pure(R, DevOut, Dev.out(Dev{k, m, qs, st}))
    case M.DeviceReset{}:
      V.Op.pure(R, DevOut, Dev.out(Dev{k, m, [], st}))
    case M.DriverOk{}:
      +m = m
      V.Op.pure(R, DevOut, Dev.out(Dev{k, m, Dev.build(Dev.cfgs(m)), st}))
    case M.Notify{+q}:
      +qs = qs
      +k = k
      do V.Op<R, DevOut>:
        o : DevOut <- Dev.notify(R, Dev.qget(qs, 0, q), k, m, qs, st, q)
        Dev.after.vsock(R, Dev.is_vsock(k) && U32.is_eq(q, 1), o)

def Dev.write.fin(-R: Type, k: DevKind, qs: +List<Q.Vq>, st: DevState, r: M.VirtioMmio & M.MmioEvent) -> V.Op<R, DevOut>:
  match r:
    case (m, ev):
      Dev.on_event(R, ev, k, m, qs, st)

def Dev.is_input(k: DevKind) -> Bool:
  match k:
    case InputKind{tablet}:
      True{}
    case _:
      False{}

def Dev.tablet_of(k: DevKind) -> Bool:
  match k:
    case InputKind{tablet}:
      tablet
    case _:
      False{}

# A write to an input device's select or subsel byte rebuilds its config
# space; other writes go to the transport.
def Dev.write.go(-R: Type, select: Bool, +k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState, +off: U32, v: U32) -> V.Op<R, DevOut>:
  match select:
    case True{}:
      +s = In.Input.select(Dev.in_of(st), (off - 256 : U32), v)
      V.Op.pure(R, DevOut, Dev.out(Dev{k, M.VirtioMmio.with_config(m, In.InputState.config(Dev.tablet_of(k), s)), qs, InDev{s}}))
    case False{}:
      Dev.write.fin(R, k, qs, st, M.VirtioMmio.write(m, off, v))

def Dev.write(-R: Type, d: Dev, +off: U32, v: U32) -> V.Op<R, DevOut>:
  match d:
    case Dev{+k, m, qs, st}:
      Dev.write.go(R, Dev.is_input(k) && (U32.is_eq(off, 256) || U32.is_eq(off, 257)), k, m, qs, st, off, v)

# Delivers a device's pending input or frames into its queue 0, when it
# exists.
def Dev.is_console(k: DevKind) -> Bool:
  match k:
    case ConsoleKind{}:
      True{}
    case RngKind{}:
      False{}
    case BlkKind{disk, sectors}:
      False{}
    case BlkRoKind{disk, sectors}:
      False{}
    case NetKind{mac}:
      False{}
    case P9Kind{share, tag}:
      False{}
    case VsockKind{cid}:
      False{}
    case InputKind{tablet}:
      False{}

def Dev.is_net(k: DevKind) -> Bool:
  match k:
    case NetKind{mac}:
      True{}
    case RngKind{}:
      False{}
    case BlkKind{disk, sectors}:
      False{}
    case BlkRoKind{disk, sectors}:
      False{}
    case ConsoleKind{}:
      False{}
    case P9Kind{share, tag}:
      False{}
    case VsockKind{cid}:
      False{}
    case InputKind{tablet}:
      False{}

def Dev.input.go(-R: Type, console: Bool, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState, bytes: +List<U32>) -> V.Op<R, Dev>:
  match console:
    case True{}:
      Dev.flush(R, k, m, qs, ConState{List.append(&2, U32, Dev.input_of(st), bytes)})
    case False{}:
      V.Op.pure(R, Dev, Dev{k, m, qs, st})

# Bytes typed on the host console: a console device appends them to its
# pending input and delivers what fits into receiveq0 (raising interrupt
# status bit 1 when it used a chain). Other kinds are unchanged.
def Dev.input(-R: Type, d: Dev, bytes: +List<U32>) -> V.Op<R, Dev>:
  match d:
    case Dev{+k, m, qs, st}:
      Dev.input.go(R, Dev.is_console(k), k, m, qs, st, bytes)

def Dev.deliver.go(-R: Type, net: Bool, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState, frames: +List<+List<U32>>) -> V.Op<R, Dev>:
  match net:
    case True{}:
      Dev.flush(R, k, m, qs, NetState{Dev.cap(List.append(&2, +List<U32>, Dev.frames_of(st), frames))})
    case False{}:
      V.Op.pure(R, Dev, Dev{k, m, qs, st})

# Frames for the guest: a net device appends them to its pending frames
# (keeping the last Dev.max_frames()) and delivers what it can into
# receiveq1 (raising interrupt status bit 1 when it used a chain). Other
# kinds are unchanged.
def Dev.deliver(-R: Type, d: Dev, frames: +List<+List<U32>>) -> V.Op<R, Dev>:
  match d:
    case Dev{+k, m, qs, st}:
      Dev.deliver.go(R, Dev.is_net(k), k, m, qs, st, frames)

# Whether the device is a net device.
def Dev.net(d: Dev) -> Bool:
  match d:
    case Dev{k, m, qs, st}:
      Dev.is_net(k)

# The number of frames a net device holds for the guest (0 for other kinds).
def Dev.backlog(d: Dev) -> U32:
  match d:
    case Dev{k, m, qs, st}:
      U32.from_nat(List.length(&2, +List<U32>, Dev.frames_of(st)))

# Whether the device is a vsock device.
def Dev.vsock(d: Dev) -> Bool:
  match d:
    case Dev{k, m, qs, st}:
      Dev.is_vsock(k)

def Dev.big.mmio(m: M.VirtioMmio) -> Bool:
  match m:
    case M.VirtioMmio{id, df, U.U64{dh, dl}, dfs, drs, qs, cfgs, st, ist, cg, cfg}:
      U32.is_eq((dl .&. 130 : U32), 130)

# Whether a net device's driver took GUEST_CSUM and GUEST_TSO4 (bits 1 and
# 7): it then receives TCP segments of up to 64 KiB as host frames.
def Dev.big(d: Dev) -> Bool:
  match d:
    case Dev{k, m, qs, st}:
      Dev.is_net(k) && Dev.big.mmio(m)

# A vsock device's backlog (Vs.Vsock.backlog; 0 for other kinds).
def Dev.vsock_backlog(d: Dev) -> U32:
  match d:
    case Dev{k, m, qs, st}:
      Vs.Vsock.backlog(Dev.vs_of(st))

def Dev.host_vsock.fin(-R: Type, k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, o: Vs.VsOut) -> V.Op<R, DevOut>:
  match o:
    case Vs.VsOut{v, cmds}:
      do V.Op<R, DevOut>:
        d : Dev <- Dev.flush(R, k, m, qs, VsState{v})
        return DevOut{d, [], [], cmds}

# An event from the host's vsock sockets: through the protocol, then the
# packets it queued go into the rx queue. Other kinds are unchanged.
def Dev.host_vsock(-R: Type, d: Dev, ev: V.VsockEvent) -> V.Op<R, DevOut>:
  match d:
    case Dev{k, m, qs, st}:
      Dev.host_vsock.fin(R, k, m, qs, Vs.Vsock.host_event(Dev.vs_of(st), ev))

# After a vsock tx pass, the replies it queued go out through the rx queue.
# The interrupt line's level.
def Dev.irq(d: Dev) -> Bool:
  match d:
    case Dev{k, m, qs, st}:
      M.VirtioMmio.irq(m)

def Dev.hid.go(-R: Type, input: Bool, +k: DevKind, m: M.VirtioMmio, qs: +List<Q.Vq>, st: DevState, ev: In.Hid) -> V.Op<R, Dev>:
  match input:
    case True{}:
      Dev.flush(R, k, m, qs, InDev{In.Input.push(Dev.tablet_of(k), Dev.in_of(st), ev)})
    case False{}:
      V.Op.pure(R, Dev, Dev{k, m, qs, st})

# A keyboard or pointer report from the host: an input device queues its
# events (In.Input.push: the keyboard takes keys, the tablet moves and
# buttons) and delivers what fits into eventq. Other kinds are unchanged.
def Dev.hid(-R: Type, d: Dev, ev: In.Hid) -> V.Op<R, Dev>:
  match d:
    case Dev{+k, m, qs, st}:
      Dev.hid.go(R, Dev.is_input(k), k, m, qs, st, ev)
