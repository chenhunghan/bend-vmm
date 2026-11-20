import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q
import ./balauto.bend as A

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
# released: 16 KiB, a host page on macOS and a whole number of them on a
# 4 KiB host (a 64 KiB-page host releases the whole pages inside, none of a
# 16 KiB block). Coarser blocks left most of a fragmented guest's memory
# charged to the host (64 KiB: 841 MiB in the balloon, ~550 MiB of it kept). Buffers on
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

# The release granule: 16 KiB, macOS's host page.
def Balloon.align() -> U32:
  16384

# The whole granules inside [addr, addr+len): none (len 0) when there are
# none.
def Balloon.inside(+addr: U.U64, +len: U32) -> V.Iov:
  +a = U.U64.align_up(14n, addr)
  +e = U.U64.and(U.U64.add_u32(addr, len), U.U64.not(U.U64{0, 16383}))
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
# device counts them (actual) and lets go of a 16 KiB block's memory once
# all its 4 pages are in the balloon: it keeps, per block that is partly
# in, a 4-bit mask of the pages that are. A deflated page leaves its mask;
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

# The pages the balloon holds that the host could not release: those of
# its partial blocks (a 16 KiB block is released only once all four of its
# pages are in the balloon).
def Balloon.bits(+m: U32) -> U32:
  ((m .&. 1 : U32) + (((m >> 1n : U32) .&. 1 : U32) + (((m >> 2n : U32) .&. 1 : U32) + ((m >> 3n : U32) .&. 1 : U32) : U32) : U32) : U32)

def Balloon.kept.go(ps: +List<Part>) -> U32:
  match ps:
    case Nil{}:
      0
    case Con{p, rest}:
      match p:
        case Part{b, +m}:
          (Balloon.bits(m) + Balloon.kept.go(rest) : U32)

def Balloon.kept(+b: Bal) -> U32:
  match b:
    case Bal{t, a, ps}:
      Balloon.kept.go(ps)

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
            Bool.pick(Took, U32.is_eq(m2, 15), Took{rest, block}, Took{Con{Part{b, m2}, rest}, Balloon.none()}),
            Balloon.take.add(Part{b, m}, Balloon.take(rest, block, bit)))

def Balloon.give(ps: +List<Part>, +block: U32, +bit: U32) -> +List<Part>:
  match ps:
    case Nil{}:
      []
    case Con{p, +rest}:
      match p:
        case Part{+b, +m}:
          +m2 = (m .&. U32.xor(15, bit) : U32)
          Bool.pick(+List<Part>, U32.is_eq(b, block),
            Bool.pick(+List<Part>, U32.is_eq(m2, 0), rest, Con{Part{b, m2}, rest}),
            Con{Part{b, m}, Balloon.give(rest, block, bit)})

def Balloon.bit(+pfn: U32) -> U32:
  (1 << U32.to_nat((pfn .&. 3 : U32)) : U32)

# A snapshot taken with 64 KiB blocks (state tags 7 and 8): each mask of 16
# pages as the masks of its four 16 KiB blocks (none for an empty quarter).
# A quarter all in the balloon was not released then: it keeps a whole mask
# and stays until deflated.
def Balloon.parts16.q(+b: U32, +m: U32, +q: U32, +rest: +List<Part>) -> +List<Part>:
  +nib = ((m >> U32.to_nat((q * 4 : U32))) .&. 15 : U32)
  Bool.pick(+List<Part>, U32.is_zero(nib), rest, Con{Part{((b * 4 : U32) + q : U32), nib}, rest})

def Balloon.parts16(ps: +List<Part>) -> +List<Part>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      match p:
        case Part{+b, +m}:
          Balloon.parts16.q(b, m, 0, Balloon.parts16.q(b, m, 1, Balloon.parts16.q(b, m, 2, Balloon.parts16.q(b, m, 3, Balloon.parts16(rest)))))

# The released blocks of an inflate, as guest ranges.
def Balloon.block_iov(+block: U32) -> V.Iov:
  V.Iov{U.U64.shl(14n, U.U64{0, block}), 16384}

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
          Balloon.inflate(rest, Balloon.inflate.one(Balloon.take(ps, (pfn >> 2n : U32), Balloon.bit(pfn)), t, a, free))

# Pages out of the balloon.
def Balloon.deflate(pfns: +List<U32>, +b: Bal) -> Bal:
  match pfns:
    case Nil{}:
      b
    case Con{+pfn, rest}:
      match b:
        case Bal{+t, +a, +ps}:
          Balloon.deflate(rest, Bal{t, Bool.pick(U32, U32.is_eq(a, 0), 0, (a - 1 : U32)), Balloon.give(ps, (pfn >> 2n : U32), Balloon.bit(pfn))})

