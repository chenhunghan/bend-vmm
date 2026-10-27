import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./mmio.bend as M

# The split virtqueue (Virtio 1.2 section 2.7), operating on guest memory
# through Op. Layout, all little-endian:
#   descriptor table: num entries of 16 bytes: addr u64, len u32,
#     flags u16 (NEXT 1, WRITE 2, INDIRECT 4), next u16
#   driver area (available ring): flags u16, idx u16, ring[num] u16
#   device area (used ring): flags u16, idx u16, ring[num] {id u32, len u32}
# idx fields count modulo 65536; ring slots are idx modulo num.
# This VMM never offers VIRTIO_F_INDIRECT_DESC or EVENT_IDX, so a chain is
# a plain NEXT-linked list. A chain is cut after num descriptors (a loop in a
# malformed chain must not hang the VMM).

type Desc is Data:
  Desc{addr: U.U64, len: U32, flags: U32, next: U32}

# A descriptor chain: its head index, then the device-readable descriptors
# and the device-writable ones, each in chain order.
type Chain is Data:
  Chain{head: U32, readable: +List<Desc>, writable: +List<Desc>}

# A queue as the device sees it: size, the three areas, and the next ring
# positions (both modulo 65536).
type Vq is Data:
  Vq{num: U32, desc: U.U64, driver: U.U64, device: U.U64, next_avail: U32, next_used: U32}

def Chain.head(c: Chain) -> U32:
  match c:
    case Chain{h, r, w}:
      h

def Desc.is_eq(a: Desc, b: Desc) -> Bool:
  match a b:
    case Desc{aa, al, af, an} Desc{ba, bl, bf, bn}:
      U.U64.is_eq(aa, ba) && U32.is_eq(al, bl) && U32.is_eq(af, bf) && U32.is_eq(an, bn)

