import Base
import ../src/lib/u64.bend as U
import ../src/virtio/mmio.bend as M
import ../src/vmm/abi.bend as V
import ../src/virtio/queue.bend as Q

# Frozen spec for the pure parts of src/virtio/queue.bend. Its guest-memory
# behaviour is pinned by tests/virtio_queue.bend, run on the simulator.

law virtio_queue.parse:
  # addr 0x1_0000_4000, len 4, flags NEXT, next 1
  {Q.Desc.parse([0, 64, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 1, 0, 1, 0]) == Q.Desc{U.U64{1, 16384}, 4, 1, 1} : Q.Desc}

law virtio_queue.parse_flags_high_byte:
  {Q.Desc.parse([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 7, 0]) == Q.Desc{U.U64{0, 0}, 0, 258, 7} : Q.Desc}

law virtio_queue.from_cfg:
  {Q.Vq.from_cfg(M.QueueCfg{256, 4, True{}, U.U64{0, 4096}, U.U64{0, 8192}, U.U64{0, 12288}}) == Q.Vq{4, U.U64{0, 4096}, U.U64{0, 8192}, U.U64{0, 12288}, 0, 0} : Q.Vq}

# Proposed: the memory a device moves on the host (Vq.segs) is the chain's
# own, after the header, cut at the room it may use.
law virtio_queue.segs_skip_header_desc:
  {Q.Vq.segs([Q.Desc{U.U64{0, 100}, 16, 1, 1}, Q.Desc{U.U64{0, 200}, 512, 1, 0}], 16, 4294967295) == [V.Iov{U.U64{0, 200}, 512}] : +List<V.Iov>}

law virtio_queue.segs_skip_inside_desc:
  {Q.Vq.segs([Q.Desc{U.U64{0, 100}, 528, 1, 0}], 16, 4294967295) == [V.Iov{U.U64{0, 116}, 512}] : +List<V.Iov>}

law virtio_queue.segs_cut_at_max:
  {Q.Vq.segs([Q.Desc{U.U64{0, 100}, 300, 2, 1}, Q.Desc{U.U64{0, 500}, 300, 2, 0}], 0, 400) == [V.Iov{U.U64{0, 100}, 300}, V.Iov{U.U64{0, 500}, 100}] : +List<V.Iov>}

law virtio_queue.segs_nothing_past_max:
  {Q.Vq.segs([Q.Desc{U.U64{0, 100}, 300, 2, 1}, Q.Desc{U.U64{0, 500}, 300, 2, 0}], 0, 300) == [V.Iov{U.U64{0, 100}, 300}] : +List<V.Iov>}
