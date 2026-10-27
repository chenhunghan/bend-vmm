import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/disk/qcow2.bend as Q

# Spec for src/disk/qcow2.bend. The version 3 header qemu-img 11 writes for
# a 1 GiB image: 64 KiB clusters, its L1 table at 196608 (2 entries), its
# refcount table at 65536 (1 cluster), 16-bit counts.
def header() -> +List<U32>:
  [81, 70, 73, 251, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 112, 0, 0, 0, 0, 0, 0, 0, 0]

def q() -> Q.Qcow:
  Q.Qcow{16, U.U64{0, 1073741824}, U.U64{0, 196608}, 2, U.U64{0, 65536}, 1, 16}

law qcow2.parse:
  {Q.Qcow.parse(header()) == Some{q()} : Maybe<&2, Q.Qcow>}

law qcow2.parse_bad_magic:
  {Q.Qcow.parse(List.set(&2, U32, header(), 0n, 82)) == None{} : Maybe<&2, Q.Qcow>}

law qcow2.parse_encrypted:
  {Q.Qcow.parse(List.set(&2, U32, header(), 35n, 1)) == None{} : Maybe<&2, Q.Qcow>}

law qcow2.parse_corrupt:
  # incompatible feature bit 1: corrupt
  {Q.Qcow.parse(List.set(&2, U32, header(), 79n, 2)) == None{} : Maybe<&2, Q.Qcow>}

law qcow2.parse_dirty_ok:
  {Q.Qcow.parse(List.set(&2, U32, header(), 79n, 1)) == Some{q()} : Maybe<&2, Q.Qcow>}

# Guest offset 0x2_3456_789A: cluster 0x2_3456, so L1 index 0x2_3456 >> 13
# = 17 and L2 index 0x2_3456 & 0x1FFF = 5206; 0x789A = 30874 bytes into it.
law qcow2.l1_index:
  {Q.Qcow.l1_index(q(), U.U64{2, 878082202}) == 17 : U32}

law qcow2.l2_index:
  {Q.Qcow.l2_index(q(), U.U64{2, 878082202}) == 5206 : U32}

law qcow2.inner:
  {Q.Qcow.inner(q(), U.U64{2, 878082202}) == 30874 : U32}

law qcow2.decode_unalloc:
  {Q.Qcow.decode(q(), U.U64{0, 0}) == Q.Unalloc{} : Q.Entry}

law qcow2.decode_copied:
  {Q.Qcow.decode(q(), U.U64{2147483648, 327680}) == Q.Mapped{U.U64{0, 327680}, True{}} : Q.Entry}

law qcow2.decode_shared:
  {Q.Qcow.decode(q(), U.U64{0, 327680}) == Q.Mapped{U.U64{0, 327680}, False{}} : Q.Entry}

law qcow2.decode_zero:
  {Q.Qcow.decode(q(), U.U64{0, 1}) == Q.Zeroed{} : Q.Entry}

# Compressed, 64 KiB clusters: offset in bits 0..53, sectors - 1 above: 3
# sectors from 0x50200 (the offset 512-aligned, so 3 * 512 bytes).
law qcow2.decode_packed:
  {Q.Qcow.decode(q(), U.U64{1082130432, 328192}) == Q.Packed{U.U64{0, 328192}, 1536} : Q.Entry}

law qcow2.copied_flag:
  {Q.Qcow.copied(U.U64{0, 327680}) == U.U64{2147483648, 327680} : U.U64}

# The count of cluster 70000 (host offset 70000 * 65536): refcount block 2
# (32768 counts each), slot 4464.
law qcow2.ref_rti:
  {Q.Qcow.ref_rti(q(), U.U64{1, 292552704}) == 2 : U32}

law qcow2.ref_slot:
  {Q.Qcow.ref_slot(q(), U.U64{1, 292552704}) == 4464 : U32}
