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

# Only whole 64 KiB blocks inside a reported range are released: a 2 MiB
# block as it is; a range cut at both ends to its inner blocks; a range
# with no whole block, nothing.
law balloon.inside_whole:
  {K.Balloon.inside(U.U64{0, 1075838976}, 2097152) == V.Iov{U.U64{0, 1075838976}, 2097152} : V.Iov}

law balloon.inside_cut:
  {K.Balloon.inside(U.U64{0, 65537}, 196607) == V.Iov{U.U64{0, 131072}, 131072} : V.Iov}

law balloon.inside_none:
  {K.Balloon.len(K.Balloon.inside(U.U64{0, 4096}, 61440)) == 0 : U32}

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

# All 16 pages of a 64 KiB block in: the block is released (block 16 is
# guest address 1 MiB) and no mask is kept; 15 of them: nothing released,
# one mask kept; each page is counted.
law balloon.inflate_whole:
  {inflated(pfns16(16n, 256)) == K.Inflated{K.Bal{0, 16, []}, [V.Iov{U.U64{0, 1048576}, 65536}]} : K.Inflated}

law balloon.inflate_part:
  {inflated(pfns16(15n, 256)) == K.Inflated{K.Bal{0, 15, [K.Part{16, 32767}]}, []} : K.Inflated}

# A deflated page leaves its block's mask and the count.
law balloon.deflate:
  {K.Balloon.deflate([256], K.Bal{0, 2, [K.Part{16, 3}]}) == K.Bal{0, 1, [K.Part{16, 2}]} : K.Bal}

# The target is the config's num_pages; actual follows it.
law balloon.config_of:
  {K.Balloon.config_of(K.Balloon.set_target(K.Bal{0, 3, []}, 262144)) == [0, 0, 4, 0, 3, 0, 0, 0] : +List<U32>}

# Page numbers from a buffer's bytes, little-endian u32s (a short tail is
# dropped).
law balloon.pfns:
  {K.Balloon.pfns(4n, [1, 0, 0, 0, 0, 1, 0, 0, 9]) == [1, 256] : +List<U32>}
