import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/net.bend as N
import ./t.bend as T

# virtio-net's transmit and receive passes on simulated guest memory. Layout
# (decimal): memory 4096..5120; descriptor table 4096 (8 entries), available
# ring 4224, used ring 4352, buffers from 4608.
#
# Transmit descriptors (all readable; header bytes are 9):
#   0: 4608, 16 bytes: header, then frame [1, 2, 3, 4]
#   1: 4640, 5 bytes, NEXT -> 2: 4648, 10 bytes: header split 5 + 7, then
#      frame [5, 6, 7]
#   3: 4672, 12 bytes: a header alone
#   4: 4688, 8 bytes: shorter than a header
# Receive descriptors (all writable):
#   0: 4608, 64 bytes
#   1: 4688, 5 bytes, NEXT -> 2: 4704, 20 bytes
#   3: 4736, 16 bytes

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def show_frames(xs: +List<+List<U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      show(x) ++ ";" ++ show_frames(t)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def vq(na: U32, nu: U32) -> Q.Vq:
  Q.Vq{8, u64(4096), u64(4224), u64(4352), na, nu}

def nines(n: Nat) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      9 <> nines(p)

# Descriptor i: addr, len, flags, next.
def desc(s: S.Sim, +i: U32, addr: U32, len: U32, flags: U32, next: U32) -> S.Sim:
  bs = List.append(&2, U32, B.Bytes.le64(u64(addr)),
    List.append(&2, U32, B.Bytes.le32(len), List.append(&2, U32, B.Bytes.le16(flags), B.Bytes.le16(next))))
  S.Sim.write(s, u64((4096 + (i * 16 : U32) : U32)), bs)

def ring16(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      List.append(&2, U32, B.Bytes.le16(x), ring16(t))

# An available ring publishing the given heads.
def avail(s: S.Sim, +heads: +List<U32>) -> S.Sim:
  idx = B.Bytes.le16(U32.from_nat(List.length(&2, U32, heads)))
  ring = ring16(heads)
  S.Sim.write(s, u64(4224), List.append(&2, U32, [0, 0], List.append(&2, U32, idx, ring)))

def tx_mem(heads: +List<U32>) -> S.Sim:
  s = S.Sim.new(u64(4096), 1024n)
  s = desc(s, 0, 4608, 16, 0, 0)
  s = desc(s, 1, 4640, 5, 1, 2)
  s = desc(s, 2, 4648, 10, 0, 0)
  s = desc(s, 3, 4672, 12, 0, 0)
  s = desc(s, 4, 4688, 8, 0, 0)
  s = S.Sim.write(s, u64(4608), List.append(&2, U32, nines(12n), [1, 2, 3, 4]))
  s = S.Sim.write(s, u64(4640), nines(5n))
  s = S.Sim.write(s, u64(4648), List.append(&2, U32, nines(7n), [5, 6, 7]))
  s = S.Sim.write(s, u64(4672), nines(12n))
  s = S.Sim.write(s, u64(4688), nines(8n))
  avail(s, heads)

def rx_mem(heads: +List<U32>) -> S.Sim:
  s = S.Sim.new(u64(4096), 1024n)
  s = desc(s, 0, 4608, 64, 2, 0)
  s = desc(s, 1, 4688, 5, 3, 2)
  s = desc(s, 2, 4704, 20, 2, 0)
  s = desc(s, 3, 4736, 16, 2, 0)
  avail(s, heads)

def run_tx(s: S.Sim) -> Maybe<&1, S.Sim & N.NetTx>:
  S.Sim.exec(N.NetTx, s, N.Net.tx(N.NetTx, vq(0, 0)))

def run_rx(s: S.Sim, frames: +List<+List<U32>>) -> Maybe<&1, S.Sim & N.NetRx>:
  S.Sim.exec(N.NetRx, s, N.Net.rx(N.NetRx, vq(0, 0), frames))

def used_ring(s: S.Sim, n: U32) -> String:
  show(S.Sim.read(s, u64(4352), (4 + (n * 8 : U32) : U32)))

def check_tx(
  +name: String, r: Maybe<&1, S.Sim & N.NetTx>, frames: String, used: Bool, ring: String, n: U32, +na: U32
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, N.NetTx{q, fs, u})}:
      do IO<Unit>:
        T.eq_str(name ++ " frames", show_frames(fs), frames)
        T.ok(name ++ " used flag", Bool.not(Bool.xor(u, used)))
        T.eq_str(name ++ " used ring", used_ring(s, n), ring)
        T.ok(name ++ " state", Q.Vq.is_eq(q, vq(na, na)))

# The bytes of every (addr, len) region, each shown, joined by ";".
def regions(+s: S.Sim, rs: List<(U32 & U32)>) -> String:
  match rs:
    case Nil{}:
      ""
    case Con{(a, l), t}:
      show(S.Sim.read(s, u64(a), l)) ++ ";" ++ regions(s, t)

def check_rx(
  +name: String, r: Maybe<&1, S.Sim & N.NetRx>, left: String, used: Bool, ring: String, n: U32,
  +na: U32, rs: List<(U32 & U32)>, bufs: String
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, N.NetRx{q, ls, u})}:
      do IO<Unit>:
        T.eq_str(name ++ " left", show_frames(ls), left)
        T.ok(name ++ " used flag", Bool.not(Bool.xor(u, used)))
        T.eq_str(name ++ " used ring", used_ring(s, n), ring)
        T.ok(name ++ " state", Q.Vq.is_eq(q, vq(na, na)))
        T.eq_str(name ++ " buffers", regions(s, rs), bufs)

