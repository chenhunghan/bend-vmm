import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q
import ../net/wire.bend as W

# virtio-net (Virtio 1.2 section 5.1), device id 1. Offered features:
# VIRTIO_F_VERSION_1 (bit 32) and VIRTIO_NET_F_MAC (bit 5); so the config
# space is the 6-byte MAC (Net.config). Queue 0 is receiveq1 (host to
# guest), queue 1 transmitq1 (guest to host).
#
# Every buffer starts with the 12-byte virtio_net_hdr (VERSION_1 layout):
# flags u8, gso_type u8, hdr_len u16, gso_size u16, csum_start u16,
# csum_offset u16, num_buffers u16. Transmit strips it; receive writes it as
# all zeros except num_buffers = 1, then the frame.
#
# Transmit: a TCP segment with data leaves its payload on the host (a staged
# frame, W.Wire.staged_frame; the NAT sends or frees it). Offered for it:
# VIRTIO_NET_F_CSUM (bit 0) and VIRTIO_NET_F_HOST_TSO4 (bit 11): the guest
# sends TCP segments of up to 64 KiB with checksums left partial (the NAT
# never checks them).
#
# Also offered: VIRTIO_NET_F_GUEST_CSUM (bit 1) and VIRTIO_NET_F_GUEST_TSO4
# (bit 7), so a guest that takes them posts receive buffers of 64 KiB and
# more and accepts TCP segments that large. A host frame (W.Wire.host_frame:
# headers, payload left on the host) goes to such a guest with flags
# DATA_VALID (2), and when its payload passes 1460 bytes, gso_type TCPV4 (1),
# hdr_len its header length and gso_size 1460; the payload follows the
# headers by V.Op.net_to_ram.

type NetTx is Data:
  NetTx{q: Q.Vq, frames: +List<+List<U32>>, used: Bool}

type NetRx is Data:
  NetRx{q: Q.Vq, left: +List<+List<U32>>, used: Bool}

def Net.config(mac: +List<U32>) -> +List<U32>:
  mac

# The virtio_net_hdr the device writes: all zeros but num_buffers = 1.
def Net.hdr() -> +List<U32>:
  List.append(&2, U32, B.Bytes.zeros(10n), B.Bytes.le16(1))

# The total length of a chain's writable descriptors.
def Net.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Net.room(t) : U32)

# Prepends the frame in a chain's readable bytes to acc (newest first), when
# the bytes are longer than the header.
def Net.keep(+bs: +List<U32>, +acc: +List<+List<U32>>) -> +List<+List<U32>>:
  Bool.pick(+List<+List<U32>>, Nat.is_le(List.length(&2, U32, bs), 12n), acc, List.drop(&2, U32, bs, 12n) <> acc)

# The lengths of a frame's Ethernet, IPv4 and TCP headers and of its TCP
# payload, from its first bytes bs; (0, 0) when it is no TCP segment with
# data (or its headers pass bs).
def Net.tcp_split(+bs: +List<U32>) -> Nat & Nat:
  +ihl = Nat.mul(4n, U32.to_nat((W.Wire.u8(bs, 14n) .&. 15 : U32)))
  +thl = Nat.mul(4n, U32.to_nat((W.Wire.u8(bs, Nat.add(26n, ihl)) >> 4n : U32)))
  +hl = Nat.add(14n, Nat.add(ihl, thl))
  +tot = U32.to_nat(W.Wire.u16(bs, 16n))
  +ok = U32.is_eq(W.Wire.u16(bs, 12n), 2048) && U32.is_eq(W.Wire.u8(bs, 23n), 6) && Nat.is_le(20n, ihl) && Nat.is_le(20n, thl) && Nat.is_le(hl, List.length(&2, U32, bs)) && Nat.is_lt(Nat.add(ihl, thl), tot)
  Bool.pick(Nat & Nat, ok, (hl, Nat.sub(tot, Nat.add(ihl, thl))), (0n, 0n))

# A chain whose frame is a TCP segment with data (pl bytes after hl bytes of
# headers): the payload is staged on the host (V.Op.stage) before the chain
# goes back to the guest, and the frame keeps only the headers
# (W.Wire.staged_frame). Any other frame is gathered whole.
def Net.tx.stage(
  -R: Type, plain: Bool, +hl: Nat, +pl: Nat, q: Q.Vq, +h: U32, +r: +List<Q.Desc>, hb: +List<U32>, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match plain:
    case True{}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        bs : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, Net.keep(bs, acc))
    case False{}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        slot : U32 <- V.Op.stage(R, Q.Vq.segs(r, (12 + U32.from_nat(hl) : U32), U32.from_nat(pl)))
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, W.Wire.staged_frame(slot, U32.from_nat(pl), List.take(&2, U32, List.drop(&2, U32, hb, 12n), hl)) <> acc)

