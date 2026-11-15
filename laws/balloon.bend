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