# A TCP segment whose IPv4 total length (140) claims 100 payload bytes
# after 54 bytes of headers, in one readable descriptor 5 at 4608 holding
# the virtio_net_hdr, the headers and `pl` payload bytes.
def tcp_head() -> +List<U32>:
  [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 69, 0, 0, 140, 0, 0, 0, 0, 64, 6, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 0, 80, 0, 81, 0, 0, 0, 1, 0, 0, 0, 1, 80, 24, 1, 0, 0, 0, 0, 0]

def tcp_mem(pl: U32) -> S.Sim:
  s = S.Sim.new(u64(4096), 1024n)
  s = desc(s, 5, 4608, (66 + pl : U32), 0, 0)
  s = S.Sim.write(s, u64(4608), List.append(&2, U32, B.Bytes.zeros(12n), tcp_head()))
  avail(s, [5])

# The longest guest read a program asks for, running it on the simulator's
# memory up to its first effect other than a read, a write or a stage;
# reads past 4096 bytes answer nothing (too large for the simulator's lists).
def longest(fuel: Nat, -A: Type, s: S.Sim, m: V.Vm<A>, +top: U32) -> U32:
  match fuel:
    case 0n:
      top
    case 1n+f:
      match m:
        case V.VmRead{+a, +n, k}:
          +s = s
          +big = U32.is_lt(4096, n)
          longest(f, A, s, k(Bool.pick(+List<U32>, big, [], S.Sim.read(s, a, n))), U32.max(top, n))
        case V.VmWrite{a, bs, next}:
          longest(f, A, S.Sim.write(s, a, bs), next, top)
        case _:
          top

# A transmit chain of one readable descriptor 4294967295 bytes long (no TCP
# segment): the device reads at most a 64 KiB frame and its header of it.
def tx_huge() -> U32:
  s = desc(S.Sim.new(u64(4096), 1024n), 5, 4608, 4294967295, 0, 0)
  longest(100n, N.NetTx, avail(s, [5]), V.Op.finish(N.NetTx, N.Net.tx(N.NetTx, vq(0, 0))), 0)

