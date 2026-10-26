import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-entropy (Virtio 1.2 section 5.4), device id 4: one queue, no config,
# no device features beyond VIRTIO_F_VERSION_1. Every buffer the driver
# posts is filled with host entropy.

# Serves every available chain of the request queue: fills its writable
# descriptors with Op.random bytes (as many as they hold), pushes it used with
# that length. At most num chains per call. Answers the queue and whether any
# chain was used.
def Rng.process(-R: Type, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  ?TODO
