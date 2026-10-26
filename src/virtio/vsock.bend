import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-vsock (Virtio 1.2 section 5.10), device id 19: stream sockets
# between the guest (CID from the config) and the host (CID 2). Offered
# features: VIRTIO_F_VERSION_1 only. Queues: 0 rx (host to guest), 1 tx
# (guest to host), 2 event (unused). Config: guest_cid, a little-endian u64.
#
# Every packet is a 44-byte little-endian header, then `len` payload bytes:
#   src_cid u64, dst_cid u64, src_port u32, dst_port u32, len u32,
#   type u16 (1 STREAM), op u16, flags u32, buf_alloc u32, fwd_cnt u32
# ops: 1 REQUEST, 2 RESPONSE, 3 RST, 4 SHUTDOWN, 5 RW, 6 CREDIT_UPDATE,
# 7 CREDIT_REQUEST. SHUTDOWN flags: 1 the sender will receive no more, 2 it
# will send no more.
#
# Flow control: each side advertises buf_alloc (its receive buffer) and
# fwd_cnt (bytes it has consumed); a sender may have at most
# buf_alloc - (sent - fwd_cnt) bytes in flight. This device hands guest data
# to the host at once, so it consumes everything it receives, advertises
# 256 KiB, and sends a CREDIT_UPDATE whenever half of that has been consumed
# since the last one. Host data waits per connection until the guest's credit
# allows it, in packets of at most 4096 payload bytes.

def Vs.host_cid() -> U32:
  2

def Vs.buf_alloc() -> U32:
  262144

def Vs.max_payload() -> U32:
  4096

def Vs.request() -> U32:
  1
def Vs.response() -> U32:
  2
def Vs.rst() -> U32:
  3
def Vs.shutdown() -> U32:
  4
def Vs.rw() -> U32:
  5
def Vs.credit_update() -> U32:
  6
def Vs.credit_request() -> U32:
  7

def Vs.config(cid: U.U64) -> +List<U32>:
  B.Bytes.le64(cid)

# Packets
# =======

type Pkt is Data:
  Pkt{src_cid: U.U64, dst_cid: U.U64, src_port: U32, dst_port: U32, op: U32, flags: U32, buf_alloc: U32, fwd_cnt: U32, payload: +List<U32>}

def Pkt.build(p: Pkt) -> +List<U32>:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, +pl}:
      +a = {List.append(&2, U32, B.Bytes.le64(sc), B.Bytes.le64(dc)) : +List<U32>}
      +b = {List.append(&2, U32, B.Bytes.le32(sp), List.append(&2, U32, B.Bytes.le32(dp), B.Bytes.le32(U32.from_nat(List.length(&2, U32, pl))))) : +List<U32>}
      +c = {List.append(&2, U32, B.Bytes.le16(1), List.append(&2, U32, B.Bytes.le16(op), List.append(&2, U32, B.Bytes.le32(fl), List.append(&2, U32, B.Bytes.le32(ba), B.Bytes.le32(fc))))) : +List<U32>}
      List.append(&2, U32, a, List.append(&2, U32, b, List.append(&2, U32, c, pl)))

def Pkt.parse.ok(ok: Bool, +bs: +List<U32>) -> Maybe<&2, Pkt>:
  match ok:
    case False{}:
      None{}
    case True{}:
      +len = U32.to_nat(B.Bytes.read_le32(B.Bytes.slice(bs, 24n, 4n)))
      Some{Pkt{B.Bytes.read_le64(bs), B.Bytes.read_le64(List.drop(&2, U32, bs, 8n)), B.Bytes.read_le32(B.Bytes.slice(bs, 16n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 20n, 4n)), B.Bytes.read_le16(B.Bytes.slice(bs, 30n, 2n)), B.Bytes.read_le32(B.Bytes.slice(bs, 32n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 36n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 40n, 4n)), B.Bytes.slice(bs, 44n, len)}}

# A packet from its bytes; None when shorter than its header plus len.
def Pkt.parse(+bs: +List<U32>) -> Maybe<&2, Pkt>:
  +n = List.length(&2, U32, bs)
  +len = U32.to_nat(B.Bytes.read_le32(B.Bytes.slice(bs, 24n, 4n)))
  Pkt.parse.ok(Nat.is_le(44n, n) && Nat.is_le(Nat.add(44n, len), n), bs)