def main() -> IO(Unit):
  do IO<Unit>:
    check_tx("tx one", run_tx(tx_mem([0])),
      "[1, 2, 3, 4];", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx split header", run_tx(tx_mem([1])),
      "[5, 6, 7];", True{}, "[0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx two", run_tx(tx_mem([0, 1])),
      "[1, 2, 3, 4];[5, 6, 7];", True{},
      "[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]", 2, 2)
    check_tx("tx short chains", run_tx(tx_mem([3, 4])),
      "", True{}, "[0, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]", 2, 2)
    check_tx("tx short then frame", run_tx(tx_mem([4, 0])),
      "[1, 2, 3, 4];", True{}, "[0, 0, 2, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]", 2, 2)
    check_tx("tx empty", run_tx(tx_mem([])),
      "", False{}, "[0, 0, 0, 0]", 0, 0)
    check_rx("rx one desc", run_rx(rx_mem([0]), [[1, 2, 3]]),
      "", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 15, 0, 0, 0]", 1, 1, [(4608, 16)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 2, 3, 0];")
    check_rx("rx multi desc", run_rx(rx_mem([1]), [[7, 8, 9, 10]]),
      "", True{}, "[0, 0, 1, 0, 1, 0, 0, 0, 16, 0, 0, 0]", 1, 1, [(4688, 5), (4704, 12)],
      "[0, 0, 0, 0, 0];[0, 0, 0, 0, 0, 1, 0, 7, 8, 9, 10, 0];")
    check_rx("rx two", run_rx(rx_mem([0, 1]), [[1, 2, 3], [7, 8, 9, 10]]),
      "", True{}, "[0, 0, 2, 0, 0, 0, 0, 0, 15, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0]", 2, 2,
      [(4608, 16), (4688, 5), (4704, 12)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 2, 3, 0];[0, 0, 0, 0, 0];[0, 0, 0, 0, 0, 1, 0, 7, 8, 9, 10, 0];")
    check_rx("rx exact fit", run_rx(rx_mem([3]), [[1, 2, 3, 4]]),
      "", True{}, "[0, 0, 1, 0, 3, 0, 0, 0, 16, 0, 0, 0]", 1, 1, [(4736, 17)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 2, 3, 4, 0];")
    check_rx("rx too big then fits", run_rx(rx_mem([3]), [[1, 2, 3, 4, 5], [6, 7]]),
      "", True{}, "[0, 0, 1, 0, 3, 0, 0, 0, 14, 0, 0, 0]", 1, 1, [(4736, 17)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 6, 7, 0, 0, 0];")
    check_rx("rx too big kept", run_rx(rx_mem([3]), [[1, 2, 3, 4, 5]]),
      "", False{}, "[0, 0, 0, 0]", 0, 0, [(4736, 17)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];")
    check_rx("rx more frames than buffers", run_rx(rx_mem([0]), [[1], [2], [3]]),
      "[2];[3];", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 13, 0, 0, 0]", 1, 1, [(4608, 14)],
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0];")
    check_rx("rx no buffers", run_rx(rx_mem([]), [[1, 2]]),
      "[1, 2];", False{}, "[0, 0, 0, 0]", 0, 0, [(4608, 4)], "[0, 0, 0, 0];")
    check_rx("rx no frames", run_rx(rx_mem([0]), []),
      "", False{}, "[0, 0, 0, 0]", 0, 0, [(4608, 4)], "[0, 0, 0, 0];")
    check_tx("tx tcp staged", run_tx(tcp_mem(100)),
      "[257, 0, 100, 2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 69, 0, 0, 140, 0, 0, 0, 0, 64, 6, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 0, 80, 0, 81, 0, 0, 0, 1, 0, 0, 0, 1, 80, 24, 1, 0, 0, 0, 0, 0];", True{}, "[0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx tcp shorter than its header says dropped", run_tx(tcp_mem(10)),
      "", True{}, "[0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    T.eq_u32("tx reads at most 65562 bytes of a chain", tx_huge(), 65562)
