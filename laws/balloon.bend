import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/virtio/queue.bend as Q
import ../src/virtio/balloon.bend as K

# Spec for src/virtio/balloon.bend: virtio-balloon with free page reporting.

# VERSION_1 and FREE_PAGE_REPORTING (bit 5); three queues, reporting is 2;
# num_pages and actual, both 0.
law balloon.features:
  {K.Balloon.features() == U.U64{1, 32} : U.U64}

law balloon.report_queue:
  {K.Balloon.report_queue() == 2 : U32}

law balloon.config:
  {K.Balloon.config() == [0, 0, 0, 0, 0, 0, 0, 0] : +List<U32>}

# Only whole 16 KiB blocks inside a reported range are released: a 2 MiB
# block as it is; a range cut at both ends to its inner blocks; a range
# with no whole block, nothing.
law balloon.inside_whole:
  {K.Balloon.inside(U.U64{0, 1075838976}, 2097152) == V.Iov{U.U64{0, 1075838976}, 2097152} : V.Iov}

law balloon.inside_cut:
  {K.Balloon.inside(U.U64{0, 65537}, 196607) == V.Iov{U.U64{0, 81920}, 180224} : V.Iov}

law balloon.inside_none:
  {K.Balloon.len(K.Balloon.inside(U.U64{0, 4096}, 8192)) == 0 : U32}

# A buffer's ranges: every descriptor's blocks, the empty ones dropped.
law balloon.ranges:
  {K.Balloon.ranges([Q.Desc{U.U64{0, 131072}, 65536, 2, 0}, Q.Desc{U.U64{0, 4096}, 100, 2, 0}]) == [V.Iov{U.U64{0, 131072}, 65536}] : +List<V.Iov>}

# Inflate and deflate. DEFLATE_ON_OOM (bit 2) is offered too.
law balloon.offered:
  {K.Balloon.offered() == U.U64{1, 36} : U.U64}

def pfns16(n: Nat, +base: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+(+k):
      Con{(base + U32.from_nat(k) : U32), pfns16(k, base)}

def inflated(+pfns: +List<U32>) -> K.Inflated:
  K.Balloon.inflate(pfns, K.Inflated{K.Balloon.new(), []})

# 16 KiB blocks (approved 2026-11-15; were 64 KiB): pages 256..271 fill
# blocks 64..67 (block 64 is guest address 1 MiB), each released as it is
# whole, no mask kept; pages 256..270 release blocks 64..66 and keep block
# 67's mask of 3 pages; each page is counted.
law balloon.inflate_whole:
  {inflated(pfns16(16n, 256)) == K.Inflated{K.Bal{0, 16, []}, [V.Iov{U.U64{0, 1048576}, 16384}, V.Iov{U.U64{0, 1064960}, 16384}, V.Iov{U.U64{0, 1081344}, 16384}, V.Iov{U.U64{0, 1097728}, 16384}]} : K.Inflated}

law balloon.inflate_part:
  {inflated(pfns16(15n, 256)) == K.Inflated{K.Bal{0, 15, [K.Part{67, 7}]}, [V.Iov{U.U64{0, 1048576}, 16384}, V.Iov{U.U64{0, 1064960}, 16384}, V.Iov{U.U64{0, 1081344}, 16384}]} : K.Inflated}

# A deflated page leaves its block's mask and the count.
law balloon.deflate:
  {K.Balloon.deflate([256], K.Bal{0, 2, [K.Part{64, 3}]}) == K.Bal{0, 1, [K.Part{64, 2}]} : K.Bal}

# The target is the config's num_pages; actual follows it.
law balloon.config_of:
  {K.Balloon.config_of(K.Balloon.set_target(K.Bal{0, 3, []}, 262144)) == [0, 0, 4, 0, 3, 0, 0, 0] : +List<U32>}

# Page numbers from a buffer's bytes, little-endian u32s (a short tail is
# dropped).
law balloon.pfns:
  {K.Balloon.pfns(4n, [1, 0, 0, 0, 0, 1, 0, 0, 9]) == [1, 256] : +List<U32>}

# Proposed: a snapshot's 64 KiB masks (older ones) as 16 KiB ones: block 16
# with pages 0, 1 and 4..7 in is block 64 with 0 and 1, block 65 whole.
law balloon.parts16:
  {K.Balloon.parts16([K.Part{16, 243}]) == [K.Part{64, 3}, K.Part{65, 15}] : +List<K.Part>}