# Connections
# ===========

# state: 0 connecting (the guest asked; the host has not connected yet),
# 1 established, 2 requested (the host asked; the guest has not answered).
# tx: payload bytes sent to the guest; peer_alloc/peer_fwd: the guest's
# last advertised credit; fwd: guest bytes consumed; last_fwd: the fwd_cnt
# last advertised; pending: host bytes waiting for credit; eof: the host
# finished sending (a SHUTDOWN follows once pending drains).
type VConn is Data:
  VConn{id: U32, gport: U32, hport: U32, state: U32, tx: U32, peer_alloc: U32, peer_fwd: U32, fwd: U32, last_fwd: U32, pending: +List<U32>, eof: Bool}

# The device's state: the guest CID, connections, the next connection
# number and host port for host-initiated ones, and packets for the guest,
# oldest first.
type Vsock is Data:
  Vsock{cid: U.U64, conns: +List<VConn>, next_id: U32, next_port: U32, out: +List<+List<U32>>}

type VsOut is Data:
  VsOut{vs: Vsock, cmds: +List<V.VsockCmd>}

def Vsock.new(cid: U.U64) -> Vsock:
  Vsock{cid, [], 0, 1024, []}

# A packet of connection c to the guest.
def VConn.pkt(+cid: U.U64, c: VConn, op: U32, flags: U32, payload: +List<U32>) -> +List<U32>:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      Pkt.build(Pkt{U.U64{0, Vs.host_cid()}, cid, hp, gp, op, flags, Vs.buf_alloc(), fwd, payload})

# A reply to a packet with no connection: RST with the ports swapped.
def Vs.rst_for(+cid: U.U64, p: Pkt) -> +List<U32>:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}:
      Pkt.build(Pkt{U.U64{0, Vs.host_cid()}, cid, dp, sp, Vs.rst(), 0, Vs.buf_alloc(), 0, []})

def VConn.id(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      id

def VConn.matches(c: VConn, +gport: U32, +hport: U32) -> Bool:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      U32.is_eq(gp, gport) && U32.is_eq(hp, hport)

# The connection with these ports and the others.
type Pick is Data:
  Pick{conn: Maybe<&2, VConn>, rest: +List<VConn>}

def Pick.add(c: VConn, p: Pick) -> Pick:
  match p:
    case Pick{found, rest}:
      Pick{found, c <> rest}

def Pick.got(hit: Bool, +c: VConn, rest: +List<VConn>, more: Pick) -> Pick:
  match hit:
    case True{}:
      Pick{Some{c}, rest}
    case False{}:
      Pick.add(c, more)

def Vs.pick_ports(cs: +List<VConn>, +gport: U32, +hport: U32) -> Pick:
  match cs:
    case Nil{}:
      Pick{None{}, []}
    case Con{+c, +rest}:
      Pick.got(VConn.matches(c, gport, hport), c, rest, Vs.pick_ports(rest, gport, hport))

def Vs.pick_id(cs: +List<VConn>, +id: U32) -> Pick:
  match cs:
    case Nil{}:
      Pick{None{}, []}
    case Con{+c, +rest}:
      Pick.got(U32.is_eq(VConn.id(c), id), c, rest, Vs.pick_id(rest, id))

# Credit and the data waiting for it
# ==================================

def VConn.credit(c: VConn, +alloc: U32, +fwd_cnt: U32) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      VConn{id, gp, hp, st, tx, alloc, fwd_cnt, fwd, lf, pend, eof}

# What a connection can send now: min(credit, 4096, pending).
def VConn.room(c: VConn) -> Nat:
  match c:
    case VConn{id, gp, hp, st, +tx, +pa, +pf, fwd, lf, +pend, eof}:
      +inflight = (tx - pf : U32)
      +free = Bool.pick(U32, U32.is_lt(pa, inflight), 0, (pa - inflight : U32))
      Nat.min(U32.to_nat(U32.min(free, Vs.max_payload())), List.length(&2, U32, pend))

type Flushed is Data:
  Flushed{conn: VConn, pkts: +List<+List<U32>>}

def Flushed.add(p: +List<U32>, f: Flushed) -> Flushed:
  match f:
    case Flushed{c, ps}:
      Flushed{c, p <> ps}

# The host has finished and every byte went out.
def VConn.drained(c: VConn) -> Bool:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      eof && List.is_empty(&2, U32, pend)

def VConn.flush.eof.go(done: Bool, c: VConn, +cid: U.U64) -> Flushed:
  match done:
    case True{}:
      match c:
        case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
          +c2 = {VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, [], False{}} : VConn}
          Flushed{c2, [VConn.pkt(cid, c2, Vs.shutdown(), 2, [])]}
    case False{}:
      Flushed{c, []}

