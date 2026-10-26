import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-console (Virtio 1.2 section 5.3), device id 3, one port, no
# features beyond VIRTIO_F_VERSION_1 (no size, no multiport), so the config
# space is empty. Queue 0 is receiveq0 (host to guest), queue 1 transmitq0
# (guest to host). Linux names the port /dev/hvc0.

# What a transmit pass produced.
type ConTx is Data:
  ConTx{q: Q.Vq, bytes: +List<U32>, used: Bool}

# What a receive pass did with the pending input.
type ConRx is Data:
  ConRx{q: Q.Vq, left: +List<U32>, used: Bool}

# Takes every available chain of transmitq0 (at most num): gathers its
# readable bytes, in chain order, and pushes it used with length 0. Answers
# the queue, all bytes in order, and whether any chain was used.
def Con.tx(-R: Type, q: Q.Vq) -> V.Op<R, ConTx>:
  ?TODO

# Delivers pending input into receiveq0: each available chain (at most num)
# takes as many bytes as its writable descriptors hold, pushed used with that
# length, until the input runs out (an empty input pops nothing). Answers the
# queue, the bytes that did not fit, and whether any chain was used.
def Con.rx(-R: Type, q: Q.Vq, input: +List<U32>) -> V.Op<R, ConRx>:
  ?TODO
