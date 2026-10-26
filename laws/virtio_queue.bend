import Base
import ../src/lib/u64.bend as U
import ../src/virtio/mmio.bend as M
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