def VConn.flush.eof(+c: VConn, +cid: U.U64) -> Flushed:
  VConn.flush.eof.go(VConn.drained(c), c, cid)

# Sends as much pending host data as the guest's credit allows (n bytes now,
# none when n is 0), then the SHUTDOWN the host's EOF asked for once nothing
# is left. Fuel: one step per packet (pending / 4096 + 2 suffices).
def VConn.flush(fuel: Nat, none: Bool, +n: Nat, c: VConn, +cid: U.U64) -> Flushed:
  match fuel none:
    case 0n _:
      Flushed{c, []}
    case 1n+f True{}:
      VConn.flush.eof(c, cid)
    case 1n+f False{}:
      match c:
        case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, +pend, eof}:
          +chunk = List.take(&2, U32, pend, n)
          +c2 = {VConn{id, gp, hp, st, (tx + U32.from_nat(n) : U32), pa, pf, fwd, lf, List.drop(&2, U32, pend, n), eof} : VConn}
          +m = VConn.room(c2)
          Flushed.add(VConn.pkt(cid, c2, Vs.rw(), 0, chunk), VConn.flush(f, Nat.is_eq(m, 0n), m, c2, cid))

def VConn.flush.all(c: VConn, +cid: U.U64) -> Flushed:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, +pend, eof}:
      +fuel = Nat.add(Nat.div(List.length(&2, U32, pend), 4096n), 2n)
      +c2 = {VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof} : VConn}
      +m = VConn.room(c2)
      VConn.flush(fuel, Nat.is_eq(m, 0n), m, c2, cid)

# Results
# =======

def Vsock.with(vs: Vsock, conns: +List<VConn>, out: +List<+List<U32>>) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, old}:
      Vsock{cid, conns, nid, np, List.append(&2, +List<U32>, old, out)}

def Vsock.cid(vs: Vsock) -> U.U64:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      cid

def Vsock.conns(vs: Vsock) -> +List<VConn>:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      cs

# Keeps a flushed connection and queues its packets.
def Vsock.keep(vs: Vsock, rest: +List<VConn>, f: Flushed, cmds: +List<V.VsockCmd>) -> VsOut:
  match f:
    case Flushed{c, ps}:
      VsOut{Vsock.with(vs, c <> rest, ps), cmds}

# Guest packets
# =============

def Vs.new_conn(vs: Vsock, +p: Pkt) -> VsOut:
  match vs p:
    case Vsock{cid, cs, +nid, np, out} Pkt{sc, dc, +sp, +dp, op, fl, ba, fc, pl}:
      +c = {VConn{nid, sp, dp, 0, 0, ba, fc, 0, 0, [], False{}} : VConn}
      VsOut{Vsock{cid, c <> cs, (nid + 1 : U32), np, out}, [V.VsConnect{nid, dp}]}

# RW: the payload goes to the host; a CREDIT_UPDATE follows once half the
# advertised buffer has been consumed since the last one.
def Vs.rw_in.fin(update: Bool, vs: Vsock, +c: VConn, +cid: U.U64, cmds: +List<V.VsockCmd>) -> VsOut:
  match update:
    case True{}:
      VsOut{Vsock.with(vs, [], [VConn.pkt(cid, c, Vs.credit_update(), 0, [])]), cmds}
    case False{}:
      VsOut{vs, cmds}

def Vs.rw_in(+vs: Vsock, rest: +List<VConn>, c: VConn, payload: +List<U32>) -> VsOut:
  match c:
    case VConn{+id, gp, hp, st, tx, pa, pf, fwd, +lf, pend, eof}:
      +payload = payload
      +fwd2 = (fwd + U32.from_nat(List.length(&2, U32, payload)) : U32)
      +update = U32.is_le((Vs.buf_alloc() >> 1n : U32), (fwd2 - lf : U32))
      +c2 = {VConn{id, gp, hp, st, tx, pa, pf, fwd2, Bool.pick(U32, update, fwd2, lf), pend, eof} : VConn}
      +cid = Vsock.cid(vs)
      Vs.rw_in.fin(update, Vsock.with(vs, c2 <> rest, []), c2, cid, [V.VsSend{id, payload}])

