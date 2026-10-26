import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./mmio.bend as M

# The split virtqueue (Virtio 1.2 section 2.7), operating on guest memory
# through Op. Layout, all little-endian:
#   descriptor table: num entries of 16 bytes: addr u64, len u32,
#     flags u16 (NEXT 1, WRITE 2, INDIRECT 4), next u16
#   driver area (available ring): flags u16, idx u16, ring[num] u16
#   device area (used ring): flags u16, idx u16, ring[num] {id u32, len u32}
# idx fields count modulo 65536; ring slots are idx modulo num.
# This VMM never offers VIRTIO_F_INDIRECT_DESC or EVENT_IDX, so a chain is
# a plain NEXT-linked list. A chain is cut after num descriptors (a loop in a
# malformed chain must not hang the VMM).

type Desc is Data:
  Desc{addr: U.U64, len: U32, flags: U32, next: U32}

# A descriptor chain: its head index, then the device-readable descriptors
# and the device-writable ones, each in chain order.
type Chain is Data:
  Chain{head: U32, readable: +List<Desc>, writable: +List<Desc>}

# A queue as the device sees it: size, the three areas, and the next ring
# positions (both modulo 65536).
type Vq is Data:
  Vq{num: U32, desc: U.U64, driver: U.U64, device: U.U64, next_avail: U32, next_used: U32}

def Chain.head(c: Chain) -> U32:
  match c:
    case Chain{h, r, w}:
      h

def Desc.is_eq(a: Desc, b: Desc) -> Bool:
  ?TODO

def Chain.is_eq(a: Chain, b: Chain) -> Bool:
  ?TODO

def Chain.is_eq_maybe(a: Maybe<&2, Chain>, b: Maybe<&2, Chain>) -> Bool:
  ?TODO

def Vq.is_eq(a: Vq, b: Vq) -> Bool:
  ?TODO

def Vq.from_cfg(cfg: M.QueueCfg) -> Vq:
  ?TODO

# Parses one 16-byte descriptor.
def Desc.parse(bs: +List<U32>) -> Desc:
  ?TODO

# Takes the next available chain, if the driver has published one.
def Vq.pop(-R: Type, q: Vq) -> V.Op<R, Vq & Maybe<&2, Chain>>:
  ?TODO

# Returns chain `head` to the driver as used, with `len` bytes written.
def Vq.push(-R: Type, q: Vq, head: U32, len: U32) -> V.Op<R, Vq>:
  ?TODO

# Gathers the bytes of every readable descriptor of a chain, in order.
def Vq.gather(-R: Type, c: Chain) -> V.Op<R, +List<U32>>:
  ?TODO

# Scatters bytes over the writable descriptors of a chain, in order, and
# answers how many bytes fit.
def Vq.scatter(-R: Type, c: Chain, bytes: +List<U32>) -> V.Op<R, U32>:
  ?TODO
