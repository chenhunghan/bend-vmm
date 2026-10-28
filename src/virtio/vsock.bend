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
# since the last one, unless the host program is behind (VsBlocked): then
# the credit waits for VsUnblocked.
#
# No payload passes through Bend. A guest RW's payload is staged on the host
# (VmStage) and sent from there (VsSendStaged); only the 44-byte header is
# read. Host data waits in the host's buffer (VsReady: len bytes held); the
# rx pass fills each posted buffer with a header and, by VmVsToRam, as many
# held bytes as the buffer, the guest's credit and the hold allow, so a
# packet always fits its buffer. Once every held byte is out, VsRelease lets
# the host read more.

def Vs.host_cid() -> U32:
  2

def Vs.buf_alloc() -> U32:
  262144

# The most payload a packet to the guest carries. Linux 6.8 posts rx
# buffers of a page less the socket buffer's overhead (about 3.7 KiB with
# the header): 3.5 KiB fits them; a packet that still does not fit a buffer
# is split there (Vsq.rx.split).
def Vs.max_payload() -> U32:
  3584

# Caps on what a guest can make the device keep: packets queued for the
# guest that answer it (RSTs, credit updates on request; further ones are
# dropped), and connections (a REQUEST past the cap is refused with an RST and
# no host connect).
def Vs.max_out() -> Nat:
  256n

def Vs.max_conns() -> Nat:
  128n

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
# last advertised; held: bytes the host holds for the guest (VsReady); sent:
# how many of them reached the guest.
type VConn is Data:
  VConn{id: U32, gport: U32, hport: U32, state: U32, tx: U32, peer_alloc: U32, peer_fwd: U32, fwd: U32, last_fwd: U32, held: U32, sent: U32}

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
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      Pkt.build(Pkt{U.U64{0, Vs.host_cid()}, cid, hp, gp, op, flags, Vs.buf_alloc(), fwd, payload})

# A reply to a packet with no connection: RST with the ports swapped.
def Vs.rst_for(+cid: U.U64, p: Pkt) -> +List<U32>:
  match p:
    case Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}:
      Pkt.build(Pkt{U.U64{0, Vs.host_cid()}, cid, dp, sp, Vs.rst(), 0, Vs.buf_alloc(), 0, []})

def VConn.id(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      id

def VConn.matches(c: VConn, +gport: U32, +hport: U32) -> Bool:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
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
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, tx, alloc, fwd_cnt, fwd, lf, hd, sn}

# What a connection may send now: the guest's credit, and what the host
# holds that has not gone out.
def VConn.avail(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, +tx, +pa, +pf, fwd, lf, +hd, +sn}:
      +inflight = (tx - pf : U32)
      +free = Bool.pick(U32, U32.is_lt(pa, inflight), 0, (pa - inflight : U32))
      U32.min(free, Bool.pick(U32, U32.is_lt(hd, sn), 0, (hd - sn : U32)))

# The host now holds len more bytes for the guest.
def VConn.hold(c: VConn, +len: U32) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, (hd + len : U32), sn}

# n held bytes went to the guest.
def VConn.sent_more(c: VConn, +n: U32) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, (tx + n : U32), pa, pf, fwd, lf, hd, (sn + n : U32)}

def VConn.sent(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      sn

# Whether the host holds bytes and all of them reached the guest.
def VConn.drained(c: VConn) -> Bool:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, +hd, +sn}:
      U32.is_ne(hd, 0) && U32.is_eq(hd, sn)

def VConn.released(c: VConn) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, 0, 0}

# Results
# =======

def Vsock.with(vs: Vsock, conns: +List<VConn>, out: +List<+List<U32>>) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, old}:
      Vsock{cid, conns, nid, np, List.append(&2, +List<U32>, old, out)}

# Packets queued for the guest, the connections kept.
def Vsock.queue(vs: Vsock, out: +List<+List<U32>>) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, old}:
      Vsock{cid, cs, nid, np, List.append(&2, +List<U32>, old, out)}