def VConn.state(c: VConn, st: U32) -> VConn:
  match c:
    case VConn{id, gp, hp, old, tx, pa, pf, fwd, lf, pend, eof}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}

def VConn.hport(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      hp

# Marks the current fwd_cnt as advertised.
def VConn.last_fwd(c: VConn) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, +fwd, lf, pend, eof}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, fwd, pend, eof}

# SHUTDOWN from the guest: "will send no more" half-closes the host side;
# both flags end the connection (an RST answers, as the spec expects).
def Vs.shutdown_in(both: Bool, no_send: Bool, vs: Vsock, rest: +List<VConn>, +c: VConn, +cid: U.U64) -> VsOut:
  match both no_send:
    case True{} _:
      +id = VConn.id(c)
      VsOut{Vsock.with(vs, rest, [VConn.pkt(cid, c, Vs.rst(), 0, [])]), [V.VsShutdown{id}, V.VsClose{id}]}
    case False{} True{}:
      VsOut{Vsock.with(vs, c <> rest, []), [V.VsShutdown{VConn.id(c)}]}
    case False{} False{}:
      VsOut{Vsock.with(vs, c <> rest, []), []}

def Pkt.op(p: Pkt) -> U32:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}:
      op

def Pkt.flags(p: Pkt) -> U32:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}:
      fl

def Pkt.payload(p: Pkt) -> +List<U32>:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}:
      pl

def Vs.known.by(rw: Bool, rst: Bool, sd: Bool, resp: Bool, creq: Bool, +vs: Vsock, rest: +List<VConn>, +c: VConn, +p: Pkt) -> VsOut:
  match rw rst sd resp creq:
    case True{} _ _ _ _:
      Vs.rw_in(vs, rest, c, Pkt.payload(p))
    case False{} True{} _ _ _:
      VsOut{Vsock.with(vs, rest, []), [V.VsClose{VConn.id(c)}]}
    case False{} False{} True{} _ _:
      +fl = Pkt.flags(p)
      Vs.shutdown_in(U32.is_eq(fl, 3), U32.is_ne((fl .&. 2 : U32), 0), vs, rest, c, Vsock.cid(vs))
    case False{} False{} False{} True{} _:
      +c2 = VConn.state(c, 1)
      Vsock.keep(vs, rest, VConn.flush.all(c2, Vsock.cid(vs)), [V.VsAccepted{VConn.id(c), VConn.hport(c2)}])
    case False{} False{} False{} False{} True{}:
      +c2 = VConn.last_fwd(c)
      VsOut{Vsock.with(vs, c2 <> rest, [VConn.pkt(Vsock.cid(vs), c2, Vs.credit_update(), 0, [])]), []}
    case False{} False{} False{} False{} False{}:
      # CREDIT_UPDATE (or anything else): the new credit may let data out
      Vsock.keep(vs, rest, VConn.flush.all(c, Vsock.cid(vs)), [])

# A guest packet for a known connection: its credit is recorded first.
def Vs.known(vs: Vsock, rest: +List<VConn>, c: VConn, +p: Pkt) -> VsOut:
  match p:
    case Pkt{sc, dc, sp, dp, +op, fl, +ba, +fc, pl}:
      Vs.known.by(U32.is_eq(op, Vs.rw()), U32.is_eq(op, Vs.rst()), U32.is_eq(op, Vs.shutdown()), U32.is_eq(op, Vs.response()), U32.is_eq(op, Vs.credit_request()), vs, rest, VConn.credit(c, ba, fc), p)

# A guest packet for no connection: a REQUEST opens one; an RST is dropped;
# anything else is answered with an RST.
def Vs.unknown(is_req: Bool, is_rst: Bool, +vs: Vsock, rest: +List<VConn>, +p: Pkt) -> VsOut:
  match is_req is_rst:
    case True{} _:
      Vs.new_conn(Vsock.with(vs, rest, []), p)
    case False{} True{}:
      VsOut{Vsock.with(vs, rest, []), []}
    case False{} False{}:
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with(vs, rest, [Vs.rst_for(cid, p)]), []}

