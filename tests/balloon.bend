import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/balloon.bend as K
import ../src/virtio/balauto.bend as A
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

# The stats queue (the automatic balloon): one readable buffer of two
# entries, free 1 GiB and total 2 GiB. Read and held (not used); a second
# arrival after the host asked (Balloon.poll) moves the target by a step.
def stat(+tag: U32, +hi: U32) -> +List<U32>:
  cat(B.Bytes.le16(tag), cat(B.Bytes.le32(0), B.Bytes.le32(hi)))

def stats_sim() -> S.Sim:
  +s = S.Sim.new(u64(4096), 8192n)
  +s = S.Sim.write(s, u64(8192), cat(stat(4, 0), stat(5, 0)))
  +s = S.Sim.write(s, u64(8192), cat(cat(B.Bytes.le16(4), B.Bytes.le64(u64(1073741824))), cat(B.Bytes.le16(5), B.Bytes.le64(U.U64{0, 2147483648}))))
  +s = S.Sim.write(s, u64(4096), desc(8192, 20, 0, 0))
  S.Sim.write(s, u64(5120), [0, 0, 1, 0, 0, 0])

def stats_run(+a: K.AutoSt) -> Maybe<&1, S.Sim & K.StatsPass>:
  S.Sim.exec(K.StatsPass, stats_sim(), K.Balloon.stats_pass(K.StatsPass, K.Balloon.new(), a, queue()))

def stats_target(r: Maybe<&1, S.Sim & K.StatsPass>) -> U32:
  match r:
    case None{}:
      4294967295
    case Some{(s, K.StatsPass{q, b, a})}:
      K.Balloon.target(b)

def stats_held(r: Maybe<&1, S.Sim & K.StatsPass>) -> U32:
  match r:
    case None{}:
      4294967295
    case Some{(s, K.StatsPass{q, b, a})}:
      K.Balloon.auto_held(a)

def poll_run(+held: U32) -> Maybe<&1, S.Sim & ((Q.Vq & K.AutoSt) & Bool)>:
  S.Sim.exec((Q.Vq & K.AutoSt) & Bool, stats_sim(), K.Balloon.poll((Q.Vq & K.AutoSt) & Bool, K.AutoSt{held, False{}, False{}, A.Auto.fresh()}, queue()))

def poll_used(r: Maybe<&1, S.Sim & ((Q.Vq & K.AutoSt) & Bool)>) -> +List<U32>:
  match r:
    case None{}:
      []
    case Some{(s, x)}:
      S.Sim.read(s, u64(6144), 12)

def poll_asked(r: Maybe<&1, S.Sim & ((Q.Vq & K.AutoSt) & Bool)>) -> Bool:
  match r:
    case None{}:
      False{}
    case Some{(s, ((q, K.AutoSt{h, k, m, st}), u))}:
      k && u && U32.is_eq(h, A.Auto.none())

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("balloon reporting: both buffers used, length 0", show(mem(run(2), 6144, 20)), "[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]")
    T.eq_str("balloon reporting: no whole block, memory kept", show(mem(run(2), 8192, 4)), "[7, 7, 7, 7]")
    T.ok("balloon reporting: the pass used buffers", used(run(2)))
    T.eq_u32("balloon inflate: 15 pages counted", actual_of(infl(0, K.Balloon.new())), 15)
    T.eq_u32("balloon deflate: 15 pages taken back", actual_of(infl(1, K.Bal{0, 20, []})), 5)
    T.eq_u32("balloon stats: the first buffer is held", stats_held(stats_run(K.Balloon.auto_new())), 0)
    T.eq_u32("balloon stats: unasked, the target stays", stats_target(stats_run(K.Balloon.auto_new())), 0)
    T.eq_u32("balloon stats: asked, 1 GiB free of 2 inflates a step", stats_target(stats_run(K.AutoSt{A.Auto.none(), True{}, False{}, A.Auto.fresh()})), 65536)
    T.eq_u32("balloon stats: set by hand, the target stays", stats_target(stats_run(K.AutoSt{A.Auto.none(), True{}, True{}, A.Auto.fresh()})), 0)
    T.eq_str("balloon poll: the held buffer comes back used", show(poll_used(poll_run(0))), "[0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
    T.ok("balloon poll: asked, nothing held", poll_asked(poll_run(0)))
    T.eq_str("balloon poll: nothing held, nothing used", show(poll_used(poll_run(A.Auto.none()))), "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
