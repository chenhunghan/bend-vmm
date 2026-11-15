import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The free space of an ext4 file system in a disk image, for
# `bend-vmm sparsify` (laws/ext4free.bend): the host reads the bytes this
# module asks for (the partition table, the superblock, the group
# descriptors, each group's block bitmap) and punches holes where it says.
# Only with the VM stopped (the host holds the image's exclusive lock): a
# running guest's cache can be newer than the disk.
#
# Partitions: the whole disk, or the entries of an MBR (signature 0x55AA at
# 510; type at 4, first sector at 8, count at 12 of each 16-byte entry at
# 446) or a GPT (protective MBR type 0xEE; header at sector 1: entries'
# sector at 72, count at 80, size at 84; an entry's first sector at 32,
# last at 40, zero type GUID unused).
#
# ext4 (little-endian; superblock 1024 bytes into the file system): blocks
# count 4 (and 336 with 64BIT), first data block 20, log block size 24
# (1024 << n), blocks per group 32, magic 56 (0xEF53), state 58 (bit 0
# cleanly unmounted, bit 1 errors), incompatible features 96 (RECOVER 0x4:
# the journal needs replaying; META_BG 0x10: descriptors elsewhere; 64BIT
# 0x80: descriptor size at 254). Group descriptors start at the block after
# the first data block's; each has its block bitmap at 0 (high half at 32
# with 64BIT) and flags at 18 (BLOCK_UNINIT 0x2: no bitmap yet, the group
# is skipped). A clear bit in a group's bitmap is a free block.
#
# A file system not cleanly unmounted, with errors, needing recovery or
# with META_BG is left alone (Ext.Fs.ok). Offsets are bytes into the image.

type Fs is Data:
  Fs{base: U.U64, log: U32, blocks: U32, first: U32, per_group: U32, groups: U32, dsize: U32, ok: Bool}

def Ext.magic() -> U32:
  # 0xEF53
  61267

def Ext.le16(+bs: +List<U32>, +at: Nat) -> U32:
  B.Bytes.read_le(2n, List.drop(&2, U32, bs, at))

def Ext.le32(+bs: +List<U32>, +at: Nat) -> U32:
  B.Bytes.read_le32(List.drop(&2, U32, bs, at))

# Whether 1024 superblock bytes are ext4's.
def Ext.is_ext(+sb: +List<U32>) -> Bool:
  Nat.is_le(1024n, List.length(&2, U32, sb)) && U32.is_eq(Ext.le16(sb, 56n), Ext.magic())

# The file system whose superblock (its 1024 bytes) lies at base + 1024.
# Blocks are counted in 32 bits (16 TiB with 4 KiB blocks): a larger one is
# left alone.
def Ext.fs(+base: U.U64, +sb: +List<U32>) -> Fs:
  +incompat = Ext.le32(sb, 96n)
  +wide = Bool.not(U32.is_zero((incompat .&. 128 : U32)))
  +blocks = Ext.le32(sb, 4n)
  +hi = Bool.pick(U32, wide, Ext.le32(sb, 336n), 0)
  +log = Ext.le32(sb, 24n)
  +per = Ext.le32(sb, 32n)
  +first = Ext.le32(sb, 20n)
  +state = Ext.le16(sb, 58n)
  +dsize = Bool.pick(U32, wide, U32.max(32, Ext.le16(sb, 254n)), 32)
  +ok = Ext.is_ext(sb) && U32.is_le(log, 6) && Bool.not(U32.is_zero(per)) && U32.is_zero(hi) && U32.is_lt(first, blocks)
    && U32.is_eq((state .&. 3 : U32), 1) && U32.is_zero((incompat .&. 20 : U32)) && U32.is_le(dsize, 1024)
  +span = (blocks - first : U32)
  +groups = Bool.pick(U32, U32.is_zero(per), 0, ((span / per : U32) + Bool.pick(U32, U32.is_zero((span % per : U32)), 0, 1) : U32))
  Fs{base, log, blocks, first, per, groups, dsize, ok}

def Fs.ok(f: Fs) -> Bool:
  match f:
    case Fs{b, l, n, fi, p, g, d, ok}:
      ok

def Fs.groups(f: Fs) -> U32:
  match f:
    case Fs{b, l, n, fi, p, g, d, ok}:
      g

def Fs.bsize(f: Fs) -> U32:
  match f:
    case Fs{b, l, n, fi, p, g, d, ok}:
      (1024 << U32.to_nat(l) : U32)