# A whole buffer of page numbers at once (Balloon.on_pfns): the same state
# as Balloon.inflate and Balloon.deflate one page at a time, with the masks
# in block order, in one walk of them (one page at a time walks them once
# per page: a fragmented guest's balloon holds tens of thousands of partial
# blocks, and inflating into it took seconds per MiB).
def Balloon.part_le(x: Part, y: Part) -> Bool:
  match x:
    case Part{+a, m}:
      match y:
        case Part{+b, n}:
          U32.is_le(a, b)

def Balloon.part_of(+pfn: U32) -> Part:
  Part{(pfn >> 2n : U32), Balloon.bit(pfn)}

def Balloon.parts_of(pfns: +List<U32>) -> +List<Part>:
  match pfns:
    case Nil{}:
      []
    case Con{+pfn, rest}:
      Con{Balloon.part_of(pfn), Balloon.parts_of(rest)}

# A part onto sorted parts: joined with the first when they share a block.
def Balloon.join_into(+p: Part, xs: +List<Part>) -> +List<Part>:
  match p:
    case Part{+b, +m}:
      match xs:
        case Nil{}:
          [Part{b, m}]
        case Con{x, +rest}:
          match x:
            case Part{+c, +n}:
              Bool.pick(+List<Part>, U32.is_eq(b, c), Con{Part{b, (m .|. n : U32)}, rest}, Con{Part{b, m}, Con{Part{c, n}, rest}})

def Balloon.join(ps: +List<Part>) -> +List<Part>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      Balloon.join_into(p, Balloon.join(rest))

# A buffer's pages as masks, one per block, in block order.
def Balloon.batch(+pfns: +List<U32>) -> +List<Part>:
  Balloon.join(List.sort(~Part, ~Balloon.part_le, Balloon.parts_of(pfns)))

def Balloon.ordered.go(ps: +List<Part>, +prev: U32) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{p, rest}:
      match p:
        case Part{+b, m}:
          Bool.and(U32.is_lt(prev, b), Balloon.ordered.go(rest, b))

def Balloon.ordered.pick(sorted: Bool, +ps: +List<Part>) -> +List<Part>:
  match sorted:
    case True{}:
      ps
    case False{}:
      List.sort(~Part, ~Balloon.part_le, ps)

# The masks in block order (a state from an older snapshot may hold them in
# any order).
def Balloon.ordered(+ps: +List<Part>) -> +List<Part>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      match p:
        case Part{+b, +m}:
          Balloon.ordered.pick(Balloon.ordered.go(rest, b), Con{Part{b, m}, rest})

def Balloon.keep(+p: Part, +i: Inflated) -> Inflated:
  match i:
    case Inflated{Bal{t, a, ps}, free}:
      Inflated{Bal{t, a, Con{p, ps}}, free}

def Balloon.one_in(+b: U32, +m: U32, +i: Inflated) -> Inflated:
  match i:
    case Inflated{Bal{t, a, ps}, +free}:
      Bool.pick(Inflated, U32.is_eq(m, 15), Inflated{Bal{t, a, ps}, Con{Balloon.block_iov(b), free}}, Inflated{Bal{t, a, Con{Part{b, m}, ps}}, free})

def Balloon.in_only(ns: +List<Part>) -> Inflated:
  match ns:
    case Nil{}:
      Inflated{Bal{0, 0, []}, []}
    case Con{n, rest}:
      match n:
        case Part{+b, +m}:
          Balloon.one_in(b, m, Balloon.in_only(rest))

# Sorted masks and a sorted batch: the masks after it (count and target
# left 0: Balloon.inflate_all sets them), and the blocks now whole.
def Balloon.in_merge(fuel: Nat, os: +List<Part>, ns: +List<Part>) -> Inflated:
  match fuel:
    case 0n:
      Inflated{Bal{0, 0, os}, []}
    case 1n+f:
      match os:
        case Nil{}:
          Balloon.in_only(ns)
        case Con{o, +orest}:
          match o:
            case Part{+ob, +om}:
              match ns:
                case Nil{}:
                  Inflated{Bal{0, 0, Con{Part{ob, om}, orest}}, []}
                case Con{n, +nrest}:
                  match n:
                    case Part{+nb, +nm}:
                      +lt = U32.is_lt(ob, nb)
                      +gt = U32.is_lt(nb, ob)
                      Balloon.one_in(Bool.pick(U32, gt, nb, ob), Bool.pick(U32, lt, om, Bool.pick(U32, gt, nm, (om .|. nm : U32))),
                        Balloon.in_merge(f, Bool.pick(+List<Part>, gt, Con{Part{ob, om}, orest}, orest), Bool.pick(+List<Part>, lt, Con{Part{nb, nm}, nrest}, nrest)))

