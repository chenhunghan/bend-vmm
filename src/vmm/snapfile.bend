import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The snapshot file's layout. The host writes and reads byte ranges where
# this module says; every offset, length prefix and bound of the format is
# decided here (laws/snapfile.bend).
#
#   0   "BVMSNAP1"
#   8   version u32 (the host's hypervisor: 1 Hypervisor.framework, 2 KVM)
#   12  vCPUs u32
#   16  RAM base u64
#   24  RAM size u64
#   32  argv length u64, then argv (NUL-separated)
#   ..  machine word count u64, then the words (u32 each, src/vmm/snapshot.bend)
#   ..  GIC state length u64, then its bytes
#   ..  per vCPU: register blob length u64 (0: none), then the blob
#   RAM at the next 16 KiB boundary, to the end of the file
#
# A loader takes at most 64 vCPUs, 1 MiB of argv, 2^26 machine words, a
# 16 MiB GIC state, 1 MiB per vCPU and 1 TiB of RAM (not 0); the writer
# refuses a state past those, rather than write one that cannot be restored.

def Snapf.magic() -> +List<U32>:
  # "BVMSNAP1"
  [66, 86, 77, 83, 78, 65, 80, 49]

def Snapf.max_cpus() -> U32:
  64

def Snapf.max_args() -> U.U64:
  # 2^20
  U.U64{0, 1048576}

def Snapf.max_words() -> U.U64:
  # 2^26
  U.U64{0, 67108864}

def Snapf.max_gic() -> U.U64:
  # 2^24
  U.U64{0, 16777216}

def Snapf.max_cpu() -> U.U64:
  # 2^20
  U.U64{0, 1048576}

def Snapf.max_ram() -> U.U64:
  # 2^40
  U.U64{256, 0}

# The fixed header, 40 bytes.
type Head is Data:
  Head{ver: U32, ncpus: U32, base: U.U64, ram: U.U64, nargs: U.U64}

# A part of the file: its offset and length.
type Part is Data:
  Part{off: U.U64, len: U.U64}

# Where each part lies in the file: argv, the machine words, the GIC state
# and each vCPU's blob as (offset, length), and RAM's offset.
type Layout is Data:
  Layout{head: Head, args: U.U64, words: U.U64, nwords: U.U64, gic: U.U64, ngic: U.U64, cpus: +List<Part>, ram_off: U.U64}

# One write of the plan the host carries out, at a file offset: bytes given
# here, or a part the host holds (the machine words, the GIC state, vCPU i's
# register blob, guest RAM, argv).
type Piece is Data:
  PBytes{off: U.U64, bs: +List<U32>}
  PWords{off: U.U64}
  PGic{off: U.U64}
  PCpu{off: U.U64, i: U32}
  PRam{off: U.U64}
  PArgs{off: U.U64}

# A step of reading a file's layout: read the u64 length at off next, the
# file is bad, or the layout is known.
type Need is Data:
  NRead{off: U.U64}
  NBad{}
  NDone{l: Layout}

# Helpers
# =======

def Snapf.len(-A: Data, +xs: +List<A>) -> U.U64:
  U.U64{0, U32.from_nat(List.length(&2, A, xs))}

# a past b by n bytes and an 8-byte length prefix
def Snapf.after(a: U.U64, n: U.U64) -> U.U64:
  U.U64.add(U.U64.add_u32(a, 8), n)

def Snapf.within(+a: U.U64, +max: U.U64) -> Bool:
  U.U64.is_le(a, max)

