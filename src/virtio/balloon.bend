import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-balloon (Virtio 1.2 section 5.5), device id 5, offered with
# --balloon free-page-reporting: VIRTIO_F_VERSION_1 and
# VIRTIO_BALLOON_F_FREE_PAGE_REPORTING (bit 5). Three queues, as Linux and
# QEMU number them when neither the stats nor the free page hint queue is
# offered: 0 inflateq, 1 deflateq, 2 reporting_vq. Config space: num_pages
# (u32, always 0: the host never asks the guest to inflate) and actual (u32).
#
# Free page reporting: every buffer on the reporting queue names free guest
# pages, one descriptor per range (Linux: blocks of its page_reporting_order,
# 2 MiB with 4 KiB pages). The host lets go of the memory behind each range
# (Op.ram_release: what the guest touches there again reads as zeros or as
# its old contents, never anything else), then returns the buffer, used
# length 0. Only the whole Balloon.align() blocks inside a range are
# released, so a host page is never cut (macOS: 16 KiB pages). Buffers on
# the inflate and deflate queues are returned untouched (num_pages is 0, so
# a driver posts none).

def Balloon.features() -> U.U64:
  U.U64{1, 32}

def Balloon.queues() -> Nat:
  3n

def Balloon.report_queue() -> U32:
  2

def Balloon.config() -> +List<U32>:
  B.Bytes.zeros(8n)

# The release granule: 64 KiB covers the host page sizes in use (4, 16 and
# 64 KiB).
def Balloon.align() -> U32:
  65536

# The whole granules inside [addr, addr+len): none (len 0) when there are
# none.
def Balloon.inside(+addr: U.U64, +len: U32) -> V.Iov:
  +a = U.U64.align_up(16n, addr)
  +e = U.U64.and(U.U64.add_u32(addr, len), U.U64.not(U.U64{0, 65535}))
  V.Iov{a, Bool.pick(U32, U.U64.is_lt(a, e), U.U64.lo(U.U64.sub(e, a)), 0)}

def Balloon.len(+i: V.Iov) -> U32:
  match i:
    case V.Iov{a, l}:
      l

# The granules of every descriptor of a buffer, the empty ones dropped.
def Balloon.ranges(ds: +List<Q.Desc>) -> +List<V.Iov>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case Q.Desc{+a, +l, f, n}:
          +i = Balloon.inside(a, l)
          +more = Balloon.ranges(rest)
          Bool.pick(+List<V.Iov>, U32.is_eq(Balloon.len(i), 0), more, Con{i, more})

def Balloon.free(-R: Type, go: Bool, +rs: +List<V.Iov>) -> V.Op<R, Unit>:
  match go:
    case True{}:
      V.Op.ram_release(R, rs)
    case False{}:
      V.Op.pure(R, Unit, Unit{})

def Balloon.serve(-R: Type, release: Bool, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      +rs = Balloon.ranges(List.append(&2, Q.Desc, r, w))
      do V.Op<R, Q.Vq>:
        Balloon.free(R, release && Bool.not(List.is_empty(&2, V.Iov, rs)), rs)
        Q.Vq.push(R, q, h, 0)

def Balloon.step(
  -R: Type, release: Bool, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool, k: Q.Vq -> V.Op<R, Q.Vq & Bool>
) -> V.Op<R, Q.Vq & Bool>:
  match r:
    case (q, None{}):
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, Q.Vq & Bool, Balloon.serve(R, release, q, c), k)

def Balloon.go(fuel: Nat, -R: Type, +release: Bool, q: Q.Vq, used: Bool) -> V.Op<R, Q.Vq & Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case 1n+f:
      do V.Op<R, Q.Vq & Bool>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Balloon.step(R, release, r, used, q2 => Balloon.go(f, R, release, q2, True{}))