def Balloon.in_set(+t: U32, +a: U32, +i: Inflated) -> Inflated:
  match i:
    case Inflated{Bal{x, y, ps}, free}:
      Inflated{Bal{t, a, ps}, free}

def Balloon.inflate_all(+pfns: +List<U32>, +b: Bal) -> Inflated:
  match b:
    case Bal{+t, +a, +ps}:
      +os = Balloon.ordered(ps)
      +ns = Balloon.batch(pfns)
      Balloon.in_set(t, (a + U32.from_nat(List.length(&2, U32, pfns)) : U32),
        Balloon.in_merge(Nat.add(List.length(&2, Part, os), List.length(&2, Part, ns)), os, ns))

def Balloon.out_one(+b: U32, +m: U32, +rest: +List<Part>) -> +List<Part>:
  Bool.pick(+List<Part>, U32.is_zero(m), rest, Con{Part{b, m}, rest})

def Balloon.out_merge(fuel: Nat, os: +List<Part>, ns: +List<Part>) -> +List<Part>:
  match fuel:
    case 0n:
      os
    case 1n+f:
      match os:
        case Nil{}:
          []
        case Con{o, +orest}:
          match o:
            case Part{+ob, +om}:
              match ns:
                case Nil{}:
                  Con{Part{ob, om}, orest}
                case Con{n, +nrest}:
                  match n:
                    case Part{+nb, +nm}:
                      +lt = U32.is_lt(ob, nb)
                      +gt = U32.is_lt(nb, ob)
                      Balloon.out_one(ob, Bool.pick(U32, lt, om, Bool.pick(U32, gt, 0, (om .&. U32.xor(15, nm) : U32))),
                        Balloon.out_merge(f, Bool.pick(+List<Part>, gt, Con{Part{ob, om}, orest}, orest), Bool.pick(+List<Part>, lt, Con{Part{nb, nm}, nrest}, nrest)))

def Balloon.deflate_all(+pfns: +List<U32>, +b: Bal) -> Bal:
  match b:
    case Bal{+t, +a, +ps}:
      +os = Balloon.ordered(ps)
      +ns = Balloon.batch(pfns)
      +k = U32.from_nat(List.length(&2, U32, pfns))
      Bal{t, Bool.pick(U32, U32.is_le(a, k), 0, (a - k : U32)), Balloon.out_merge(Nat.add(List.length(&2, Part, os), List.length(&2, Part, ns)), os, ns)}

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
      Balloon.on_inflated(R, Balloon.inflate_all(pfns, b))
    case False{}:
      V.Op.pure(R, Bal, Balloon.deflate_all(pfns, b))

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

# The automatic balloon (src/virtio/balauto.bend)
# ===============================================
#
# --balloon auto (the default) offers the stats queue too
# (VIRTIO_BALLOON_F_STATS_VQ, bit 1): four queues. The driver numbers its
# queues by what it accepted: with the stats queue, 2 is stats and 3
# reporting. Dev.notify maps them to this module's own numbers, which do
# not depend on it: 0 inflate, 1 deflate, 2 reporting
# (Balloon.report_queue()), 3 stats (Balloon.stats_queue()).

def Balloon.offered_auto() -> U.U64:
  U.U64{1, 38}

def Balloon.queues_auto() -> Nat:
  4n

def Balloon.stats_queue() -> U32:
  3

# The driver's number for one of ours (stats: it accepted the stats queue).
def Balloon.logical(+stats: Bool, +sel: U32) -> U32:
  Bool.pick(U32, stats && U32.is_eq(sel, 2), 3, Bool.pick(U32, stats && U32.is_eq(sel, 3), 2, sel))

# What the automatic balloon keeps: the stats buffer the driver posted and
# the device holds (its head; Auto.none() when none), whether the host asked
# for the statistics it will bring (only an answer moves the target: the
# first buffer, posted at the driver's start, does not), whether a target
# was set by hand (`balloon MiB`: the automatic balloon stands aside), and
# the latest statistics.
type AutoSt is Data:
  AutoSt{held: U32, asked: Bool, manual: Bool, stats: A.Stats}

def Balloon.auto_new() -> AutoSt:
  AutoSt{A.Auto.none(), False{}, False{}, A.Auto.fresh()}