def Vs.route(pick: Pick, vs: Vsock, +p: Pkt) -> VsOut:
  match pick:
    case Pick{found, rest}:
      match found:
        case Some{c}:
          Vs.known(vs, rest, c, p)
        case None{}:
          +op = Pkt.op(p)
          Vs.unknown(U32.is_eq(op, Vs.request()), U32.is_eq(op, Vs.rst()), vs, rest, p)

def Vs.packet(got: Maybe<&2, Pkt>, +vs: Vsock) -> VsOut:
  match got:
    case None{}:
      VsOut{vs, []}
    case Some{+p}:
      match p:
        case Pkt{sc, dc, +sp, +dp, op, fl, ba, fc, pl}:
          Vs.route(Vs.pick_ports(Vsock.conns(vs), sp, dp), vs, p)

# A packet the guest transmitted (header and payload).
def Vsock.guest_packet(vs: Vsock, bytes: +List<U32>) -> VsOut:
  Vs.packet(Pkt.parse(bytes), vs)

# Host events
# ===========

def VConn.queue(c: VConn, bs: +List<U32>) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, List.append(&2, U32, pend, bs), eof}

def VConn.set_eof(c: VConn) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, True{}}

def Vs.event.on(ev: V.VsockEvent, +vs: Vsock, rest: +List<VConn>, +c: VConn) -> VsOut:
  match ev:
    case V.VsConnected{id}:
      +c2 = VConn.state(c, 1)
      +cid = Vsock.cid(vs)
      Vsock.keep(vs, rest, Flushed.add(VConn.pkt(cid, c2, Vs.response(), 0, []), VConn.flush.all(c2, cid)), [])
    case V.VsRefused{id}:
      VsOut{Vsock.with(vs, rest, [VConn.pkt(Vsock.cid(vs), c, Vs.rst(), 0, [])]), []}
    case V.VsData{id, bs}:
      Vsock.keep(vs, rest, VConn.flush.all(VConn.queue(c, bs), Vsock.cid(vs)), [])
    case V.VsEof{id}:
      Vsock.keep(vs, rest, VConn.flush.all(VConn.set_eof(c), Vsock.cid(vs)), [])
    case V.VsIncoming{id, port}:
      VsOut{Vsock.with(vs, c <> rest, []), []}

def Vs.event.conn(pick: Pick, vs: Vsock, ev: V.VsockEvent) -> VsOut:
  match pick:
    case Pick{found, rest}:
      match found:
        case None{}:
          # an event for a connection already gone
          VsOut{Vsock.with(vs, rest, []), []}
        case Some{c}:
          Vs.event.on(ev, vs, rest, c)

# A host client asks for guest port `port`: a REQUEST from a fresh host port.
def Vs.incoming(vs: Vsock, +id: U32, +port: U32) -> VsOut:
  match vs:
    case Vsock{+cid, cs, nid, +np, out}:
      +c = {VConn{id, port, np, 2, 0, 0, 0, 0, 0, [], False{}} : VConn}
      VsOut{Vsock{cid, c <> cs, nid, (np + 1 : U32), List.append(&2, +List<U32>, out, [VConn.pkt(cid, c, Vs.request(), 0, [])])}, []}

def Vs.event.id(ev: V.VsockEvent) -> U32:
  match ev:
    case V.VsConnected{id}:
      id
    case V.VsRefused{id}:
      id
    case V.VsData{id, bs}:
      id
    case V.VsEof{id}:
      id
    case V.VsIncoming{id, port}:
      id

# An event from the host's sockets.
def Vsock.host_event(+vs: Vsock, ev: V.VsockEvent) -> VsOut:
  match ev:
    case V.VsIncoming{id, port}:
      Vs.incoming(vs, id, port)
    case _:
      +ev = ev
      Vs.event.conn(Vs.pick_id(Vsock.conns(vs), Vs.event.id(ev)), vs, ev)

# The same state with no packets queued for the guest.
def Vsock.drop_out(vs: Vsock) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      Vsock{cid, cs, nid, np, []}

# Packets queued for the guest and bytes waiting for its credit, for host
# backpressure: in 4 KiB units.
def Vs.pending(cs: +List<VConn>) -> Nat:
  match cs:
    case Nil{}:
      0n
    case Con{VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}, rest}:
      Nat.add(Nat.div(List.length(&2, U32, pend), 4096n), Vs.pending(rest))