def Fs.dsize(f: Fs) -> U32:
  match f:
    case Fs{b, l, n, fi, p, g, d, ok}:
      d

# The byte offset of block n.
def Fs.block_at(f: Fs, +n: U32) -> U.U64:
  match f:
    case Fs{+b, +l, nb, fi, p, g, d, ok}:
      U.U64.add(b, U.U64.shl(U32.to_nat((l + 10 : U32)), U.U64.from_u32(n)))

# Where the group descriptors start, and their bytes for every group.
def Fs.descs_at(+f: Fs) -> U.U64:
  match f:
    case Fs{b, l, n, +fi, p, g, d, ok}:
      Fs.block_at(f, (fi + 1 : U32))

def Fs.descs_len(+f: Fs) -> U32:
  (Fs.groups(f) * Fs.dsize(f) : U32)

# Group g's block bitmap block, or none (BLOCK_UNINIT, or a bitmap block
# past the end), from the descriptors' bytes.
def Fs.bitmap(+f: Fs, +ds: +List<U32>, +g: U32) -> Maybe<&2, U32>:
  match f:
    case Fs{b, l, +n, fi, p, gs, +d, ok}:
      +at = U32.to_nat((g * d : U32))
      +lo = Ext.le32(ds, at)
      +hi = Bool.pick(U32, U32.is_le(64, d), Ext.le32(ds, Nat.add(at, 32n)), 0)
      +flags = Ext.le16(ds, Nat.add(at, 18n))
      Bool.pick(Maybe<&2, U32>, U32.is_zero((flags .&. 2 : U32)) && U32.is_zero(hi) && U32.is_lt(lo, n) && Bool.not(U32.is_zero(lo)),
        Some{lo}, None{})

# A run of free blocks: the first block and how many.
type Run is Data:
  Run{start: U32, len: U32}

def Ext.runs.close(+first: U32, +i: U32, cur: Maybe<&2, U32>, +acc: +List<Run>) -> +List<Run>:
  match cur:
    case None{}:
      acc
    case Some{+s}:
      Con{Run{(first + s : U32), (i - s : U32)}, acc}

# The runs of clear bits among the first n of a bitmap, newest first; block
# numbers from first. One pass over the bytes, a bit at a time (fuel: bits
# and bytes); each call is handed what the next step needs to know (a byte
# to take, the end reached, bit i set), as a def may only match its
# parameters, in order.
def Ext.walk(
  fuel: Nat, done: Bool, refill: Bool, used: Bool, bs: +List<U32>, +b: U32, +k: U32, +i: U32, +n: U32, +first: U32, +cur: Maybe<&2, U32>, +acc: +List<Run>
) -> +List<Run>:
  match fuel:
    case 0n:
      Ext.runs.close(first, i, cur, acc)
    case 1n+f:
      match done:
        case True{}:
          Ext.runs.close(first, i, cur, acc)
        case False{}:
          match refill:
            case True{}:
              match bs:
                case Nil{}:
                  Ext.runs.close(first, i, cur, acc)
                case Con{+c, rest}:
                  Ext.walk(f, U32.is_le(n, i), False{}, U32.is_eq((c .&. 1 : U32), 1), rest, c, 8, i, n, first, cur, acc)
            case False{}:
              match used:
                case True{}:
                  +k2 = (k - 1 : U32)
                  +b2 = (b >> 1n : U32)
                  +i2 = (i + 1 : U32)
                  Ext.walk(f, U32.is_le(n, i2), U32.is_zero(k2), U32.is_eq((b2 .&. 1 : U32), 1), bs, b2, k2, i2, n, first, None{}, Ext.runs.close(first, i, cur, acc))
                case False{}:
                  +k2 = (k - 1 : U32)
                  +b2 = (b >> 1n : U32)
                  +i2 = (i + 1 : U32)
                  Ext.walk(f, U32.is_le(n, i2), U32.is_zero(k2), U32.is_eq((b2 .&. 1 : U32), 1), bs, b2, k2, i2, n, first, Some{Maybe.default(&2, U32, cur, i)}, acc)

def Ext.runs(+bs: +List<U32>, +n: U32, +first: U32) -> +List<Run>:
  Ext.walk(U32.to_nat(((n + (n / 8 : U32) : U32) + 4 : U32)), U32.is_zero(n), True{}, False{}, bs, 0, 0, 0, n, first, None{}, [])

