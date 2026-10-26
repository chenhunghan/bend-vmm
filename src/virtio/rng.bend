import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-entropy (Virtio 1.2 section 5.4), device id 4: one queue, no config,
# no device features beyond VIRTIO_F_VERSION_1. Every buffer the driver
# posts is filled with host entropy.

# The total length of a chain's writable descriptors.
def Rng.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Rng.room(t) : U32)

# Fills one chain's writable descriptors with entropy and pushes it used.
def Rng.serve(-R: Type, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, +w}:
      do V.Op<R, Q.Vq>:
        +bs : +List<U32> <- V.Op.random(R, Rng.room(w))
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, bs)
        Q.Vq.push(R, q, h, n)

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Rng.step(
  -R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool, k: Q.Vq -> V.Op<R, Q.Vq & Bool>
) -> V.Op<R, Q.Vq & Bool>:
  match r:
    case (q, None{}):
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, Q.Vq & Bool, Rng.serve(R, q, c), k)

# Pops and serves chains, at most fuel of them; used tells whether any was.
def Rng.go(fuel: Nat, -R: Type, q: Q.Vq, used: Bool) -> V.Op<R, Q.Vq & Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case 1n+f:
      do V.Op<R, Q.Vq & Bool>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Rng.step(R, r, used, q2 => Rng.go(f, R, q2, True{}))

# Serves every available chain of the request queue: fills its writable
# descriptors with Op.random bytes (as many as they hold), pushes it used with
# that length. At most num chains per call. Answers the queue and whether any
# chain was used.
def Rng.process(-R: Type, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Rng.go(U32.to_nat(num), R, Q.Vq{num, d, dr, dv, na, nu}, False{})