def Vsock.backlog(vs: Vsock) -> U32:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      U32.from_nat(Nat.add(List.length(&2, +List<U32>, out), Vs.pending(cs)))

# Queue passes
# ============
#
# The same shape as virtio-net's (src/virtio/net.bend), without its header.

type VsTxq is Data:
  VsTxq{q: Q.Vq, frames: +List<+List<U32>>, used: Bool}

type VsRxq is Data:
  VsRxq{q: Q.Vq, left: +List<+List<U32>>, used: Bool}

# The total length of a chain's writable descriptors.
def Vsq.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Vsq.room(t) : U32)

# Prepends a chain's readable bytes (one packet) to acc (newest first).
def Vsq.keep(+bs: +List<U32>, +acc: +List<+List<U32>>) -> +List<+List<U32>>:
  bs <> acc

# Gathers one transmit chain, pushes it used with length 0, and keeps its frame.
def Vsq.tx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        bs : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, Vsq.keep(bs, acc))

def Vsq.tx.done(-R: Type, q: Q.Vq, acc: +List<+List<U32>>, used: Bool) -> V.Op<R, VsTxq>:
  V.Op.pure(R, VsTxq, VsTxq{q, List.reverse(&2, +List<U32>, acc), used})

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Vsq.tx.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, acc: +List<+List<U32>>, used: Bool,
  k: Q.Vq & +List<+List<U32>> -> V.Op<R, VsTxq>
) -> V.Op<R, VsTxq>:
  match r:
    case (q, None{}):
      Vsq.tx.done(R, q, acc, used)
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & +List<+List<U32>>, VsTxq, Vsq.tx.serve(R, q, c, acc), k)

# Pops and serves transmit chains, at most fuel of them; st is the queue and
# the frames so far (newest first).
def Vsq.tx.go(fuel: Nat, -R: Type, st: Q.Vq & +List<+List<U32>>, used: Bool) -> V.Op<R, VsTxq>:
  match fuel:
    case 0n:
      match st:
        case (q, acc):
          Vsq.tx.done(R, q, acc, used)
    case 1n+f:
      match st:
        case (q, acc):
          do V.Op<R, VsTxq>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Vsq.tx.step(R, r, acc, used, st2 => Vsq.tx.go(f, R, st2, True{}))

# Writes the header and the frame over a receive chain and pushes it used
# with 12 + frame length.
def Vsq.rx.deliver(-R: Type, q: Q.Vq, c: Q.Chain, +frame: +List<U32>) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      len = U32.from_nat(List.length(&2, U32, frame))
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, frame)
        Q.Vq.push(R, q, h, len)

# Whether the header and the frame fit the chain's writable room.
def Vsq.rx.fits(c: Q.Chain, +frame: +List<U32>) -> Bool:
  match c:
    case Q.Chain{h, r, w}:
      Nat.is_le(List.length(&2, U32, frame), U32.to_nat(Vsq.room(w)))

# A popped chain: delivers the frame into it, or drops the frame and keeps the
# chain (continuing with q0, the queue before the pop).
def Vsq.rx.serve(
  -R: Type, fits: Bool, q0: Q.Vq, q: Q.Vq, c: Q.Chain, frame: +List<U32>, used: Bool,
  k: Q.Vq & Bool -> V.Op<R, VsRxq>
) -> V.Op<R, VsRxq>:
  match fits:
    case False{}:
      k((q0, used))
    case True{}:
      V.Op.bind(R, Q.Vq, VsRxq, Vsq.rx.deliver(R, q, c, frame), q2 => k((q2, True{})))

# After a pop: stops on an empty queue with the frame and the rest left, else
# serves the chain and continues with k.
def Vsq.rx.step(
  -R: Type, q0: Q.Vq, r: Q.Vq & Maybe<&2, Q.Chain>, +frame: +List<U32>,
  rest: +List<+List<U32>>, used: Bool, k: Q.Vq & Bool -> V.Op<R, VsRxq>
) -> V.Op<R, VsRxq>:
  match r:
    case (q, None{}):
      V.Op.pure(R, VsRxq, VsRxq{q, frame <> rest, used})
    case (q, Some{+c}):
      Vsq.rx.serve(R, Vsq.rx.fits(c, frame), q0, q, c, frame, used, k)