# Vsock.with for a packet that answers the guest: it is dropped once
# Vs.max_out() packets wait for the guest.
def Vsock.with_ctl(vs: Vsock, conns: +List<VConn>, p: +List<U32>) -> Vsock:
  match vs:
    case Vsock{cid, cs, nid, np, +old}:
      +room = Nat.is_lt(List.length(&2, +List<U32>, old), Vs.max_out())
      Vsock{cid, conns, nid, np, List.append(&2, +List<U32>, old, Bool.pick(+List<+List<U32>>, room, [p], []))}

def Vsock.cid(vs: Vsock) -> U.U64:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      cid

def Vsock.conns(vs: Vsock) -> +List<VConn>:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      cs

# Prepends earlier commands to a step's result.
def Vs.merge(+cmds: +List<V.VsockCmd>, o: VsOut) -> VsOut:
  match o:
    case VsOut{vs, cs}:
      VsOut{vs, List.append(&2, V.VsockCmd, cmds, cs)}

# Guest packets
# =============

def Vs.new_conn(vs: Vsock, +p: Pkt) -> VsOut:
  match vs p:
    case Vsock{cid, cs, +nid, np, out} Pkt{sc, dc, +sp, +dp, op, fl, ba, fc, pl}:
      +c = {VConn{nid, sp, dp, 0, 0, ba, fc, 0, 0, 0, 0} : VConn}
      VsOut{Vsock{cid, c <> cs, (nid + 1 : U32), np, out}, [V.VsConnect{nid, dp}]}

# A packet's payload when the tx pass staged it on the host (VmStage): its
# slot and length. NoStg: the payload, if any, came as bytes.
type Stg is Data:
  NoStg{}
  Stg{slot: U32, len: U32}

# Frees a staged payload its packet did not use.
def Stg.drop(s: Stg) -> +List<V.VsockCmd>:
  match s:
    case NoStg{}:
      []
    case Stg{slot, len}:
      [V.VsStageDrop{slot}]

def Stg.len(s: Stg, payload: +List<U32>) -> U32:
  match s:
    case NoStg{}:
      U32.from_nat(List.length(&2, U32, payload))
    case Stg{slot, len}:
      len

def Stg.send(s: Stg, +id: U32, payload: +List<U32>) -> V.VsockCmd:
  match s:
    case NoStg{}:
      V.VsSend{id, payload}
    case Stg{slot, len}:
      V.VsSendStaged{id, slot}

# RW: the payload goes to the host; a CREDIT_UPDATE follows once half the
# advertised buffer has been consumed since the last one.
def Vs.rw_in.fin(update: Bool, vs: Vsock, +c: VConn, +cid: U.U64, cmds: +List<V.VsockCmd>) -> VsOut:
  match update:
    case True{}:
      VsOut{Vsock.queue(vs, [VConn.pkt(cid, c, Vs.credit_update(), 0, [])]), cmds}
    case False{}:
      VsOut{vs, cmds}

def Vs.rw_in(+vs: Vsock, rest: +List<VConn>, c: VConn, payload: +List<U32>, +stg: Stg) -> VsOut:
  match c:
    case VConn{+id, gp, hp, +st, tx, pa, pf, fwd, +lf, hd, sn}:
      +held = U32.is_ne((st .&. 256 : U32), 0)
      +payload = payload
      +fwd2 = (fwd + Stg.len(stg, payload) : U32)
      # no credit update while the host program is behind (VsBlocked)
      +update = Bool.not(held) && U32.is_le((Vs.buf_alloc() >> 1n : U32), (fwd2 - lf : U32))
      +c2 = {VConn{id, gp, hp, st, tx, pa, pf, fwd2, Bool.pick(U32, update, fwd2, lf), hd, sn} : VConn}
      +cid = Vsock.cid(vs)
      Vs.rw_in.fin(update, Vsock.with(vs, c2 <> rest, []), c2, cid, [Stg.send(stg, id, payload)])

def VConn.state(c: VConn, st: U32) -> VConn:
  match c:
    case VConn{id, gp, hp, old, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}

