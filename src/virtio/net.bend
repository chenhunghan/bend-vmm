import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-net (Virtio 1.2 section 5.1), device id 1. Offered features:
# VIRTIO_F_VERSION_1 (bit 32) and VIRTIO_NET_F_MAC (bit 5); so the config
# space is the 6-byte MAC (Net.config). Queue 0 is receiveq1 (host to
# guest), queue 1 transmitq1 (guest to host).
#
# Every buffer starts with the 12-byte virtio_net_hdr (VERSION_1 layout):
# flags u8, gso_type u8, hdr_len u16, gso_size u16, csum_start u16,
# csum_offset u16, num_buffers u16. Transmit strips it; receive writes it as
# all zeros except num_buffers = 1, then the frame.

type NetTx is Data:
  NetTx{q: Q.Vq, frames: +List<+List<U32>>, used: Bool}

type NetRx is Data:
  NetRx{q: Q.Vq, left: +List<+List<U32>>, used: Bool}

def Net.config(mac: +List<U32>) -> +List<U32>:
  mac

# Takes every available chain of transmitq1 (at most num): its readable
# bytes minus the 12-byte header form one frame (a chain of 12 bytes or less
# gives no frame), pushed used with length 0. Answers the queue, the frames
# in order, and whether any chain was used.
def Net.tx(-R: Type, q: Q.Vq) -> V.Op<R, NetTx>:
  ?TODO

# Delivers frames into receiveq1, one frame per available chain, in order:
# header then frame, scattered over the chain's writable descriptors, pushed
# used with 12 + frame length. A frame larger than the chain's room is
# dropped and the chain is kept for the next frame. Stops when frames or
# chains run out.
# Answers the queue, the frames not delivered, and whether any chain was used.
def Net.rx(-R: Type, q: Q.Vq, frames: +List<+List<U32>>) -> V.Op<R, NetRx>:
  ?TODO
