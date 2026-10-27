import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The qcow2 image format (QEMU's docs/interop/qcow2.txt), as far as a block
# device needs it: the header, the two-level cluster map and its entries,
# and where a cluster's 16-bit reference count lives. All big-endian.
#
# Header (byte offsets): 0 magic "QFI\xfb", 4 version (2 or 3), 8 backing
# file name offset (u64), 16 its length (u32), 20 cluster_bits, 24 virtual
# size (u64), 32 encryption method, 36 L1 entries, 40 L1 offset (u64), 48
# refcount table offset (u64), 56 refcount table clusters, 60 snapshots;
# version 3 adds 72 incompatible features (u64), 96 refcount_order, 100
# header length and, past 104, the compression type.
#
# A guest offset splits into an L1 index (the bits above cluster_bits +
# cluster_bits - 3), an L2 index (the next cluster_bits - 3 bits) and the
# offset inside its cluster. L1 and L2 entries hold a host offset in bits
# 9..55; bit 63 (COPIED) says its reference count is exactly 1, so it may be
# written in place. An L2 entry with bit 62 set is a compressed cluster
# (raw deflate): its host offset in the low 62 - (cluster_bits - 8) bits,
# then the count of 512-byte sectors it spans, less one. Bit 0 of a version 3
# entry reads the cluster as zeros.

type Qcow is Data:
  Qcow{bits: U32, size: U.U64, l1: U.U64, l1_size: U32, rt: U.U64, rt_clusters: U32, refbits: U32}

# What an L2 entry says about a cluster.
type Entry is Data:
  # Not in this image: read the backing file (or zeros).
  Unalloc{}
  # Reads as zeros.
  Zeroed{}
  # At host offset off; copied: its reference count is 1.
  Mapped{off: U.U64, copied: Bool}
  # Compressed: clen bytes of raw deflate at host offset off.
  Packed{off: U.U64, clen: U32}

# "QFI\xfb" read big-endian.
def Qcow.magic() -> U32:
  1363560955

def Qcow.be64(+bs: +List<U32>, +at: Nat) -> U.U64:
  U.U64{B.Bytes.read_be32(List.drop(&2, U32, bs, at)), B.Bytes.read_be32(List.drop(&2, U32, bs, Nat.add(at, 4n)))}

def Qcow.be32(+bs: +List<U32>, +at: Nat) -> U32:
  B.Bytes.read_be32(List.drop(&2, U32, bs, at))

# The feature bits a version 3 header may set: dirty (bit 0) and the
# compression type (bit 3, which must then be zlib, type 0). Corrupt
# images, external data files and extended L2 entries are refused.
def Qcow.features_ok(+version: U32, +bs: +List<U32>) -> Bool:
  +inc = Qcow.be64(bs, 72n)
  +hlen = Qcow.be32(bs, 100n)
  +ztype = Bool.pick(U32, U32.is_lt(104, hlen), Maybe.default(&2, U32, List.get(&2, U32, bs, 104n), 0), 0)
  U32.is_eq(version, 2) || (U32.is_zero(U.U64.hi(inc)) && U32.is_zero((U.U64.lo(inc) .&. 4294967286 : U32)) && U32.is_zero(ztype))

# The header of bs (its first 112 bytes or more), if a qcow2 image this
# device can use: version 2 or 3, clusters of 512 bytes to 2 MiB, no
# encryption.
def Qcow.parse(+bs: +List<U32>) -> Maybe<&2, Qcow>:
  +version = Qcow.be32(bs, 4n)
  +bits = Qcow.be32(bs, 20n)
  +refbits = Bool.pick(U32, U32.is_eq(version, 2), 16, (1 << U32.to_nat(U32.min(Qcow.be32(bs, 96n), 6)) : U32))
  +ok = Nat.is_le(112n, List.length(&2, U32, bs)) && U32.is_eq(Qcow.be32(bs, 0n), Qcow.magic()) && (U32.is_eq(version, 2) || U32.is_eq(version, 3)) && U32.is_le(9, bits) && U32.is_le(bits, 21) && U32.is_zero(Qcow.be32(bs, 32n)) && Qcow.features_ok(version, bs)
  Bool.pick(Maybe<&2, Qcow>, ok, Some{Qcow{bits, Qcow.be64(bs, 24n), Qcow.be64(bs, 40n), Qcow.be32(bs, 36n), Qcow.be64(bs, 48n), Qcow.be32(bs, 56n), refbits}}, None{})

# The backing file name's offset and length (length 0: none).
def Qcow.backing(+bs: +List<U32>) -> U.U64 & U32:
  (Qcow.be64(bs, 8n), Qcow.be32(bs, 16n))

def Qcow.bits(q: Qcow) -> U32:
  match q:
    case Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      bits

def Qcow.size(q: Qcow) -> U.U64:
  match q:
    case Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      size

def Qcow.csize(q: Qcow) -> U32:
  (1 << U32.to_nat(Qcow.bits(q)) : U32)

# The offset of off inside its cluster.
def Qcow.inner(+q: Qcow, off: U.U64) -> U32:
  (U.U64.lo(off) .&. (Qcow.csize(q) - 1 : U32) : U32)

# off's index in the L1 table (saturating past 2^32 entries).
def Qcow.l1_index(+q: Qcow, off: U.U64) -> U32:
  +bits = Qcow.bits(q)
  +i = U.U64.shr(U32.to_nat((bits + (bits - 3 : U32) : U32)), off)
  Bool.pick(U32, U32.is_zero(U.U64.hi(i)), U.U64.lo(i), 4294967295)

# off's index in its L2 table.
def Qcow.l2_index(+q: Qcow, off: U.U64) -> U32:
  +bits = Qcow.bits(q)
  (U.U64.lo(U.U64.shr(U32.to_nat(bits), off)) .&. ((1 << U32.to_nat((bits - 3 : U32))) - 1 : U32) : U32)

# The host offset in an L1 or L2 entry (bits 9..55).
def Qcow.entry_off(e: U.U64) -> U.U64:
  U.U64.and(e, U.U64{16777215, 4294966784})

# What an L2 entry says (bit 62 compressed, bit 0 zeros, bit 63 COPIED).
def Qcow.decode(+q: Qcow, +e: U.U64) -> Entry:
  +hi = U.U64.hi(e)
  +packed = Bool.not(U32.is_zero((hi .&. 1073741824 : U32)))
  +x = (62 - (Qcow.bits(q) - 8 : U32) : U32)
  +poff = U.U64.and(e, U.U64.sub(U.U64.shl(U32.to_nat(x), U.U64.from_u32(1)), U.U64.from_u32(1)))
  +sectors = (U.U64.lo(U.U64.shr(U32.to_nat(x), e)) .&. ((1 << U32.to_nat((Qcow.bits(q) - 8 : U32))) - 1 : U32) : U32)
  +clen = ((sectors + 1 : U32) * 512 - (U.U64.lo(poff) .&. 511 : U32) : U32)
  +off = Qcow.entry_off(e)
  +zero = Bool.not(U32.is_zero((U.U64.lo(e) .&. 1 : U32)))
  Bool.pick(Entry, packed, Packed{poff, clen},
    Bool.pick(Entry, zero, Zeroed{},
      Bool.pick(Entry, U.U64.is_zero(off), Unalloc{}, Mapped{off, Bool.not(U32.is_zero((hi .&. 2147483648 : U32)))})))

# An L1 or L2 entry for a cluster at off whose reference count is 1.
def Qcow.copied(off: U.U64) -> U.U64:
  U.U64.or(off, U.U64{2147483648, 0})

# The refcount table's entries.
def Qcow.rt_entries(+q: Qcow) -> U32:
  match q:
    case Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      (rtc * (Qcow.csize(q) / 8 : U32) : U32)

# The refcount table index for the cluster at host offset h.
def Qcow.ref_rti(+q: Qcow, h: U.U64) -> U32:
  +bits = Qcow.bits(q)
  U.U64.lo(U.U64.shr(U32.to_nat((bits - 1 : U32)), U.U64.shr(U32.to_nat(bits), h)))

# The slot of the cluster at host offset h in its refcount block.
def Qcow.ref_slot(+q: Qcow, h: U.U64) -> U32:
  +bits = Qcow.bits(q)
  (U.U64.lo(U.U64.shr(U32.to_nat(bits), h)) .&. ((1 << U32.to_nat((bits - 1 : U32))) - 1 : U32) : U32)