def Net.tx.split(
  -R: Type, sp: Nat & Nat, q: Q.Vq, +h: U32, +r: +List<Q.Desc>, hb: +List<U32>, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match sp:
    case (hl, +pl):
      Net.tx.stage(R, Nat.is_eq(pl, 0n), hl, pl, q, h, r, hb, acc)

# One transmit chain: its frame kept (TCP data staged on the host), the
# chain pushed used with length 0. Only the first 146 bytes (the
# virtio_net_hdr and the headers) are read through Bend.
def Net.tx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match c:
    case Q.Chain{+h, +r, w}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        +hb : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 0, 146))
        Net.tx.split(R, Net.tcp_split(List.drop(&2, U32, hb, 12n)), q, h, r, hb, acc)

def Net.tx.done(-R: Type, q: Q.Vq, acc: +List<+List<U32>>, used: Bool) -> V.Op<R, NetTx>:
  V.Op.pure(R, NetTx, NetTx{q, List.reverse(&2, +List<U32>, acc), used})

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Net.tx.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, acc: +List<+List<U32>>, used: Bool,
  k: Q.Vq & +List<+List<U32>> -> V.Op<R, NetTx>
) -> V.Op<R, NetTx>:
  match r:
    case (q, None{}):
      Net.tx.done(R, q, acc, used)
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & +List<+List<U32>>, NetTx, Net.tx.serve(R, q, c, acc), k)

# Pops and serves transmit chains, at most fuel of them; st is the queue and
# the frames so far (newest first).
def Net.tx.go(fuel: Nat, -R: Type, st: Q.Vq & +List<+List<U32>>, used: Bool) -> V.Op<R, NetTx>:
  match fuel:
    case 0n:
      match st:
        case (q, acc):
          Net.tx.done(R, q, acc, used)
    case 1n+f:
      match st:
        case (q, acc):
          do V.Op<R, NetTx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Net.tx.step(R, r, acc, used, st2 => Net.tx.go(f, R, st2, True{}))

# The virtio_net_hdr of a host frame whose headers are hlen bytes and whose
# payload is len bytes.
def Net.host_hdr(+hlen: U32, +len: U32) -> +List<U32>:
  +gso = U32.is_lt(1460, len)
  List.append(&2, U32, [2, Bool.pick(U32, gso, 1, 0)], List.append(&2, U32, B.Bytes.le16(hlen),
    List.append(&2, U32, B.Bytes.le16(Bool.pick(U32, gso, 1460, 0)), List.append(&2, U32, B.Bytes.zeros(4n), B.Bytes.le16(1)))))

# A host frame [256, conn, len, headers...] over a receive chain: the
# virtio_net_hdr and the headers through Bend, then the payload from the
# host straight into the memory after them.
def Net.rx.deliver.host(-R: Type, q: Q.Vq, +h: U32, +w: +List<Q.Desc>, frame: +List<U32>) -> V.Op<R, Q.Vq>:
  match frame:
    case Con{tag, Con{conn, Con{+len, +head}}}:
      +hlen = U32.from_nat(List.length(&2, U32, head))
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, List.append(&2, U32, Net.host_hdr(hlen, len), head))
        V.Op.net_to_ram(R, conn, Q.Vq.segs(w, (12 + hlen : U32), len))
        Q.Vq.push(R, q, h, (12 + (hlen + len : U32) : U32))
    case _:
      Q.Vq.push(R, q, h, 0)

def Net.rx.deliver.go(-R: Type, host: Bool, q: Q.Vq, +h: U32, +w: +List<Q.Desc>, +frame: +List<U32>) -> V.Op<R, Q.Vq>:
  match host:
    case True{}:
      Net.rx.deliver.host(R, q, h, w, frame)
    case False{}:
      len = (12 + U32.from_nat(List.length(&2, U32, frame)) : U32)
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, List.append(&2, U32, Net.hdr(), frame))
        Q.Vq.push(R, q, h, len)