# Queue sel's pass: the reporting queue releases what each buffer names;
# the others return their buffers. At most 256 buffers per pass.
def Balloon.process(-R: Type, +sel: U32, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  Balloon.go(256n, R, U32.is_eq(sel, Balloon.report_queue()), q, False{})

# Inflate and deflate (Virtio 1.2 5.5.6), with VIRTIO_BALLOON_F_DEFLATE_ON_OOM
# (bit 2) offered too (Balloon.offered): the host sets num_pages, a target
# in 4 KiB pages (`balloon MiB` on the control socket: Balloon.set_target);
# the guest gives pages to the balloon on the inflate queue and takes them
# back on the deflate queue, each buffer an array of u32 page frame numbers
# (4 KiB pages, at most Balloon.max_pfns() of them read per buffer). The
# device counts them (actual) and lets go of a 64 KiB block's memory once
# all its 16 pages are in the balloon: it keeps, per block that is partly
# in, a 16-bit mask of the pages that are. A deflated page leaves its mask;
# one of a block already released is not tracked again (its memory reads
# zeros when the guest touches it), so the device never releases a block
# with a page the guest still has.
def Balloon.offered() -> U.U64:
  U.U64{1, 36}

def Balloon.max_pfns() -> U32:
  256

type Part is Data:
  Part{block: U32, mask: U32}

type Bal is Data:
  Bal{target: U32, actual: U32, partial: +List<Part>}

def Balloon.new() -> Bal:
  Bal{0, 0, []}

# The config space of a state: num_pages (the target), actual.
def Balloon.config_of(+b: Bal) -> +List<U32>:
  match b:
    case Bal{t, a, p}:
      List.append(&2, U32, B.Bytes.le32(t), B.Bytes.le32(a))

def Balloon.set_target(+b: Bal, +pages: U32) -> Bal:
  match b:
    case Bal{t, a, p}:
      Bal{pages, a, p}

def Balloon.target(+b: Bal) -> U32:
  match b:
    case Bal{t, a, p}:
      t

def Balloon.actual(+b: Bal) -> U32:
  match b:
    case Bal{t, a, p}:
      a

# A page into its block's mask: the masks after it, and the block when it is
# now whole (U32 max when not).
type Took is Data:
  Took{parts: +List<Part>, whole: U32}

def Balloon.none() -> U32:
  4294967295

def Balloon.take.add(+p: Part, +t: Took) -> Took:
  match t:
    case Took{ps, w}:
      Took{Con{p, ps}, w}

def Balloon.take(ps: +List<Part>, +block: U32, +bit: U32) -> Took:
  match ps:
    case Nil{}:
      Took{[Part{block, bit}], Balloon.none()}
    case Con{p, +rest}:
      match p:
        case Part{+b, +m}:
          +m2 = (m .|. bit : U32)
          Bool.pick(Took, U32.is_eq(b, block),
            Bool.pick(Took, U32.is_eq(m2, 65535), Took{rest, block}, Took{Con{Part{b, m2}, rest}, Balloon.none()}),
            Balloon.take.add(Part{b, m}, Balloon.take(rest, block, bit)))

def Balloon.give(ps: +List<Part>, +block: U32, +bit: U32) -> +List<Part>:
  match ps:
    case Nil{}:
      []
    case Con{p, +rest}:
      match p:
        case Part{+b, +m}:
          +m2 = (m .&. U32.xor(65535, bit) : U32)
          Bool.pick(+List<Part>, U32.is_eq(b, block),
            Bool.pick(+List<Part>, U32.is_eq(m2, 0), rest, Con{Part{b, m2}, rest}),
            Con{Part{b, m}, Balloon.give(rest, block, bit)})

def Balloon.bit(+pfn: U32) -> U32:
  (1 << U32.to_nat((pfn .&. 15 : U32)) : U32)

# The released blocks of an inflate, as guest ranges.
def Balloon.block_iov(+block: U32) -> V.Iov:
  V.Iov{U.U64.shl(16n, U.U64{0, block}), 65536}

type Inflated is Data:
  Inflated{bal: Bal, free: +List<V.Iov>}

def Balloon.inflate.one(+t: Took, +ta: U32, +a: U32, +free: +List<V.Iov>) -> Inflated:
  match t:
    case Took{ps, w}:
      Inflated{Bal{ta, (a + 1 : U32), ps}, Bool.pick(+List<V.Iov>, U32.is_eq(w, Balloon.none()), free, Con{Balloon.block_iov(w), free})}

# Pages into the balloon: the state after them, and the blocks now whole.
def Balloon.inflate(pfns: +List<U32>, +i: Inflated) -> Inflated:
  match pfns:
    case Nil{}:
      i
    case Con{+pfn, rest}:
      match i:
        case Inflated{Bal{+t, +a, +ps}, +free}:
          Balloon.inflate(rest, Balloon.inflate.one(Balloon.take(ps, (pfn >> 4n : U32), Balloon.bit(pfn)), t, a, free))

# Pages out of the balloon.
def Balloon.deflate(pfns: +List<U32>, +b: Bal) -> Bal:
  match pfns:
    case Nil{}:
      b
    case Con{+pfn, rest}:
      match b:
        case Bal{+t, +a, +ps}:
          Balloon.deflate(rest, Bal{t, Bool.pick(U32, U32.is_eq(a, 0), 0, (a - 1 : U32)), Balloon.give(ps, (pfn >> 4n : U32), Balloon.bit(pfn))})

# The u32 page numbers of a buffer's bytes (little-endian).
def Balloon.pfns(fuel: Nat, bs: +List<U32>) -> +List<U32>:
  match fuel:
    case 0n:
      []
    case 1n+f:
      match bs:
        case Nil{}:
          []
        case Con{b, rest}:
          +all : +List<U32> = Con{b, rest}
          Bool.pick(+List<U32>, Nat.is_lt(List.length(&2, U32, all), 4n), [],
            Con{B.Bytes.read_le32(all), Balloon.pfns(f, List.drop(&2, U32, all, 4n))})

# A pass with the device's state.
type BalPass is Data:
  BalPass{q: Q.Vq, bal: Bal, used: Bool}

def Balloon.on_inflated(-R: Type, +i: Inflated) -> V.Op<R, Bal>:
  match i:
    case Inflated{+b2, +free}:
      do V.Op<R, Bal>:
        Balloon.free(R, Bool.not(List.is_empty(&2, V.Iov, free)), free)
        return b2

def Balloon.on_pfns(-R: Type, +inflate: Bool, +b: Bal, +pfns: +List<U32>) -> V.Op<R, Bal>:
  match inflate:
    case True{}:
      Balloon.on_inflated(R, Balloon.inflate(pfns, Inflated{b, []}))
    case False{}:
      V.Op.pure(R, Bal, Balloon.deflate(pfns, b))

# One inflate or deflate buffer: its page numbers read (at most
# max_pfns), counted, the whole blocks released; returned with length 0.
def Balloon.pfn_serve(-R: Type, +inflate: Bool, +b: Bal, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq & Bal>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq & Bal>:
        +bs : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 0, (Balloon.max_pfns() * 4 : U32)))
        b2 : Bal <- Balloon.on_pfns(R, inflate, b, Balloon.pfns(257n, bs))
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, b2)