def VConn.hport(c: VConn) -> U32:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      hp

# Marks the current fwd_cnt as advertised.
def VConn.last_fwd(c: VConn) -> VConn:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, +fwd, lf, hd, sn}:
      VConn{id, gp, hp, st, tx, pa, pf, fwd, fwd, hd, sn}

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

def Vs.known.by(rw: Bool, rst: Bool, sd: Bool, resp: Bool, creq: Bool, +vs: Vsock, rest: +List<VConn>, +c: VConn, +p: Pkt, +stg: Stg) -> VsOut:
  match rw rst sd resp creq:
    case True{} _ _ _ _:
      Vs.rw_in(vs, rest, c, Pkt.payload(p), stg)
    case False{} True{} _ _ _:
      VsOut{Vsock.with(vs, rest, []), [V.VsClose{VConn.id(c)}]}
    case False{} False{} True{} _ _:
      +fl = Pkt.flags(p)
      Vs.shutdown_in(U32.is_eq(fl, 3), U32.is_ne((fl .&. 2 : U32), 0), vs, rest, c, Vsock.cid(vs))
    case False{} False{} False{} True{} _:
      +c2 = VConn.state(c, 1)
      VsOut{Vsock.with(vs, c2 <> rest, []), [V.VsAccepted{VConn.id(c), VConn.hport(c2)}]}
    case False{} False{} False{} False{} True{}:
      +c2 = VConn.last_fwd(c)
      VsOut{Vsock.with_ctl(vs, c2 <> rest, VConn.pkt(Vsock.cid(vs), c2, Vs.credit_update(), 0, [])), []}
    case False{} False{} False{} False{} False{}:
      # CREDIT_UPDATE (or anything else): the credit is recorded; the next rx
      # pass sends what it allows
      VsOut{Vsock.with(vs, c <> rest, []), []}

# A guest packet for a known connection: its credit is recorded first. Only
# an RW takes a staged payload (the tx pass stages no other).
def Vs.known(vs: Vsock, rest: +List<VConn>, c: VConn, +p: Pkt, +stg: Stg) -> VsOut:
  match p:
    case Pkt{sc, dc, sp, dp, +op, fl, +ba, +fc, pl}:
      +rw = U32.is_eq(op, Vs.rw())
      Vs.merge(Bool.pick(+List<V.VsockCmd>, rw, [], Stg.drop(stg)), Vs.known.by(rw, U32.is_eq(op, Vs.rst()), U32.is_eq(op, Vs.shutdown()), U32.is_eq(op, Vs.response()), U32.is_eq(op, Vs.credit_request()), vs, rest, VConn.credit(c, ba, fc), Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}, stg))

# A REQUEST for no connection: a new one, or an RST when Vs.max_conns() are
# open (full).
def Vs.open(full: Bool, +vs: Vsock, rest: +List<VConn>, +p: Pkt) -> VsOut:
  match full:
    case False{}:
      Vs.new_conn(Vsock.with(vs, rest, []), p)
    case True{}:
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with_ctl(vs, rest, Vs.rst_for(cid, p)), []}

# A guest packet for no connection: a REQUEST opens one (Vs.open); an RST is
# dropped; anything else is answered with an RST (Vsock.with_ctl).
def Vs.unknown(is_req: Bool, is_rst: Bool, +vs: Vsock, +rest: +List<VConn>, +p: Pkt) -> VsOut:
  match is_req is_rst:
    case True{} _:
      Vs.open(Nat.is_le(Vs.max_conns(), List.length(&2, VConn, rest)), vs, rest, p)
    case False{} True{}:
      VsOut{Vsock.with(vs, rest, []), []}
    case False{} False{}:
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with_ctl(vs, rest, Vs.rst_for(cid, p)), []}

