import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/console.bend as C
import ./t.bend as T

# virtio-console's transmit and receive passes on simulated guest memory.
# Layout (decimal): memory 4096..5120; descriptor table 4096 (8 entries),
# available ring 4224, used ring 4352, buffers from 4608.
#
# Transmit descriptors (readable unless said):
#   0: 4608, 3 bytes [1, 2, 3]
#   1: 4640, 2 bytes [4, 5], NEXT -> 2: 4648, 3 bytes [6, 7, 8]
#   3: 4672, 2 bytes [9, 9], NEXT -> 4: 4688, 4 bytes, writable (ignored)
# Receive descriptors (all writable):
#   0: 4608, 4 bytes
#   1: 4688, 2 bytes, NEXT -> 2: 4704, 3 bytes
#   3: 4736, 8 bytes

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def vq(na: U32, nu: U32) -> Q.Vq:
  Q.Vq{8, u64(4096), u64(4224), u64(4352), na, nu}

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
  s = desc(s, 0, 4608, 3, 0, 0)
  s = desc(s, 1, 4640, 2, 1, 2)
  s = desc(s, 2, 4648, 3, 0, 0)
  s = desc(s, 3, 4672, 2, 1, 4)
  s = desc(s, 4, 4688, 4, 2, 0)
  s = S.Sim.write(s, u64(4608), [1, 2, 3])
  s = S.Sim.write(s, u64(4640), [4, 5])
  s = S.Sim.write(s, u64(4648), [6, 7, 8])
  s = S.Sim.write(s, u64(4672), [9, 9])
  s = S.Sim.write(s, u64(4688), [7, 7, 7, 7])
  avail(s, heads)

def rx_mem(heads: +List<U32>) -> S.Sim:
  s = S.Sim.new(u64(4096), 1024n)
  s = desc(s, 0, 4608, 4, 2, 0)
  s = desc(s, 1, 4688, 2, 3, 2)
  s = desc(s, 2, 4704, 3, 2, 0)
  s = desc(s, 3, 4736, 8, 2, 0)
  avail(s, heads)

def run_tx(s: S.Sim) -> Maybe<&1, S.Sim & C.ConTx>:
  S.Sim.exec(C.ConTx, s, C.Con.tx(C.ConTx, vq(0, 0)))

def run_rx(s: S.Sim, input: +List<U32>) -> Maybe<&1, S.Sim & C.ConRx>:
  S.Sim.exec(C.ConRx, s, C.Con.rx(C.ConRx, vq(0, 0), input))

def used_ring(s: S.Sim, n: U32) -> String:
  show(S.Sim.read(s, u64(4352), (4 + (n * 8 : U32) : U32)))

def check_tx(
  +name: String, r: Maybe<&1, S.Sim & C.ConTx>, bytes: String, used: Bool, ring: String, n: U32, +na: U32
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, C.ConTx{q, bs, u})}:
      do IO<Unit>:
        T.eq_str(name ++ " bytes", show(bs), bytes)
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
  +name: String, r: Maybe<&1, S.Sim & C.ConRx>, left: String, used: Bool, ring: String, n: U32,
  +na: U32, rs: List<(U32 & U32)>, bufs: String
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, C.ConRx{q, ls, u})}:
      do IO<Unit>:
        T.eq_str(name ++ " left", show(ls), left)
        T.ok(name ++ " used flag", Bool.not(Bool.xor(u, used)))
        T.eq_str(name ++ " used ring", used_ring(s, n), ring)
        T.ok(name ++ " state", Q.Vq.is_eq(q, vq(na, na)))
        T.eq_str(name ++ " buffers", regions(s, rs), bufs)

def main() -> IO(Unit):
  do IO<Unit>:
    check_tx("tx one", run_tx(tx_mem([0])),
      "[1, 2, 3]", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx multi desc", run_tx(tx_mem([1])),
      "[4, 5, 6, 7, 8]", True{}, "[0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx two", run_tx(tx_mem([0, 1])),
      "[1, 2, 3, 4, 5, 6, 7, 8]", True{},
      "[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]", 2, 2)
    check_tx("tx two reversed", run_tx(tx_mem([1, 0])),
      "[4, 5, 6, 7, 8, 1, 2, 3]", True{},
      "[0, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]", 2, 2)
    check_tx("tx skips writable", run_tx(tx_mem([3])),
      "[9, 9]", True{}, "[0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0]", 1, 1)
    check_tx("tx empty", run_tx(tx_mem([])),
      "[]", False{}, "[0, 0, 0, 0]", 0, 0)
    check_rx("rx smaller", run_rx(rx_mem([3]), [1, 2, 3]),
      "[]", True{}, "[0, 0, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0]", 1, 1, [(4736, 9)],
      "[1, 2, 3, 0, 0, 0, 0, 0, 0];")
    check_rx("rx exact", run_rx(rx_mem([0]), [1, 2, 3, 4]),
      "[]", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0]", 1, 1, [(4608, 5)],
      "[1, 2, 3, 4, 0];")
    check_rx("rx larger", run_rx(rx_mem([0]), [1, 2, 3, 4, 5, 6]),
      "[5, 6]", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0]", 1, 1, [(4608, 5)],
      "[1, 2, 3, 4, 0];")
    check_rx("rx multi desc", run_rx(rx_mem([1]), [1, 2, 3, 4, 5]),
      "[]", True{}, "[0, 0, 1, 0, 1, 0, 0, 0, 5, 0, 0, 0]", 1, 1, [(4688, 3), (4704, 4)],
      "[1, 2, 0];[3, 4, 5, 0];")
    check_rx("rx two larger", run_rx(rx_mem([0, 1]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      "[10]", True{}, "[0, 0, 2, 0, 0, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0]", 2, 2,
      [(4608, 4), (4688, 2), (4704, 3)],
      "[1, 2, 3, 4];[5, 6];[7, 8, 9];")
    check_rx("rx two smaller", run_rx(rx_mem([0, 3]), [1, 2, 3, 4, 5, 6]),
      "[]", True{}, "[0, 0, 2, 0, 0, 0, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0]", 2, 2,
      [(4608, 4), (4736, 8)],
      "[1, 2, 3, 4];[5, 6, 0, 0, 0, 0, 0, 0];")
    check_rx("rx stops when input runs out", run_rx(rx_mem([0, 3]), [1, 2, 3, 4]),
      "[]", True{}, "[0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0]", 1, 1, [(4608, 4), (4736, 8)],
      "[1, 2, 3, 4];[0, 0, 0, 0, 0, 0, 0, 0];")
    check_rx("rx empty input", run_rx(rx_mem([0]), []),
      "[]", False{}, "[0, 0, 0, 0]", 0, 0, [(4608, 4)], "[0, 0, 0, 0];")
    check_rx("rx no buffers", run_rx(rx_mem([]), [1, 2]),
      "[1, 2]", False{}, "[0, 0, 0, 0]", 0, 0, [(4608, 4)], "[0, 0, 0, 0];")