def Balloon.auto_manual(+a: AutoSt, +manual: Bool) -> AutoSt:
  match a:
    case AutoSt{h, k, m, st}:
      AutoSt{h, k, manual, st}

def Balloon.auto_held(+a: AutoSt) -> U32:
  match a:
    case AutoSt{h, k, m, st}:
      h

def Balloon.auto_on(+a: AutoSt) -> Bool:
  match a:
    case AutoSt{h, k, m, st}:
      Bool.not(m)

# The target after a stats buffer: moved only when the host asked for it
# and no target was set by hand.
# (the balloon holding at most pct percent of the guest's RAM)
def Balloon.auto_target(+asked: Bool, +manual: Bool, +st: A.Stats, +b: Bal, +pct: U32) -> Bal:
  Bool.pick(Bal, asked && Bool.not(manual), Balloon.set_target(b, A.Auto.target_at(st, U32.min(Balloon.target(b), Balloon.actual(b)), pct)), b)

type StatsPass is Data:
  StatsPass{q: Q.Vq, bal: Bal, auto: AutoSt}

def Balloon.stats.serve(-R: Type, +b: Bal, a: AutoSt, q: Q.Vq, c: Q.Chain, +pct: U32) -> V.Op<R, StatsPass>:
  match a c:
    case AutoSt{old, +asked, +manual, +st0} Q.Chain{+h, r, w}:
      do V.Op<R, StatsPass>:
        +bs : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 0, 640))
        +st : A.Stats = A.Auto.stats(bs, st0)
        return StatsPass{q, Balloon.auto_target(asked, manual, st, b, pct), AutoSt{h, False{}, manual, st}}

def Balloon.stats.got(-R: Type, +b: Bal, +a: AutoSt, r: Q.Vq & Maybe<&2, Q.Chain>, +pct: U32) -> V.Op<R, StatsPass>:
  match r:
    case (q, None{}):
      V.Op.pure(R, StatsPass, StatsPass{q, b, a})
    case (q, Some{c}):
      Balloon.stats.serve(R, b, a, q, c, pct)

# The stats queue's pass: the buffer the driver posted is read and held
# (the host returns it when it wants fresh statistics: Balloon.poll).
def Balloon.stats_pass_at(-R: Type, +b: Bal, +a: AutoSt, q: Q.Vq, +pct: U32) -> V.Op<R, StatsPass>:
  V.Op.bind(R, Q.Vq & Maybe<&2, Q.Chain>, StatsPass, Q.Vq.pop(R, q), r => Balloon.stats.got(R, b, a, r, pct))

# (at most half the guest's RAM: the default)
def Balloon.stats_pass(-R: Type, +b: Bal, +a: AutoSt, q: Q.Vq) -> V.Op<R, StatsPass>:
  Balloon.stats_pass_at(R, b, a, q, 50)

# After a deflate pass of the automatic balloon (on: its own, not a target
# set by hand), a guest that took pages back on its own gets the rest of
# what it needs at once (A.Auto.oom).
def Balloon.after_deflate(+on: Bool, +b: Bal) -> Bal:
  Bool.pick(Bal, on, Balloon.set_target(b, A.Auto.oom(Balloon.target(b), Balloon.actual(b))), b)

def Balloon.pass_after(+on: Bool, r: BalPass) -> BalPass:
  match r:
    case BalPass{q, b, used}:
      BalPass{q, Balloon.after_deflate(on, b), used}

# Asking for fresh statistics: the held buffer returned (used length 0);
# the driver posts it again with new values. Nothing when none is held or
# a target was set by hand.
def Balloon.poll.go(-R: Type, skip: Bool, +h: U32, +k: Bool, +manual: Bool, +st: A.Stats, q: Q.Vq) -> V.Op<R, (Q.Vq & AutoSt) & Bool>:
  match skip:
    case True{}:
      V.Op.pure(R, (Q.Vq & AutoSt) & Bool, ((q, AutoSt{h, k, manual, st}), False{}))
    case False{}:
      V.Op.bind(R, Q.Vq, (Q.Vq & AutoSt) & Bool, Q.Vq.push(R, q, h, 0), q2 =>
        V.Op.pure(R, (Q.Vq & AutoSt) & Bool, ((q2, AutoSt{A.Auto.none(), True{}, manual, st}), True{})))

def Balloon.poll(-R: Type, +a: AutoSt, q: Q.Vq) -> V.Op<R, (Q.Vq & AutoSt) & Bool>:
  match a:
    case AutoSt{+h, k, +manual, st}:
      Balloon.poll.go(R, U32.is_eq(h, A.Auto.none()) || manual, h, k, manual, st, q)