def Vs.route(pick: Pick, vs: Vsock, +p: Pkt, +stg: Stg) -> VsOut:
  match pick:
    case Pick{found, rest}:
      match found:
        case Some{c}:
          Vs.known(vs, rest, c, p, stg)
        case None{}:
          # a packet for no connection carries nowhere: its staged payload
          # is freed
          +op = Pkt.op(p)
          Vs.merge(Stg.drop(stg), Vs.unknown(U32.is_eq(op, Vs.request()), U32.is_eq(op, Vs.rst()), vs, rest, p))

def Vs.packet(got: Maybe<&2, Pkt>, +vs: Vsock, +stg: Stg) -> VsOut:
  match got:
    case None{}:
      VsOut{vs, Stg.drop(stg)}
    case Some{+p}:
      match p:
        case Pkt{sc, dc, +sp, +dp, op, fl, ba, fc, pl}:
          Vs.route(Vs.pick_ports(Vsock.conns(vs), sp, dp), vs, Pkt{sc, dc, sp, dp, op, fl, ba, fc, pl}, stg)

# A packet the guest transmitted (header and payload).
def Vsock.guest_packet(vs: Vsock, bytes: +List<U32>) -> VsOut:
  Vs.packet(Pkt.parse(bytes), vs, NoStg{})

# The header of a packet the guest transmitted (44 bytes or more: the rest
# is ignored), its payload staged on the host (stg) or absent.
def Pkt.head.ok(ok: Bool, +bs: +List<U32>) -> Maybe<&2, Pkt>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Some{Pkt{B.Bytes.read_le64(bs), B.Bytes.read_le64(List.drop(&2, U32, bs, 8n)), B.Bytes.read_le32(B.Bytes.slice(bs, 16n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 20n, 4n)), B.Bytes.read_le16(B.Bytes.slice(bs, 30n, 2n)), B.Bytes.read_le32(B.Bytes.slice(bs, 32n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 36n, 4n)), B.Bytes.read_le32(B.Bytes.slice(bs, 40n, 4n)), []}}

def Pkt.head(+bs: +List<U32>) -> Maybe<&2, Pkt>:
  Pkt.head.ok(Nat.is_le(44n, List.length(&2, U32, bs)), bs)

def Vsock.guest_staged(vs: Vsock, hdr: +List<U32>, +stg: Stg) -> VsOut:
  Vs.packet(Pkt.head(hdr), vs, stg)

# Host events
# ===========

# Whether the host program is behind on this connection (bit 256 of state,
# which holds no other value that high): no credit goes to the guest then.
def VConn.blocked(c: VConn) -> Bool:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      U32.is_ne((st .&. 256 : U32), 0)

def VConn.set_blocked(c: VConn, on: Bool) -> VConn:
  match c:
    case VConn{id, gp, hp, +st, tx, pa, pf, fwd, lf, hd, sn}:
      VConn{id, gp, hp, Bool.pick(U32, on, (st .|. 256 : U32), (st .&. 4294967039 : U32)), tx, pa, pf, fwd, lf, hd, sn}

def Vs.event.on(ev: V.VsockEvent, +vs: Vsock, rest: +List<VConn>, +c: VConn) -> VsOut:
  match ev:
    case V.VsConnected{id}:
      +c2 = VConn.state(c, 1)
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with(vs, c2 <> rest, [VConn.pkt(cid, c2, Vs.response(), 0, [])]), []}
    case V.VsRefused{id}:
      VsOut{Vsock.with(vs, rest, [VConn.pkt(Vsock.cid(vs), c, Vs.rst(), 0, [])]), []}
    case V.VsReady{id, len}:
      # the rx pass sends them as credit and buffers allow
      VsOut{Vsock.with(vs, VConn.hold(c, len) <> rest, []), []}
    case V.VsEof{id}:
      # the host reads again only after VsRelease, so nothing it held is
      # left: the guest learns the host will send no more
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with(vs, c <> rest, [VConn.pkt(cid, c, Vs.shutdown(), 2, [])]), []}
    case V.VsIncoming{id, port}:
      VsOut{Vsock.with(vs, c <> rest, []), []}
    case V.VsBlocked{id}:
      VsOut{Vsock.with(vs, VConn.set_blocked(c, True{}) <> rest, []), []}
    case V.VsUnblocked{id}:
      # caught up: the credit held back goes to the guest now
      +c2 = VConn.last_fwd(VConn.set_blocked(c, False{}))
      +cid = Vsock.cid(vs)
      VsOut{Vsock.with(vs, c2 <> rest, [VConn.pkt(cid, c2, Vs.credit_update(), 0, [])]), []}

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
      +c = {VConn{id, port, np, 2, 0, 0, 0, 0, 0, 0, 0} : VConn}
      VsOut{Vsock{cid, c <> cs, nid, (np + 1 : U32), List.append(&2, +List<U32>, out, [VConn.pkt(cid, c, Vs.request(), 0, [])])}, []}