def Snapf.cpus_within(cs: +List<U.U64>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Snapf.within(c, Snapf.max_cpu()) && Snapf.cpus_within(rest)

def Snapf.ram_ok(+ram: U.U64) -> Bool:
  Bool.not(U.U64.is_zero(ram)) && Snapf.within(ram, Snapf.max_ram())

# The header's 40 bytes.
def Snapf.head_bytes(h: Head) -> +List<U32>:
  match h:
    case Head{v, n, b, r, a}:
      List.append(&2, U32, Snapf.magic(), List.append(&2, U32, B.Bytes.le32(v), List.append(&2, U32, B.Bytes.le32(n),
        List.append(&2, U32, B.Bytes.le64(b), List.append(&2, U32, B.Bytes.le64(r), B.Bytes.le64(a))))))

# Writing
# =======

def Head.nargs(h: Head) -> U.U64:
  match h:
    case Head{v, n, b, r, a}:
      a

def Head.ncpus(h: Head) -> U32:
  match h:
    case Head{v, n, b, r, a}:
      n

def Snapf.words_at(+h: Head) -> U.U64:
  U.U64.add_u32(Head.nargs(h), 40)

def Snapf.gic_at(+h: Head, +nw: U.U64) -> U.U64:
  U.U64.add(U.U64.add_u32(Snapf.words_at(h), 8), U.U64.shl(2n, nw))


# The vCPU blobs from offset at: each one's length, then the blob; RAM at
# the next 16 KiB boundary after the last.
def Snapf.plan.cpus(cs: +List<U.U64>, +i: U32, +at: U.U64) -> +List<Piece>:
  match cs:
    case Nil{}:
      [PRam{U.U64.align_up(14n, at)}]
    case Con{+c, rest}:
      PBytes{at, B.Bytes.le64(c)} <> PCpu{U.U64.add_u32(at, 8), i} <> Snapf.plan.cpus(rest, (i + 1 : U32), Snapf.after(at, c))

def Snapf.plan.pieces(+h: Head, +nwords: U.U64, +ngic: U.U64, cs: +List<U.U64>) -> +List<Piece>:
  +wat = Snapf.words_at(h)
  +gat = Snapf.gic_at(h, nwords)
  PBytes{U.U64.zero(), Snapf.head_bytes(h)}
    <> PArgs{U.U64{0, 40}}
    <> PBytes{wat, B.Bytes.le64(nwords)}
    <> PWords{U.U64.add_u32(wat, 8)}
    <> PBytes{gat, B.Bytes.le64(ngic)}
    <> PGic{U.U64.add_u32(gat, 8)}
    <> Snapf.plan.cpus(cs, 0, Snapf.after(gat, ngic))

def Snapf.plan.pick(ok: Bool, ps: +List<Piece>) -> Maybe<&2, +List<Piece>>:
  match ok:
    case True{}:
      Some{ps}
    case False{}:
      None{}

# The writes of a snapshot of a VM with this hypervisor version, RAM base
# and size, argv length, machine word count, GIC state length and vCPU blob
# lengths; None when a loader would refuse the file.
def Snapf.plan(ver: U32, base: U.U64, +ram: U.U64, +nargs: U.U64, +nwords: U.U64, +ngic: U.U64, +cs: +List<U.U64>) -> Maybe<&2, +List<Piece>>:
  +n = U32.from_nat(List.length(&2, U.U64, cs))
  +ok = U32.is_le(n, Snapf.max_cpus()) && Snapf.ram_ok(ram) && Snapf.within(nargs, Snapf.max_args())
    && Snapf.within(nwords, Snapf.max_words()) && Snapf.within(ngic, Snapf.max_gic()) && Snapf.cpus_within(cs)
  Snapf.plan.pick(ok, Snapf.plan.pieces(Head{ver, n, base, ram, nargs}, nwords, ngic, cs))

def Snapf.word.got(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      x

def Snapf.word(+ws: +List<U32>, k: Nat) -> U32:
  Snapf.word.got(List.get(&2, U32, ws, k))

def Snapf.u64_at(+ws: +List<U32>, +k: Nat) -> U.U64:
  U.U64{Snapf.word(ws, k), Snapf.word(ws, 1n+k)}

def Snapf.lens(ws: +List<U32>) -> +List<U.U64>:
  match ws:
    case Con{h, Con{l, rest}}:
      U.U64{h, l} <> Snapf.lens(rest)
    case _:
      []

def Snapf.plan_of.pick(ok: Bool, p: Maybe<&2, +List<Piece>>) -> Maybe<&2, +List<Piece>>:
  match ok:
    case True{}:
      p
    case False{}:
      None{}

# The plan for the sizes the host answers (Hvf.snap_save): [version, RAM
# base, RAM size, argv length, word count, GIC length (each hi, lo), vCPUs,
# then each vCPU's blob length (hi, lo)].
def Snapf.plan_of(+ws: +List<U32>) -> Maybe<&2, +List<Piece>>:
  +cs = Snapf.lens(List.drop(&2, U32, ws, 12n))
  +ok = U32.is_eq(U32.from_nat(List.length(&2, U.U64, cs)), Snapf.word(ws, 11n))
  Snapf.plan_of.pick(ok, Snapf.plan(Snapf.word(ws, 0n), Snapf.u64_at(ws, 1n), Snapf.u64_at(ws, 3n), Snapf.u64_at(ws, 5n), Snapf.u64_at(ws, 7n), Snapf.u64_at(ws, 9n), cs))

# Reading
# =======

def Snapf.head.pick(ok: Bool, h: Head) -> Maybe<&2, Head>:
  match ok:
    case True{}:
      Some{h}
    case False{}:
      None{}

def Snapf.magic_is(a: +List<U32>, b: +List<U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Con{x, xs} Con{y, ys}:
      U32.is_eq(x, y) && Snapf.magic_is(xs, ys)
    case _ _:
      False{}

# The first 40 bytes of a snapshot from a host whose version is ver.
def Snapf.head(+ver: U32, +bs: +List<U32>) -> Maybe<&2, Head>:
  +v = B.Bytes.read_le32(List.drop(&2, U32, bs, 8n))
  +n = B.Bytes.read_le32(List.drop(&2, U32, bs, 12n))
  +ram = B.Bytes.read_le64(List.drop(&2, U32, bs, 24n))
  +nargs = B.Bytes.read_le64(List.drop(&2, U32, bs, 32n))
  +ok = U32.is_eq(U32.from_nat(List.length(&2, U32, bs)), 40) && Snapf.magic_is(List.take(&2, U32, bs, 8n), Snapf.magic())
    && U32.is_eq(v, ver) && U32.is_le(n, Snapf.max_cpus()) && Snapf.ram_ok(ram) && Snapf.within(nargs, Snapf.max_args())
  Snapf.head.pick(ok, Head{v, n, B.Bytes.read_le64(List.drop(&2, U32, bs, 16n)), ram, nargs})

# The vCPU blobs: left more to read from at, with lens the lengths read so
# far past the GIC's (each within its bound, or the file is bad).
def Snapf.need.cpus(left: Nat, lens: +List<U.U64>, +h: Head, +nw: U.U64, +ng: U.U64, +at: U.U64, acc: +List<Part>) -> Need:
  match left:
    case 0n:
      match lens:
        case Nil{}:
          +wat = U.U64.add_u32(Head.nargs(h), 48)
          NDone{Layout{h, U.U64{0, 40}, wat, nw, U.U64.add_u32(U.U64.add(wat, U.U64.shl(2n, nw)), 8), ng, acc, U.U64.align_up(14n, at)}}
        case Con{x, rest}:
          NBad{}
    case 1n+p:
      match lens:
        case Nil{}:
          NRead{at}
        case Con{+c, rest}:
          Bool.pick(Need, Snapf.within(c, Snapf.max_cpu()),
            Snapf.need.cpus(p, rest, h, nw, ng, Snapf.after(at, c), List.append(&2, Part, acc, [Part{U.U64.add_u32(at, 8), c}])),
            NBad{})

def Snapf.need.gic(rest: +List<U.U64>, +h: Head, +nw: U.U64) -> Need:
  match rest:
    case Nil{}:
      Bool.pick(Need, Snapf.within(nw, Snapf.max_words()), NRead{Snapf.gic_at(h, nw)}, NBad{})
    case Con{+ng, more}:
      Bool.pick(Need, Snapf.within(nw, Snapf.max_words()) && Snapf.within(ng, Snapf.max_gic()),
        Snapf.need.cpus(U32.to_nat(Head.ncpus(h)), more, h, nw, ng, Snapf.after(Snapf.gic_at(h, nw), ng), []),
        NBad{})

# What to read next, given the header and the length prefixes read so far
# (the machine words', the GIC's, then each vCPU's, in file order).
def Snapf.need(+h: Head, lens: +List<U.U64>) -> Need:
  match lens:
    case Nil{}:
      NRead{Snapf.words_at(h)}
    case Con{nw, rest}:
      Snapf.need.gic(rest, h, nw)

# The file holds all of RAM (it is mapped from the file: a short one would
# fault on the first touch past its end).
def Snapf.fits(l: Layout, +size: U.U64) -> Bool:
  match l:
    case Layout{Head{v, n, b, r, a}, ao, wo, nw, go, ng, cs, ro}:
      U.U64.is_le(U.U64.add(ro, r), size)

# Wire forms for the host
# =======================

def Snapf.w64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      [h, l]

# A piece for the host: [kind, offset hi, lo, ...]: 0 bytes (count, then
# the bytes), 1 the machine words, 2 the GIC state, 3 vCPU i's blob (i),
# 4 guest RAM, 5 argv.
def Snapf.piece.wire(p: Piece) -> +List<U32>:
  match p:
    case PBytes{o, +bs}:
      0 <> List.append(&2, U32, Snapf.w64(o), U32.from_nat(List.length(&2, U32, bs)) <> bs)
    case PWords{o}:
      1 <> Snapf.w64(o)
    case PGic{o}:
      2 <> Snapf.w64(o)
    case PCpu{o, i}:
      3 <> List.append(&2, U32, Snapf.w64(o), [i])
    case PRam{o}:
      4 <> Snapf.w64(o)
    case PArgs{o}:
      5 <> Snapf.w64(o)

def Snapf.pieces.wire(ps: +List<Piece>) -> +List<U32>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      List.append(&2, U32, Snapf.piece.wire(p), Snapf.pieces.wire(rest))

# The host's load: [RAM base, RAM size, RAM offset, argv offset, argv
# length, words offset, words length in bytes, GIC offset, GIC length (each hi, lo),
# vCPUs, then per vCPU offset and length].
def Snapf.cpus.wire(cs: +List<Part>) -> +List<U32>:
  match cs:
    case Nil{}:
      []
    case Con{Part{o, n}, rest}:
      List.append(&2, U32, Snapf.w64(o), List.append(&2, U32, Snapf.w64(n), Snapf.cpus.wire(rest)))

def Snapf.load.wire(l: Layout) -> +List<U32>:
  match l:
    case Layout{Head{v, n, b, r, a}, ao, wo, nw, go, ng, +cs, ro}:
      List.concat(&2, U32, [Snapf.w64(b), Snapf.w64(r), Snapf.w64(ro), Snapf.w64(ao), Snapf.w64(a), Snapf.w64(wo), Snapf.w64(U.U64.shl(2n, nw)), Snapf.w64(go), Snapf.w64(ng), [U32.from_nat(List.length(&2, Part, cs))], Snapf.cpus.wire(cs)])