def Balloon.pfn_step(
  -R: Type, +inflate: Bool, +b: Bal, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool, k: (Q.Vq & Bal) -> V.Op<R, BalPass>
) -> V.Op<R, BalPass>:
  match r:
    case (q, None{}):
      V.Op.pure(R, BalPass, BalPass{q, b, used})
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & Bal, BalPass, Balloon.pfn_serve(R, inflate, b, q, c), k)

def Balloon.pfn_split(-R: Type, qb: Q.Vq & Bal, k: Q.Vq -> Bal -> V.Op<R, BalPass>) -> V.Op<R, BalPass>:
  match qb:
    case (q, b):
      k(q)(b)

def Balloon.pfn_go(fuel: Nat, -R: Type, +inflate: Bool, +b: Bal, q: Q.Vq, used: Bool) -> V.Op<R, BalPass>:
  match fuel:
    case 0n:
      V.Op.pure(R, BalPass, BalPass{q, b, used})
    case 1n+f:
      do V.Op<R, BalPass>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Balloon.pfn_step(R, inflate, b, r, used, qb => Balloon.pfn_split(R, qb, q2 => b2 => Balloon.pfn_go(f, R, inflate, b2, q2, True{})))

# A queue's pass with the device's state: 2 reports free pages; 0 inflates,
# 1 deflates.
def Balloon.pass.report(-R: Type, +b: Bal, r: Q.Vq & Bool) -> BalPass:
  match r:
    case (q, used):
      BalPass{q, b, used}

def Balloon.pass.go(-R: Type, report: Bool, +sel: U32, +b: Bal, q: Q.Vq) -> V.Op<R, BalPass>:
  match report:
    case True{}:
      V.Op.bind(R, Q.Vq & Bool, BalPass, Balloon.process(R, sel, q), r => V.Op.pure(R, BalPass, Balloon.pass.report(R, b, r)))
    case False{}:
      Balloon.pfn_go(256n, R, U32.is_eq(sel, 0), b, q, False{})

def Balloon.pass(-R: Type, +sel: U32, +b: Bal, q: Q.Vq) -> V.Op<R, BalPass>:
  Balloon.pass.go(R, U32.is_eq(sel, Balloon.report_queue()), sel, b, q)