def Vs.event.id(ev: V.VsockEvent) -> U32:
  match ev:
    case V.VsConnected{id}:
      id
    case V.VsRefused{id}:
      id
    case V.VsReady{id, len}:
      id
    case V.VsEof{id}:
      id
    case V.VsIncoming{id, port}:
      id
    case V.VsBlocked{id}:
      id
    case V.VsUnblocked{id}:
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

# Packets queued for the guest (host data waits in the host's buffer).
def Vsock.backlog(vs: Vsock) -> U32:
  match vs:
    case Vsock{cid, cs, nid, np, out}:
      U32.from_nat(List.length(&2, +List<U32>, out))

# Queue passes
# ============
#
# The same shape as virtio-net's (src/virtio/net.bend), without its header.

# One transmitted packet: its header bytes and its staged payload.
type TxItem is Data:
  TxItem{hdr: +List<U32>, stg: Stg}

type VsTxq is Data:
  VsTxq{q: Q.Vq, items: +List<TxItem>, used: Bool}

type VsRxq is Data:
  VsRxq{q: Q.Vq, left: +List<+List<U32>>, used: Bool}

# The total length of a chain's writable descriptors.
def Vsq.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Vsq.room(t) : U32)

# The most bytes of one transmit chain: a header and 64 KiB of payload (a
# longer payload is cut). Only the header is read through Bend.
def Vsq.max_tx() -> U32:
  65580

# What the tx pass makes of a chain whose header says op and len: an RW's
# payload staged on the host (as much of it as the chain holds, at most
# Vsq.max_tx() - 44 bytes), else nothing staged.
def Vsq.tx.stage(-R: Type, rw: Bool, +segs: +List<V.Iov>) -> V.Op<R, Stg>:
  match rw:
    case False{}:
      V.Op.pure(R, Stg, NoStg{})
    case True{}:
      +n = V.Iov.total(segs)
      do V.Op<R, Stg>:
        slot : U32 <- V.Op.stage(R, segs)
        return Stg{slot, n}

# Reads one transmit chain's header, stages its payload, pushes it used with
# length 0, and keeps the item.
def Vsq.tx.item(-R: Type, q: Q.Vq, +h: U32, +r: +List<Q.Desc>, +hdr: +List<U32>, acc: +List<TxItem>) -> V.Op<R, Q.Vq & +List<TxItem>>:
  +len = B.Bytes.read_le32(B.Bytes.slice(hdr, 24n, 4n))
  +rw = Nat.is_le(44n, List.length(&2, U32, hdr)) && U32.is_eq(B.Bytes.read_le16(B.Bytes.slice(hdr, 30n, 2n)), Vs.rw()) && U32.is_ne(len, 0)
  do V.Op<R, Q.Vq & +List<TxItem>>:
    stg : Stg <- Vsq.tx.stage(R, rw, Q.Vq.segs(r, 44, U32.min(len, (Vsq.max_tx() - 44 : U32))))
    q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
    return (q2, TxItem{hdr, stg} <> acc)

def Vsq.tx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, acc: +List<TxItem>
) -> V.Op<R, Q.Vq & +List<TxItem>>:
  match c:
    case Q.Chain{+h, +r, w}:
      do V.Op<R, Q.Vq & +List<TxItem>>:
        hdr : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 0, 44))
        Vsq.tx.item(R, q, h, r, hdr, acc)