# Delivers or drops each frame in turn; st is the queue and whether any chain
# was used. Every step takes one frame, so the frames bound the loop.
def Vsq.rx.go(frames: +List<+List<U32>>, -R: Type, st: Q.Vq & Bool) -> V.Op<R, VsRxq>:
  match frames:
    case Nil{}:
      match st:
        case (q, used):
          V.Op.pure(R, VsRxq, VsRxq{q, [], used})
    case Con{frame, +rest}:
      match st:
        case (+q, used):
          do V.Op<R, VsRxq>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Vsq.rx.step(R, q, r, frame, rest, used, st2 => Vsq.rx.go(rest, R, st2))

# Takes every available chain of the tx queue (at most num): its readable
# bytes are one packet, pushed used with length 0.
def Vsq.tx(-R: Type, q: Q.Vq) -> V.Op<R, VsTxq>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Vsq.tx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, []), False{})

# Delivers packets into the rx queue, one per available chain, in order; a
# packet larger than the chain's room is dropped and the chain is kept.
def Vsq.rx(-R: Type, q: Q.Vq, frames: +List<+List<U32>>) -> V.Op<R, VsRxq>:
  Vsq.rx.go(frames, R, (q, False{}))

type VsTx is Data:
  VsTx{vs: Vsock, q: Q.Vq, cmds: +List<V.VsockCmd>, used: Bool}

type VsRx is Data:
  VsRx{vs: Vsock, q: Q.Vq, used: Bool}

# Prepends earlier commands to a step's result.
def Vs.merge(+cmds: +List<V.VsockCmd>, o: VsOut) -> VsOut:
  match o:
    case VsOut{vs, cs}:
      VsOut{vs, List.append(&2, V.VsockCmd, cmds, cs)}

def Vs.step(o: VsOut, p: +List<U32>) -> VsOut:
  match o:
    case VsOut{vs, cmds}:
      Vs.merge(cmds, Vsock.guest_packet(vs, p))

# Runs the guest's packets through the protocol, in order.
def Vs.apply(pkts: +List<+List<U32>>, o: VsOut) -> VsOut:
  match pkts:
    case Nil{}:
      o
    case Con{p, rest}:
      Vs.apply(rest, Vs.step(o, p))

def Vs.tx.out(o: VsOut, q: Q.Vq, used: Bool) -> VsTx:
  match o:
    case VsOut{vs, cmds}:
      VsTx{vs, q, cmds, used}

def Vs.tx.fin(-R: Type, vs: Vsock, t: VsTxq) -> V.Op<R, VsTx>:
  match t:
    case VsTxq{q, pkts, used}:
      V.Op.pure(R, VsTx, Vs.tx.out(Vs.apply(pkts, VsOut{vs, []}), q, used))

# The tx queue's packets through the protocol: host commands, and packets
# for the guest queued in the device state.
def Vsock.tx(-R: Type, vs: Vsock, q: Q.Vq) -> V.Op<R, VsTx>:
  do V.Op<R, VsTx>:
    t : VsTxq <- Vsq.tx(R, q)
    Vs.tx.fin(R, vs, t)

def Vsock.take_out(vs: Vsock) -> Vsock & +List<+List<U32>>:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      (Vsock{cid, cs, nid, np, []}, out)

def Vsock.put_back(vs: Vsock, left: +List<+List<U32>>) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      Vsock{cid, cs, nid, np, List.append(&2, +List<U32>, left, out)}

def Vs.rx.fin(-R: Type, vs: Vsock, r: VsRxq) -> V.Op<R, VsRx>:
  match r:
    case VsRxq{q, left, used}:
      V.Op.pure(R, VsRx, VsRx{Vsock.put_back(vs, left), q, used})

def Vs.rx.go(-R: Type, t: Vsock & +List<+List<U32>>, q: Q.Vq) -> V.Op<R, VsRx>:
  match t:
    case (vs, pkts):
      do V.Op<R, VsRx>:
        r : VsRxq <- Vsq.rx(R, q, pkts)
        Vs.rx.fin(R, vs, r)

# Delivers the packets queued for the guest into posted rx buffers; those
# that find no buffer stay queued.
def Vsock.rx(-R: Type, vs: Vsock, q: Q.Vq) -> V.Op<R, VsRx>:
  Vs.rx.go(R, Vsock.take_out(vs), q)
