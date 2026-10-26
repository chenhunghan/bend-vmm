import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ./t.bend as T

# FROZEN SPEC (architect-owned): the split virtqueue against simulated guest
# memory. Layout (decimal): memory 4096..16408; descriptor table 4096,
# available ring 8192, used ring 12288, buffers at 16384 and 16400.
# Chain: d0 = 16384, 4 bytes, NEXT -> d1; d1 = 16400, 8 bytes, WRITE.

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def mem() -> S.Sim:
  +s = S.Sim.new(u64(4096), 12312n)
  s = S.Sim.write(s, u64(4096), [0, 64, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 1, 0, 1, 0])
  s = S.Sim.write(s, u64(4112), [16, 64, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0])
  s = S.Sim.write(s, u64(8192), [0, 0, 1, 0, 0, 0])
  S.Sim.write(s, u64(16384), [1, 2, 3, 4])

type Out is Data:
  Out{first: Maybe<&2, Q.Chain>, second: Maybe<&2, Q.Chain>, req: +List<U32>, wrote: U32, q: Q.Vq}

def scenario.fin(first: Maybe<&2, Q.Chain>, req: +List<U32>, n: U32, r: Q.Vq & Maybe<&2, Q.Chain>) -> Out:
  match r:
    case (q, second):
      Out{first, second, req, n, q}

# pop, gather, scatter 3 bytes, push, pop again.
def scenario.go(-R: Type, q: Q.Vq, c: Maybe<&2, Q.Chain>) -> V.Op<Out, Out>:
  match c:
    case None{}:
      V.Op.pure(Out, Out, Out{None{}, None{}, [], 0, q})
    case Some{+chain}:
      do V.Op<Out, Out>:
        +req : +List<U32> <- Q.Vq.gather(Out, chain)
        +n : U32 <- Q.Vq.scatter(Out, chain, [9, 9, 9])
        q2 : Q.Vq <- Q.Vq.push(Out, q, Q.Chain.head(chain), n)
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(Out, q2)
        return scenario.fin(Some{chain}, req, n, r)

def scenario.split(r: Q.Vq & Maybe<&2, Q.Chain>) -> V.Op<Out, Out>:
  match r:
    case (q, c):
      scenario.go(Out, q, c)

def scenario() -> V.Op<Out, Out>:
  do V.Op<Out, Out>:
    r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(Out, Q.Vq{4, u64(4096), u64(8192), u64(12288), 0, 0})
    scenario.split(r)

def check(r: Maybe<&1, S.Sim & Out>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("virtio_queue ran", False{})
    case Some{(+s, o)}:
      match o:
        case Out{first, second, req, wrote, q}:
          do IO<Unit>:
            T.ok("virtio_queue pop chain", Q.Chain.is_eq_maybe(first, Some{Q.Chain{0, [Q.Desc{u64(16384), 4, 1, 1}], [Q.Desc{u64(16400), 8, 2, 0}]}}))
            T.eq_str("virtio_queue gather", show(req), "[1, 2, 3, 4]")
            T.eq_u32("virtio_queue scatter len", wrote, 3)
            T.eq_str("virtio_queue scatter mem", show(S.Sim.read(s, u64(16400), 4)), "[9, 9, 9, 0]")
            T.eq_str("virtio_queue used ring", show(S.Sim.read(s, u64(12288), 12)), "[0, 0, 1, 0, 0, 0, 0, 0, 3, 0, 0, 0]")
            T.ok("virtio_queue second pop empty", Maybe.is_none(&2, Q.Chain, second))
            T.ok("virtio_queue state", Q.Vq.is_eq(q, Q.Vq{4, u64(4096), u64(8192), u64(12288), 1, 1}))

def main() -> IO(Unit):
  check(S.Sim.exec(Out, mem(), scenario()))