def Vsq.tx.done(-R: Type, q: Q.Vq, acc: +List<TxItem>, used: Bool) -> V.Op<R, VsTxq>:
  V.Op.pure(R, VsTxq, VsTxq{q, List.reverse(&2, TxItem, acc), used})

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Vsq.tx.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, acc: +List<TxItem>, used: Bool,
  k: Q.Vq & +List<TxItem> -> V.Op<R, VsTxq>
) -> V.Op<R, VsTxq>:
  match r:
    case (q, None{}):
      Vsq.tx.done(R, q, acc, used)
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & +List<TxItem>, VsTxq, Vsq.tx.serve(R, q, c, acc), k)

# Pops and serves transmit chains, at most fuel of them; st is the queue and
# the items so far (newest first).
def Vsq.tx.go(fuel: Nat, -R: Type, st: Q.Vq & +List<TxItem>, used: Bool) -> V.Op<R, VsTxq>:
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

# Takes every available chain of the tx queue (at most num): its header is
# read, an RW's payload staged, and the chain pushed used with length 0.
def Vsq.tx(-R: Type, q: Q.Vq) -> V.Op<R, VsTxq>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Vsq.tx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, []), False{})

# Delivers the queued control packets into the rx queue, one per available
# chain, in order; a packet larger than the chain's room is dropped and the
# chain kept.
def Vsq.rx(-R: Type, q: Q.Vq, frames: +List<+List<U32>>) -> V.Op<R, VsRxq>:
  Vsq.rx.go(frames, R, (q, False{}))

type VsTx is Data:
  VsTx{vs: Vsock, q: Q.Vq, cmds: +List<V.VsockCmd>, used: Bool}

type VsRx is Data:
  VsRx{vs: Vsock, q: Q.Vq, cmds: +List<V.VsockCmd>, used: Bool}

def Vs.step(o: VsOut, it: TxItem) -> VsOut:
  match o it:
    case VsOut{vs, cmds} TxItem{hdr, stg}:
      Vs.merge(cmds, Vsock.guest_staged(vs, hdr, stg))

# Runs the guest's packets through the protocol, in order.
def Vs.apply(items: +List<TxItem>, o: VsOut) -> VsOut:
  match items:
    case Nil{}:
      o
    case Con{it, rest}:
      Vs.apply(rest, Vs.step(o, it))

def Vs.tx.out(o: VsOut, q: Q.Vq, used: Bool) -> VsTx:
  match o:
    case VsOut{vs, cmds}:
      VsTx{vs, q, cmds, used}

def Vs.tx.fin(-R: Type, vs: Vsock, t: VsTxq) -> V.Op<R, VsTx>:
  match t:
    case VsTxq{q, items, used}:
      V.Op.pure(R, VsTx, Vs.tx.out(Vs.apply(items, VsOut{vs, []}), q, used))

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

# Host data to the guest
# ======================
#
# After the control packets, each connection's held bytes go straight into
# the remaining buffers: a header written through Bend, then the payload
# copied on the host (VmVsToRam), as much as the guest's credit, the hold and
# the buffer allow.

# The data pass's queue, whether it used a chain, and whether chains may
# remain (false once the queue ran dry or a buffer was too small).
type VsDat is Data:
  VsDat{q: Q.Vq, used: Bool, open: Bool}

# The connections after the data pass, its state, and its commands
# (VsRelease for every hold that went out whole).
type VsAll is Data:
  VsAll{conns: +List<VConn>, st: VsDat, cmds: +List<V.VsockCmd>}