# Writes the header and the frame over a receive chain and pushes it used
# with 12 + frame length (a host frame: its headers and payload).
def Net.rx.deliver(-R: Type, q: Q.Vq, c: Q.Chain, +frame: +List<U32>) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      Net.rx.deliver.go(R, W.Wire.is_host_frame(frame), q, h, w, frame)

# The bytes a frame takes in a receive buffer after the virtio_net_hdr: a
# host frame's headers and payload.
def Net.size(host: Bool, +frame: +List<U32>) -> Nat:
  match host:
    case True{}:
      Nat.add(Nat.sub(List.length(&2, U32, frame), 3n), U32.to_nat(Maybe.default(&2, U32, List.get(&2, U32, frame, 2n), 0)))
    case False{}:
      List.length(&2, U32, frame)

# Whether the header and the frame fit the chain's writable room.
def Net.rx.fits(c: Q.Chain, +frame: +List<U32>) -> Bool:
  match c:
    case Q.Chain{h, r, w}:
      Nat.is_le(12n+Net.size(W.Wire.is_host_frame(frame), frame), U32.to_nat(Net.room(w)))

# A frame that does not fit is dropped; a host frame's loss stalls its TCP
# connection (the NAT does not retransmit), so it is logged.
def Net.rx.drop(-R: Type, host: Bool, q0: Q.Vq, used: Bool, k: Q.Vq & Bool -> V.Op<R, NetRx>) -> V.Op<R, NetRx>:
  match host:
    case True{}:
      do V.Op<R, NetRx>:
        V.Op.log(R, "net: a TCP segment does not fit the guest's receive buffer; dropped")
        k((q0, used))
    case False{}:
      k((q0, used))

# A popped chain: delivers the frame into it, or drops the frame and keeps the
# chain (continuing with q0, the queue before the pop).
def Net.rx.serve(
  -R: Type, fits: Bool, q0: Q.Vq, q: Q.Vq, c: Q.Chain, frame: +List<U32>, used: Bool,
  k: Q.Vq & Bool -> V.Op<R, NetRx>
) -> V.Op<R, NetRx>:
  match fits:
    case False{}:
      Net.rx.drop(R, W.Wire.is_host_frame(frame), q0, used, k)
    case True{}:
      V.Op.bind(R, Q.Vq, NetRx, Net.rx.deliver(R, q, c, frame), q2 => k((q2, True{})))

# After a pop: stops on an empty queue with the frame and the rest left, else
# serves the chain and continues with k.
def Net.rx.step(
  -R: Type, q0: Q.Vq, r: Q.Vq & Maybe<&2, Q.Chain>, +frame: +List<U32>,
  rest: +List<+List<U32>>, used: Bool, k: Q.Vq & Bool -> V.Op<R, NetRx>
) -> V.Op<R, NetRx>:
  match r:
    case (q, None{}):
      V.Op.pure(R, NetRx, NetRx{q, frame <> rest, used})
    case (q, Some{+c}):
      Net.rx.serve(R, Net.rx.fits(c, frame), q0, q, c, frame, used, k)

# Delivers or drops each frame in turn; st is the queue and whether any chain
# was used. Every step takes one frame, so the frames bound the loop.
def Net.rx.go(frames: +List<+List<U32>>, -R: Type, st: Q.Vq & Bool) -> V.Op<R, NetRx>:
  match frames:
    case Nil{}:
      match st:
        case (q, used):
          V.Op.pure(R, NetRx, NetRx{q, [], used})
    case Con{frame, +rest}:
      match st:
        case (+q, used):
          do V.Op<R, NetRx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Net.rx.step(R, q, r, frame, rest, used, st2 => Net.rx.go(rest, R, st2))

# Takes every available chain of transmitq1 (at most num): its readable
# bytes minus the 12-byte header form one frame (a chain of 12 bytes or less
# gives no frame), pushed used with length 0. Answers the queue, the frames
# in order, and whether any chain was used.
def Net.tx(-R: Type, q: Q.Vq) -> V.Op<R, NetTx>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Net.tx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, []), False{})

# Delivers frames into receiveq1, one frame per available chain, in order:
# header then frame, scattered over the chain's writable descriptors, pushed
# used with 12 + frame length. A frame larger than the chain's room is
# dropped and the chain is kept for the next frame. Stops when frames or
# chains run out.
# Answers the queue, the frames not delivered, and whether any chain was used.
def Net.rx(-R: Type, q: Q.Vq, frames: +List<+List<U32>>) -> V.Op<R, NetRx>:
  Net.rx.go(frames, R, (q, False{}))
