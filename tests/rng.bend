import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/rng.bend as Rng
import ./t.bend as T

# virtio-rng's process on simulated guest memory. Layout (decimal): memory
# 4096..16416; descriptor table 4096, available ring 8192, used ring 12288.
# Chain 0: d0 = 16384, 4 bytes, WRITE.
# Chain 1: d1 = 16400, 3 bytes, WRITE|NEXT -> d2 = 16408, 2 bytes, WRITE.
# The simulator's entropy is 0, 1, 2, ...

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def vq() -> Q.Vq:
  Q.Vq{8, u64(4096), u64(8192), u64(12288), 0, 0}

# The descriptors, and an available ring publishing `avail` bytes.
def mem(avail: +List<U32>) -> S.Sim:
  +s = S.Sim.new(u64(4096), 12320n)
  s = S.Sim.write(s, u64(4096), [0, 64, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0])
  s = S.Sim.write(s, u64(4112), [16, 64, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 3, 0, 2, 0])
  s = S.Sim.write(s, u64(4128), [24, 64, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0])
  S.Sim.write(s, u64(8192), avail)

def run(s: S.Sim) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, s, Rng.Rng.process(Q.Vq & Bool, vq()))

def check_one(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("rng one ran", False{})
    case Some{(+s, (q, used))}:
      do IO<Unit>:
        T.ok("rng one used", used)
        T.eq_str("rng one buffer", show(S.Sim.read(s, u64(16384), 5)), "[0, 1, 2, 3, 0]")
        T.eq_str("rng one used ring", show(S.Sim.read(s, u64(12288), 12)), "[0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0]")
        T.eq_str("rng one chain 1 untouched", show(S.Sim.read(s, u64(16400), 10)), "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
        T.ok("rng one state", Q.Vq.is_eq(q, Q.Vq{8, u64(4096), u64(8192), u64(12288), 1, 1}))

def check_two(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("rng two ran", False{})
    case Some{(+s, (q, used))}:
      do IO<Unit>:
        T.ok("rng two used", used)
        T.eq_str("rng two buffer 0", show(S.Sim.read(s, u64(16384), 4)), "[0, 1, 2, 3]")
        T.eq_str("rng two buffer 1", show(S.Sim.read(s, u64(16400), 3)), "[4, 5, 6]")
        T.eq_str("rng two buffer 2", show(S.Sim.read(s, u64(16408), 3)), "[7, 8, 0]")
        T.eq_str("rng two used ring", show(S.Sim.read(s, u64(12288), 20)), "[0, 0, 2, 0, 0, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0]")
        T.ok("rng two state", Q.Vq.is_eq(q, Q.Vq{8, u64(4096), u64(8192), u64(12288), 2, 2}))

def check_empty(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("rng empty ran", False{})
    case Some{(+s, (q, used))}:
      do IO<Unit>:
        T.ok("rng empty not used", Bool.not(used))
        T.eq_str("rng empty buffer", show(S.Sim.read(s, u64(16384), 4)), "[0, 0, 0, 0]")
        T.eq_str("rng empty used ring", show(S.Sim.read(s, u64(12288), 4)), "[0, 0, 0, 0]")
        T.ok("rng empty state", Q.Vq.is_eq(q, vq()))

def main() -> IO(Unit):
  do IO<Unit>:
    check_one(run(mem([0, 0, 1, 0, 0, 0])))
    check_two(run(mem([0, 0, 2, 0, 0, 0, 1, 0])))
    check_empty(run(mem([0, 0, 0, 0])))
