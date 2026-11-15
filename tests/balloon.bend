import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/balloon.bend as K
import ./t.bend as T

# virtio-balloon's queues on the simulator (memory 4096..12288: descriptor
# table 4096, available ring 5120, used ring 6144). Two buffers, each one
# writable descriptor of free pages too small to hold a whole 64 KiB block
# (src/virtio/balloon.bend releases none of it: laws/balloon.bend has the
# ranges; scripts/balloon-test.py the release on a real host). Every
# buffer comes back used with length 0 and the memory is kept.

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def desc(addr: U32, len: U32, flags: U32, next: U32) -> +List<U32>:
  cat(B.Bytes.le64(u64(addr)), cat(B.Bytes.le32(len), cat(B.Bytes.le16(flags), B.Bytes.le16(next))))

def sim() -> S.Sim:
  +s = S.Sim.new(u64(4096), 8192n)
  +s = S.Sim.write(s, u64(8192), List.replicate(U32, 64n, 7))
  +s = S.Sim.write(s, u64(4096), cat(desc(8192, 32, 2, 0), desc(8224, 32, 2, 0)))
  S.Sim.write(s, u64(5120), [0, 0, 2, 0, 0, 0, 1, 0])

def queue() -> Q.Vq:
  Q.Vq{8, u64(4096), u64(5120), u64(6144), 0, 0}

def run(+sel: U32) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, sim(), K.Balloon.process(Q.Vq & Bool, sel, queue()))

def mem(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>, +addr: U32, +n: U32) -> +List<U32>:
  match r:
    case None{}:
      []
    case Some{(s, x)}:
      S.Sim.read(s, u64(addr), n)

def used(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>) -> Bool:
  match r:
    case None{}:
      False{}
    case Some{(s, (q, u))}:
      u

# The inflate queue: one readable buffer of 15 page numbers (256..270; not a
# whole block, so nothing released): counted in the state, the buffer used.
def le32s(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, rest}:
      cat(B.Bytes.le32(x), le32s(rest))

def pfns(n: Nat, +i: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+k:
      Con{i, pfns(k, (i + 1 : U32))}

def infl_sim(+inflate: Bool) -> S.Sim:
  +s = S.Sim.new(u64(4096), 8192n)
  +s = S.Sim.write(s, u64(8192), le32s(pfns(15n, 256)))
  +s = S.Sim.write(s, u64(4096), desc(8192, 60, 0, 0))
  S.Sim.write(s, u64(5120), [0, 0, 1, 0, 0, 0])

def infl(+sel: U32, +b: K.Bal) -> Maybe<&1, S.Sim & K.BalPass>:
  S.Sim.exec(K.BalPass, infl_sim(True{}), K.Balloon.pass(K.BalPass, sel, b, queue()))

def actual_of(r: Maybe<&1, S.Sim & K.BalPass>) -> U32:
  match r:
    case None{}:
      4294967295
    case Some{(s, K.BalPass{q, b, u})}:
      K.Balloon.actual(b)

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("balloon reporting: both buffers used, length 0", show(mem(run(2), 6144, 20)), "[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]")
    T.eq_str("balloon reporting: no whole block, memory kept", show(mem(run(2), 8192, 4)), "[7, 7, 7, 7]")
    T.ok("balloon reporting: the pass used buffers", used(run(2)))
    T.eq_u32("balloon inflate: 15 pages counted", actual_of(infl(0, K.Balloon.new())), 15)
    T.eq_u32("balloon deflate: 15 pages taken back", actual_of(infl(1, K.Bal{0, 20, []})), 5)