def Desc.list_eq(xs: +List<Desc>, ys: +List<Desc>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{x, xt} Con{y, yt}:
      Desc.is_eq(x, y) && Desc.list_eq(xt, yt)
    case _ _:
      False{}

def Chain.is_eq(a: Chain, b: Chain) -> Bool:
  match a b:
    case Chain{ah, ar, aw} Chain{bh, br, bw}:
      U32.is_eq(ah, bh) && Desc.list_eq(ar, br) && Desc.list_eq(aw, bw)

def Chain.is_eq_maybe(a: Maybe<&2, Chain>, b: Maybe<&2, Chain>) -> Bool:
  match a b:
    case None{} None{}:
      True{}
    case Some{x} Some{y}:
      Chain.is_eq(x, y)
    case _ _:
      False{}

def Vq.is_eq(a: Vq, b: Vq) -> Bool:
  match a b:
    case Vq{an, ad, adr, adv, aa, au} Vq{bn, bd, bdr, bdv, ba, bu}:
      (U32.is_eq(an, bn) && U.U64.is_eq(ad, bd) && U.U64.is_eq(adr, bdr)
        && U.U64.is_eq(adv, bdv) && U32.is_eq(aa, ba) && U32.is_eq(au, bu))

# The queue of a transport's config; num is clamped to num_max (the
# transport already drops a larger QueueNum).
def Vq.from_cfg(cfg: M.QueueCfg) -> Vq:
  match cfg:
    case M.QueueCfg{num_max, num, ready, desc, driver, device}:
      Vq{U32.min(num, num_max), desc, driver, device, 0, 0}

# Parses one 16-byte descriptor.
def Desc.parse(bs: +List<U32>) -> Desc:
  +bs = bs
  addr = B.Bytes.read_le64(bs)
  len = B.Bytes.read_le32(List.drop(&2, U32, bs, 8n))
  flags = B.Bytes.read_le16(List.drop(&2, U32, bs, 12n))
  next = B.Bytes.read_le16(List.drop(&2, U32, bs, 14n))
  Desc{addr, len, flags, next}

# Flag bits.
def Desc.f_next() -> U32:
  1

def Desc.f_write() -> U32:
  2

def Desc.is_write(d: Desc) -> Bool:
  match d:
    case Desc{a, l, f, n}:
      U32.is_ne((f .&. Desc.f_write() : U32), 0)

# The index i, when it names a slot of a table of num descriptors.
def Vq.index(+i: U32, num: U32) -> Maybe<&2, U32>:
  Bool.pick(Maybe<&2, U32>, U32.is_lt(i, num), Some{i}, None{})

# The descriptor the chain continues with, if d has NEXT and it is in range.
def Desc.follow(d: Desc, num: U32) -> Maybe<&2, U32>:
  match d:
    case Desc{a, l, f, n}:
      Bool.pick(Maybe<&2, U32>, U32.is_ne((f .&. Desc.f_next() : U32), 0), Vq.index(n, num), None{})

# Prepends d to the readable list (reversed) unless it is device-writable.
def Desc.add_readable(+d: Desc, +rd: +List<Desc>) -> +List<Desc>:
  Bool.pick(+List<Desc>, Desc.is_write(d), rd, d <> rd)

# Prepends d to the writable list (reversed) when it is device-writable.
def Desc.add_writable(+d: Desc, +wr: +List<Desc>) -> +List<Desc>:
  Bool.pick(+List<Desc>, Desc.is_write(d), d <> wr, wr)

# Index n modulo 65536, the width of the ring idx fields.
def Vq.wrap(n: U32) -> U32:
  (n .&. 65535 : U32)

# Walks a chain from descriptor `cur`, at most fuel descriptors; rd and wr
# collect the readable and writable descriptors in reverse.
def Vq.walk(
  fuel: Nat, -R: Type, +num: U32, +desc: U.U64, cur: Maybe<&2, U32>,
  rd: +List<Desc>, wr: +List<Desc>
) -> V.Op<R, +List<Desc> & +List<Desc>>:
  match fuel:
    case 0n:
      V.Op.pure(R, +List<Desc> & +List<Desc>, (List.reverse(&2, Desc, rd), List.reverse(&2, Desc, wr)))
    case 1n+f:
      match cur:
        case None{}:
          V.Op.pure(R, +List<Desc> & +List<Desc>, (List.reverse(&2, Desc, rd), List.reverse(&2, Desc, wr)))
        case Some{i}:
          do V.Op<R, +List<Desc> & +List<Desc>>:
            +bs : +List<U32> <- V.Op.read(R, U.U64.add_u32(desc, (i * 16 : U32)), 16)
            +d : Desc = Desc.parse(bs)
            Vq.walk(f, R, num, desc, Desc.follow(d, num), Desc.add_readable(d, rd), Desc.add_writable(d, wr))

def Vq.pop.fin(q: Vq, head: U32, ds: +List<Desc> & +List<Desc>) -> Vq & Maybe<&2, Chain>:
  match ds:
    case (rd, wr):
      (q, Some{Chain{head, rd, wr}})

# Reads the head of the chain at ring slot next_avail and walks it.
def Vq.pop.take(-R: Type, q: Vq) -> V.Op<R, Vq & Maybe<&2, Chain>>:
  match q:
    case Vq{+num, +desc, +driver, device, +na, nu}:
      slot = (U32.mod(na, num) * 2 : U32)
      do V.Op<R, Vq & Maybe<&2, Chain>>:
        +hb : +List<U32> <- V.Op.read(R, U.U64.add_u32(driver, (4 + slot : U32)), 2)
        +head : U32 = B.Bytes.read_le16(hb)
        ds : +List<Desc> & +List<Desc> <- Vq.walk(U32.to_nat(num), R, num, desc, Vq.index(head, num), [], [])
        return Vq.pop.fin(Vq{num, desc, driver, device, Vq.wrap((na + 1 : U32)), nu}, head, ds)

def Vq.pop.go(-R: Type, empty: Bool, q: Vq) -> V.Op<R, Vq & Maybe<&2, Chain>>:
  match empty:
    case True{}:
      V.Op.pure(R, Vq & Maybe<&2, Chain>, (q, None{}))
    case False{}:
      Vq.pop.take(R, q)

def Vq.pop.avail(-R: Type, q: Vq, avail: U32) -> V.Op<R, Vq & Maybe<&2, Chain>>:
  match q:
    case Vq{+num, desc, driver, device, +na, nu}:
      empty = U32.is_zero(num) || U32.is_eq(Vq.wrap(avail), Vq.wrap(na))
      Vq.pop.go(R, empty, Vq{num, desc, driver, device, na, nu})

# Takes the next available chain, if the driver has published one.
def Vq.pop(-R: Type, q: Vq) -> V.Op<R, Vq & Maybe<&2, Chain>>:
  match q:
    case Vq{num, desc, +driver, device, na, nu}:
      do V.Op<R, Vq & Maybe<&2, Chain>>:
        +bs : +List<U32> <- V.Op.read(R, U.U64.add_u32(driver, 2), 2)
        Vq.pop.avail(R, Vq{num, desc, driver, device, na, nu}, B.Bytes.read_le16(bs))

# Writes the used element at ring slot next_used, then publishes the new idx.
def Vq.push.write(-R: Type, q: Vq, +head: U32, +len: U32) -> V.Op<R, Vq>:
  match q:
    case Vq{+num, desc, driver, +device, na, +nu}:
      slot = (U32.mod(nu, num) * 8 : U32)
      +used = Vq.wrap((nu + 1 : U32))
      elem = List.append(&2, U32, B.Bytes.le32(head), B.Bytes.le32(len))
      do V.Op<R, Vq>:
        V.Op.write(R, U.U64.add_u32(device, (4 + slot : U32)), elem)
        V.Op.write(R, U.U64.add_u32(device, 2), B.Bytes.le16(used))
        return Vq{num, desc, driver, device, na, used}

def Vq.push.go(-R: Type, empty: Bool, q: Vq, head: U32, len: U32) -> V.Op<R, Vq>:
  match empty:
    case True{}:
      V.Op.pure(R, Vq, q)
    case False{}:
      Vq.push.write(R, q, head, len)

# Returns chain `head` to the driver as used, with `len` bytes written.
def Vq.push(-R: Type, q: Vq, head: U32, len: U32) -> V.Op<R, Vq>:
  match q:
    case Vq{+num, desc, driver, device, na, nu}:
      Vq.push.go(R, U32.is_zero(num), Vq{num, desc, driver, device, na, nu}, head, len)

def Vq.read_desc(-R: Type, d: Desc) -> V.Op<R, +List<U32>>:
  match d:
    case Desc{a, l, f, n}:
      V.Op.read(R, a, l)

def Vq.cat(-R: Type, a: V.Op<R, +List<U32>>, b: V.Op<R, +List<U32>>) -> V.Op<R, +List<U32>>:
  do V.Op<R, +List<U32>>:
    xs : +List<U32> <- a
    ys : +List<U32> <- b
    return List.append(&2, U32, xs, ys)

# Builds the reads of n descriptors: halves are independent, so they are
# built in parallel. fuel bounds the depth (n descriptors need at most n).
def Vq.gather.go(fuel: Nat, -R: Type, +n: Nat, ds: +List<Desc>) -> V.Op<R, +List<U32>>:
  match fuel:
    case 0n:
      V.Op.pure(R, +List<U32>, [])
    case 1n+(+f):
      match ds:
        case Nil{}:
          V.Op.pure(R, +List<U32>, [])
        case Con{d, Nil{}}:
          Vq.read_desc(R, d)
        case Con{+d, +rest}:
          +all = {d <> rest : +List<Desc>}
          +h = Nat.div(n, 2n)
          a b = Vq.gather.go(f, R, h, List.take(&2, Desc, all, h)) Vq.gather.go(f, R, Nat.sub(n, h), List.drop(&2, Desc, all, h))
          Vq.cat(R, a, b)

# Gathers the bytes of every readable descriptor of a chain, in order.
def Vq.gather(-R: Type, c: Chain) -> V.Op<R, +List<U32>>:
  match c:
    case Chain{h, +r, w}:
      +n = List.length(&2, Desc, r)
      Vq.gather.go(n, R, n, r)

# Writes the head of bytes that fits d, then the rest over ds; answers the
# count written.
def Vq.scatter.go(-R: Type, ds: +List<Desc>, bytes: +List<U32>) -> V.Op<R, U32>:
  match ds:
    case Nil{}:
      V.Op.pure(R, U32, 0)
    case Con{Desc{a, l, fl, nx}, rest}:
      match bytes:
        case Nil{}:
          V.Op.pure(R, U32, 0)
        case Con{+b, +bt}:
          +all = {b <> bt : +List<U32>}
          +cap = U32.to_nat(l)
          +part = List.take(&2, U32, all, cap)
          +k = U32.from_nat(List.length(&2, U32, part))
          do V.Op<R, U32>:
            V.Op.write(R, a, part)
            m : U32 <- Vq.scatter.go(R, rest, List.drop(&2, U32, all, cap))
            return (k + m : U32)

# Scatters bytes over the writable descriptors of a chain, in order, and
# answers how many bytes fit.
def Vq.scatter(-R: Type, c: Chain, bytes: +List<U32>) -> V.Op<R, U32>:
  match c:
    case Chain{h, r, w}:
      Vq.scatter.go(R, w, bytes)

def Iov.add(+s: V.Iov, +ss: +List<V.Iov>) -> +List<V.Iov>:
  match s:
    case V.Iov{a, +l}:
      Bool.pick(+List<V.Iov>, U32.is_zero(l), ss, V.Iov{a, l} <> ss)

# The memory of ds after its first skip bytes, at most max bytes of it, in
# chain order (empty pieces left out).
def Vq.segs(ds: +List<Desc>, +skip: U32, +max: U32) -> +List<V.Iov>:
  match ds:
    case Nil{}:
      []
    case Desc{+a, +l, f, n} <> t:
      +past = U32.is_ge(skip, l)
      +off = Bool.pick(U32, past, l, skip)
      +take = U32.min((l - off : U32), max)
      Iov.add(V.Iov{U.U64.add_u32(a, off), take}, Vq.segs(t, Bool.pick(U32, past, (skip - l : U32), 0), (max - take : U32)))

# Reads the pieces of guest memory, in order.
def Vq.read_segs(-R: Type, ss: +List<V.Iov>) -> V.Op<R, +List<U32>>:
  match ss:
    case Nil{}:
      V.Op.pure(R, +List<U32>, [])
    case V.Iov{a, l} <> t:
      Vq.cat(R, V.Op.read(R, a, l), Vq.read_segs(R, t))