# The header of a data packet of n bytes of c.
def VConn.data_hdr(+cid: U.U64, c: VConn, +n: U32) -> +List<U32>:
  match c:
    case VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, hd, sn}:
      List.append(&2, U32, B.Bytes.le64(U.U64{0, Vs.host_cid()}), List.append(&2, U32, B.Bytes.le64(cid), List.append(&2, U32, B.Bytes.le32(hp), List.append(&2, U32, B.Bytes.le32(gp), List.append(&2, U32, B.Bytes.le32(n), List.append(&2, U32, B.Bytes.le16(1), List.append(&2, U32, B.Bytes.le16(Vs.rw()), List.append(&2, U32, B.Bytes.le32(0), List.append(&2, U32, B.Bytes.le32(Vs.buf_alloc()), B.Bytes.le32(fwd))))))))))

# One data packet of n bytes of c into the chain (h, w): the header, then the
# held bytes from where c left off.
def Vs.rx.fill(-R: Type, +cid: U.U64, +c: VConn, q: Q.Vq, +h: U32, +w: +List<Q.Desc>, +n: U32) -> V.Op<R, VConn & Q.Vq>:
  +hdr = VConn.data_hdr(cid, c, n)
  +id = VConn.id(c)
  +off = VConn.sent(c)
  do V.Op<R, VConn & Q.Vq>:
    k : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, hdr)
    V.Op.vs_to_ram(R, id, off, Q.Vq.segs(w, 44, n))
    q2 : Q.Vq <- Q.Vq.push(R, q, h, (44 + n : U32))
    return (VConn.sent_more(c, n), q2)

def Vs.rx.put.next(-R: Type, r: VConn & Q.Vq, k: VConn & VsDat -> V.Op<R, VConn & VsDat>) -> V.Op<R, VConn & VsDat>:
  match r:
    case (c2, q2):
      k((c2, VsDat{q2, True{}, True{}}))

# A buffer of room bytes: too small for a header and a byte stops the pass
# with the chain kept (q0); else a packet of what fits goes into it.
def Vs.rx.put(
  small: Bool, -R: Type, +cid: U.U64, +n0: U32, +c: VConn, q0: Q.Vq, q: Q.Vq, +h: U32, +w: +List<Q.Desc>, +room: U32, used: Bool,
  k: VConn & VsDat -> V.Op<R, VConn & VsDat>
) -> V.Op<R, VConn & VsDat>:
  match small:
    case True{}:
      V.Op.pure(R, VConn & VsDat, (c, VsDat{q0, used, False{}}))
    case False{}:
      +n = U32.min(n0, U32.min((room - 44 : U32), Vs.max_payload()))
      do V.Op<R, VConn & VsDat>:
        r : VConn & Q.Vq <- Vs.rx.fill(R, cid, c, q, h, w, n)
        Vs.rx.put.next(R, r, k)

# After a pop: no chain stops the pass; a chain takes a packet.
def Vs.rx.chain(
  -R: Type, +cid: U.U64, +n0: U32, +c: VConn, q0: Q.Vq, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool,
  k: VConn & VsDat -> V.Op<R, VConn & VsDat>
) -> V.Op<R, VConn & VsDat>:
  match r:
    case (q, None{}):
      V.Op.pure(R, VConn & VsDat, (c, VsDat{q, used, False{}}))
    case (q, Some{Q.Chain{h, rd, +w}}):
      +room = Vsq.room(w)
      Vs.rx.put(U32.is_le(room, 44), R, cid, n0, c, q0, q, h, w, room, used, k)

# One step for c: nothing to send (n0, what it may send, is 0) or no chain
# left ends it; else a chain is popped.
def Vs.rx.step(
  stop: Bool, -R: Type, +cid: U.U64, +n0: U32, +c: VConn, s: VsDat,
  k: VConn & VsDat -> V.Op<R, VConn & VsDat>
) -> V.Op<R, VConn & VsDat>:
  match stop:
    case True{}:
      V.Op.pure(R, VConn & VsDat, (c, s))
    case False{}:
      match s:
        case VsDat{+q, used, open}:
          do V.Op<R, VConn & VsDat>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Vs.rx.chain(R, cid, n0, c, q, r, used, k)

def VsDat.open(s: VsDat) -> Bool:
  match s:
    case VsDat{q, used, open}:
      open