# The free runs of group g, its bitmap's bytes read.
def Fs.free_runs(+f: Fs, +g: U32, +bs: +List<U32>) -> +List<Run>:
  match f:
    case Fs{b, l, +nb, +fi, +p, gs, d, ok}:
      +first = ((g * p : U32) + fi : U32)
      +left = (nb - first : U32)
      +n = U32.min(left, p)
      Ext.runs(bs, n, first)

def Fs.log(f: Fs) -> U32:
  match f:
    case Fs{b, l, n, fi, p, g, d, ok}:
      l

# A run as a byte range of the image: the whole 4 KiB blocks inside it (a
# host punches holes in those; with 1 KiB file system blocks a run's ends
# may cut one), as offset and length (0: none).
def Fs.range(+f: Fs, r: Run) -> U.U64 & U.U64:
  match r:
    case Run{+st, +n}:
      +off = Fs.block_at(f, st)
      +end = U.U64.add(off, U.U64.shl(U32.to_nat((Fs.log(f) + 10 : U32)), U.U64.from_u32(n)))
      +a = U.U64.align_up(12n, off)
      +e = U.U64.and(end, U.U64.not(U.U64{0, 4095}))
      (a, Bool.pick(U.U64, U.U64.is_lt(a, e), U.U64.sub(e, a), U.U64.zero()))

# Partitions
# ==========

# The byte offsets of the partitions an MBR lists (type 0: none), from the
# first sector's bytes.
def Part.mbr.go(fuel: Nat, +bs: +List<U32>, +i: U32) -> +List<U.U64>:
  match fuel:
    case 0n:
      []
    case 1n+f:
      +at = Nat.add(446n, U32.to_nat((i * 16 : U32)))
      +ty = Maybe.default(&2, U32, List.get(&2, U32, bs, Nat.add(at, 4n)), 0)
      +lba = Ext.le32(bs, Nat.add(at, 8n))
      +more = Part.mbr.go(f, bs, (i + 1 : U32))
      Bool.pick(+List<U.U64>, U32.is_zero(ty) || U32.is_zero(lba), more, Con{U.U64.shl(9n, U.U64.from_u32(lba)), more})

def Part.signed(+bs: +List<U32>) -> Bool:
  U32.is_eq(Ext.le16(bs, 510n), 43605)

# Whether the first sector is a GPT's protective MBR (type 0xEE).
def Part.gpt(+bs: +List<U32>) -> Bool:
  Part.signed(bs) && U32.is_eq(Maybe.default(&2, U32, List.get(&2, U32, bs, 450n), 0), 238)

def Part.mbr(+bs: +List<U32>) -> +List<U.U64>:
  Bool.pick(+List<U.U64>, Part.signed(bs) && Bool.not(Part.gpt(bs)), Part.mbr.go(4n, bs, 0), [])

# A GPT header's entries: their offset, count (at most 128) and entry size.
type GptTab is Data:
  GptTab{at: U.U64, n: U32, size: U32}

def Part.gpt_table(+hdr: +List<U32>) -> GptTab:
  GptTab{U.U64.shl(9n, B.Bytes.read_le64(List.drop(&2, U32, hdr, 72n))), U32.min(Ext.le32(hdr, 80n), 128), U32.max(128, U32.min(Ext.le32(hdr, 84n), 512))}

# The byte offsets of the partitions in a GPT's entries (zero type: unused).
def Part.gpt_entries.go(fuel: Nat, +es: +List<U32>, +i: U32, +n: U32, +size: U32) -> +List<U.U64>:
  match fuel:
    case 0n:
      []
    case 1n+f:
      +at = U32.to_nat((i * size : U32))
      +used = Bool.not(U.U64.is_zero(B.Bytes.read_le64(List.drop(&2, U32, es, at)))) || Bool.not(U.U64.is_zero(B.Bytes.read_le64(List.drop(&2, U32, es, Nat.add(at, 8n)))))
      +lba = B.Bytes.read_le64(List.drop(&2, U32, es, Nat.add(at, 32n)))
      +more = Bool.pick(+List<U.U64>, U32.is_le(n, (i + 1 : U32)), [], Part.gpt_entries.go(f, es, (i + 1 : U32), n, size))
      Bool.pick(+List<U.U64>, used && Bool.not(U.U64.is_zero(lba)), Con{U.U64.shl(9n, lba), more}, more)

def Part.gpt_entries(+es: +List<U32>, +n: U32, +size: U32) -> +List<U.U64>:
  Bool.pick(+List<U.U64>, U32.is_zero(n), [], Part.gpt_entries.go(128n, es, 0, n, size))
