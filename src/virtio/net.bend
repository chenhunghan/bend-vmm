import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-net (Virtio 1.2 section 5.1), device id 1. Offered features:
# VIRTIO_F_VERSION_1 (bit 32) and VIRTIO_NET_F_MAC (bit 5); so the config
# space is the 6-byte MAC (Net.config). Queue 0 is receiveq1 (host to
# guest), queue 1 transmitq1 (guest to host).
#
# Every buffer starts with the 12-byte virtio_net_hdr (VERSION_1 layout):
# flags u8, gso_type u8, hdr_len u16, gso_size u16, csum_start u16,
# csum_offset u16, num_buffers u16. Transmit strips it; receive writes it as
# all zeros except num_buffers = 1, then the frame.

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

# Gathers one transmit chain, pushes it used with length 0, and keeps its frame.
def Net.tx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        bs : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, Net.keep(bs, acc))

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

# Writes the header and the frame over a receive chain and pushes it used
# with 12 + frame length.
def Net.rx.deliver(-R: Type, q: Q.Vq, c: Q.Chain, +frame: +List<U32>) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      len = (12 + U32.from_nat(List.length(&2, U32, frame)) : U32)
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, List.append(&2, U32, Net.hdr(), frame))
        Q.Vq.push(R, q, h, len)

# Whether the header and the frame fit the chain's writable room.
def Net.rx.fits(c: Q.Chain, +frame: +List<U32>) -> Bool:
  match c:
    case Q.Chain{h, r, w}:
      Nat.is_le(12n+List.length(&2, U32, frame), U32.to_nat(Net.room(w)))

# A popped chain: delivers the frame into it, or drops the frame and keeps the
# chain (continuing with q0, the queue before the pop).
def Net.rx.serve(
  -R: Type, fits: Bool, q0: Q.Vq, q: Q.Vq, c: Q.Chain, frame: +List<U32>, used: Bool,
  k: Q.Vq & Bool -> V.Op<R, NetRx>
) -> V.Op<R, NetRx>:
  match fits:
    case False{}:
      k((q0, used))
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
