import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-balloon (Virtio 1.2 section 5.5), device id 5, offered with
# --balloon free-page-reporting: VIRTIO_F_VERSION_1 and
# VIRTIO_BALLOON_F_FREE_PAGE_REPORTING (bit 5). Three queues, as Linux and
# QEMU number them when neither the stats nor the free page hint queue is
# offered: 0 inflateq, 1 deflateq, 2 reporting_vq. Config space: num_pages
# (u32, always 0: the host never asks the guest to inflate) and actual (u32).
#
# Free page reporting: every buffer on the reporting queue names free guest
# pages, one descriptor per range (Linux: blocks of its page_reporting_order,
# 2 MiB with 4 KiB pages). The host lets go of the memory behind each range
# (Op.ram_release: what the guest touches there again reads as zeros or as
# its old contents, never anything else), then returns the buffer, used
# length 0. Only the whole Balloon.align() blocks inside a range are
# released, so a host page is never cut (macOS: 16 KiB pages). Buffers on
# the inflate and deflate queues are returned untouched (num_pages is 0, so
# a driver posts none).

def Balloon.features() -> U.U64:
  U.U64{1, 32}

def Balloon.queues() -> Nat:
  3n

def Balloon.report_queue() -> U32:
  2

def Balloon.config() -> +List<U32>:
  B.Bytes.zeros(8n)

# The release granule: 64 KiB covers the host page sizes in use (4, 16 and
# 64 KiB).
def Balloon.align() -> U32:
  65536

# The whole granules inside [addr, addr+len): none (len 0) when there are
# none.
def Balloon.inside(+addr: U.U64, +len: U32) -> V.Iov:
  +a = U.U64.align_up(16n, addr)
  +e = U.U64.and(U.U64.add_u32(addr, len), U.U64.not(U.U64{0, 65535}))
  V.Iov{a, Bool.pick(U32, U.U64.is_lt(a, e), U.U64.lo(U.U64.sub(e, a)), 0)}

def Balloon.len(+i: V.Iov) -> U32:
  match i:
    case V.Iov{a, l}:
      l

# The granules of every descriptor of a buffer, the empty ones dropped.
def Balloon.ranges(ds: +List<Q.Desc>) -> +List<V.Iov>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case Q.Desc{+a, +l, f, n}:
          +i = Balloon.inside(a, l)
          +more = Balloon.ranges(rest)
          Bool.pick(+List<V.Iov>, U32.is_eq(Balloon.len(i), 0), more, Con{i, more})

def Balloon.free(-R: Type, go: Bool, +rs: +List<V.Iov>) -> V.Op<R, Unit>:
  match go:
    case True{}:
      V.Op.ram_release(R, rs)
    case False{}:
      V.Op.pure(R, Unit, Unit{})

def Balloon.serve(-R: Type, release: Bool, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      +rs = Balloon.ranges(List.append(&2, Q.Desc, r, w))
      do V.Op<R, Q.Vq>:
        Balloon.free(R, release && Bool.not(List.is_empty(&2, V.Iov, rs)), rs)
        Q.Vq.push(R, q, h, 0)

def Balloon.step(
  -R: Type, release: Bool, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool, k: Q.Vq -> V.Op<R, Q.Vq & Bool>
) -> V.Op<R, Q.Vq & Bool>:
  match r:
    case (q, None{}):
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, Q.Vq & Bool, Balloon.serve(R, release, q, c), k)

def Balloon.go(fuel: Nat, -R: Type, +release: Bool, q: Q.Vq, used: Bool) -> V.Op<R, Q.Vq & Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case 1n+f:
      do V.Op<R, Q.Vq & Bool>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Balloon.step(R, release, r, used, q2 => Balloon.go(f, R, release, q2, True{}))

# Queue sel's pass: the reporting queue releases what each buffer names;
# the others return their buffers. At most 256 buffers per pass.
def Balloon.process(-R: Type, +sel: U32, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  Balloon.go(256n, R, U32.is_eq(sel, Balloon.report_queue()), q, False{})
