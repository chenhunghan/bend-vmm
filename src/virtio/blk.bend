import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-blk (Virtio 1.2 section 5.2), device id 2, one request queue. The
# backing store is a host disk image reached through Op.disk_read and
# Op.disk_write. Offered features: VIRTIO_F_VERSION_1 only (so no FLUSH, no
# read-only, no multi-queue). Config space: capacity, a little-endian u64
# count of 512-byte sectors.
#
# A request is one chain: a 16-byte readable header {type u32, reserved u32,
# sector u64}, data descriptors, and a final 1-byte writable status.
#   type 0 IN:     read len bytes at sector*512 into the writable data
#                  descriptors; len = total writable length - 1
#   type 1 OUT:    write the readable data after the header at sector*512
#   type 8 GET_ID: write the id string (Blk.id(), NUL-padded to 20 bytes) into
#                  the writable data descriptors
#   other types:   status UNSUPP
# Status: 0 OK, 1 IOERR (the access ends past capacity*512, or the chain has no
# writable status byte to answer in), 2 UNSUPP. The used length is the number
# of bytes written into the chain, status byte included.

def Blk.id() -> String:
  "bend-vmm-disk"

def Blk.config(sectors: U.U64) -> +List<U32>:
  B.Bytes.le64(sectors)

# Serves every available request of the queue (at most num per call).
# Answers the queue and whether any chain was used.
def Blk.process(-R: Type, disk: U32, sectors: U.U64, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  ?TODO
