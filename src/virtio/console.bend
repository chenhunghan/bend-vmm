import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-console (Virtio 1.2 section 5.3), device id 3, one port, no
# features beyond VIRTIO_F_VERSION_1 (no size, no multiport), so the config
# space is empty. Queue 0 is receiveq0 (host to guest), queue 1 transmitq0
# (guest to host). Linux names the port /dev/hvc0.

# What a transmit pass produced.
type ConTx is Data:
  ConTx{q: Q.Vq, bytes: +List<U32>, used: Bool}

# What a receive pass did with the pending input.
type ConRx is Data:
  ConRx{q: Q.Vq, left: +List<U32>, used: Bool}

# Gathers one transmit chain and pushes it used with length 0; prepends its
# bytes to acc (newest chain first).
def Con.tx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, acc: +List<+List<U32>>
) -> V.Op<R, Q.Vq & +List<+List<U32>>>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq & +List<+List<U32>>>:
        bs : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, bs <> acc)

def Con.tx.done(-R: Type, q: Q.Vq, acc: +List<+List<U32>>, used: Bool) -> V.Op<R, ConTx>:
  V.Op.pure(R, ConTx, ConTx{q, List.concat(&2, U32, List.reverse(&2, +List<U32>, acc)), used})

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Con.tx.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, acc: +List<+List<U32>>, used: Bool,
  k: Q.Vq & +List<+List<U32>> -> V.Op<R, ConTx>
) -> V.Op<R, ConTx>:
  match r:
    case (q, None{}):
      Con.tx.done(R, q, acc, used)
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & +List<+List<U32>>, ConTx, Con.tx.serve(R, q, c, acc), k)

# Pops and serves transmit chains, at most fuel of them; st is the queue and
# the chains' bytes so far (newest first).
def Con.tx.go(fuel: Nat, -R: Type, st: Q.Vq & +List<+List<U32>>, used: Bool) -> V.Op<R, ConTx>:
  match fuel:
    case 0n:
      match st:
        case (q, acc):
          Con.tx.done(R, q, acc, used)
    case 1n+f:
      match st:
        case (q, acc):
          do V.Op<R, ConTx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Con.tx.step(R, r, acc, used, st2 => Con.tx.go(f, R, st2, True{}))

# Takes every available chain of transmitq0 (at most num): gathers its
# readable bytes, in chain order, and pushes it used with length 0. Answers
# the queue, all bytes in order, and whether any chain was used.
def Con.tx(-R: Type, q: Q.Vq) -> V.Op<R, ConTx>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Con.tx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, []), False{})

# Scatters input over one receive chain's writable descriptors, pushes it
# used with the count that fit, and answers the queue and the bytes left.
def Con.rx.serve(
  -R: Type, q: Q.Vq, c: Q.Chain, +input: +List<U32>
) -> V.Op<R, Q.Vq & +List<U32>>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq & +List<U32>>:
        +n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, input)
        q2 : Q.Vq <- Q.Vq.push(R, q, h, n)
        return (q2, List.drop(&2, U32, input, U32.to_nat(n)))

# After a pop: stops on an empty queue with the input left, else serves the
# chain and continues with k.
def Con.rx.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, input: +List<U32>, used: Bool,
  k: Q.Vq & +List<U32> -> V.Op<R, ConRx>
) -> V.Op<R, ConRx>:
  match r:
    case (q, None{}):
      V.Op.pure(R, ConRx, ConRx{q, input, used})
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & +List<U32>, ConRx, Con.rx.serve(R, q, c, input), k)

# Pops and fills receive chains, at most fuel of them, while input remains;
# st is the queue and the input left.
def Con.rx.go(fuel: Nat, -R: Type, st: Q.Vq & +List<U32>, used: Bool) -> V.Op<R, ConRx>:
  match fuel:
    case 0n:
      match st:
        case (q, input):
          V.Op.pure(R, ConRx, ConRx{q, input, used})
    case 1n+f:
      match st:
        case (q, Nil{}):
          V.Op.pure(R, ConRx, ConRx{q, [], used})
        case (q, Con{b, bs}):
          do V.Op<R, ConRx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Con.rx.step(R, r, b <> bs, used, st2 => Con.rx.go(f, R, st2, True{}))

# Delivers pending input into receiveq0: each available chain (at most num)
# takes as many bytes as its writable descriptors hold, pushed used with that
# length, until the input runs out (an empty input pops nothing). Answers the
# queue, the bytes that did not fit, and whether any chain was used.
def Con.rx(-R: Type, q: Q.Vq, input: +List<U32>) -> V.Op<R, ConRx>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Con.rx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, input), False{})