# Packets for c while it may send and buffers come; fuel bounds the chains.
def Vs.rx.conn(fuel: Nat, -R: Type, +cid: U.U64, st: VConn & VsDat) -> V.Op<R, VConn & VsDat>:
  match fuel:
    case 0n:
      V.Op.pure(R, VConn & VsDat, st)
    case 1n+f:
      match st:
        case (+c, +s):
          +n0 = VConn.avail(c)
          Vs.rx.step(U32.is_zero(n0) || Bool.not(VsDat.open(s)), R, cid, n0, c, s, st2 => Vs.rx.conn(f, R, cid, st2))

# c once its pass is over: a hold that went out whole is released.
def Vs.rx.done.go(drained: Bool, +c: VConn) -> VConn & +List<V.VsockCmd>:
  match drained:
    case True{}:
      (VConn.released(c), [V.VsRelease{VConn.id(c)}])
    case False{}:
      (c, [])

def Vs.rx.done(+c: VConn) -> VConn & +List<V.VsockCmd>:
  Vs.rx.done.go(VConn.drained(c), c)

def VsAll.add(r: VConn & +List<V.VsockCmd>, a: VsAll) -> VsAll:
  match r a:
    case (c, cs) VsAll{conns, st, cmds}:
      VsAll{c <> conns, st, List.append(&2, V.VsockCmd, cs, cmds)}

def Vs.rx.after(-R: Type, p: VConn & VsDat, k: VsDat -> V.Op<R, VsAll>) -> V.Op<R, VsAll>:
  match p:
    case (c, s):
      do V.Op<R, VsAll>:
        a : VsAll <- k(s)
        return VsAll.add(Vs.rx.done(c), a)

# The data pass over every connection, in order.
def Vs.rx.conns(-R: Type, +cid: U.U64, +fuel: Nat, cs: +List<VConn>, s: VsDat) -> V.Op<R, VsAll>:
  match cs:
    case Nil{}:
      V.Op.pure(R, VsAll, VsAll{[], s, []})
    case Con{c, rest}:
      do V.Op<R, VsAll>:
        p : VConn & VsDat <- Vs.rx.conn(fuel, R, cid, (c, s))
        Vs.rx.after(R, p, s2 => Vs.rx.conns(R, cid, fuel, rest, s2))

def Vs.rx.data.fin(vs: Vsock, a: VsAll) -> VsRx:
  match vs a:
    case Vsock{cid, cs, nid, np, out} VsAll{conns, VsDat{q, used, open}, cmds}:
      VsRx{Vsock{cid, conns, nid, np, out}, q, cmds, used}

def Vs.rx.data(-R: Type, vs: Vsock, q: Q.Vq, used: Bool) -> V.Op<R, VsRx>:
  match vs q:
    case Vsock{+cid, cs, nid, np, out} Q.Vq{+num, d, dr, dv, na, nu}:
      do V.Op<R, VsRx>:
        a : VsAll <- Vs.rx.conns(R, cid, U32.to_nat(num), cs, VsDat{Q.Vq{num, d, dr, dv, na, nu}, used, True{}})
        return Vs.rx.data.fin(Vsock{cid, [], nid, np, out}, a)

def Vs.rx.fin(-R: Type, vs: Vsock, r: VsRxq) -> V.Op<R, VsRx>:
  match r:
    case VsRxq{q, left, used}:
      Vs.rx.data(R, Vsock.put_back(vs, left), q, used)

def Vs.rx.go(-R: Type, t: Vsock & +List<+List<U32>>, q: Q.Vq) -> V.Op<R, VsRx>:
  match t:
    case (vs, pkts):
      do V.Op<R, VsRx>:
        r : VsRxq <- Vsq.rx(R, q, pkts)
        Vs.rx.fin(R, vs, r)

# Delivers the control packets queued for the guest into posted rx buffers
# (those that find no buffer stay queued), then the host's held data.
def Vsock.rx(-R: Type, vs: Vsock, q: Q.Vq) -> V.Op<R, VsRx>:
  Vs.rx.go(R, Vsock.take_out(vs), q)
