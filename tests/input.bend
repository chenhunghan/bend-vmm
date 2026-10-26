import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/input.bend as In
import ../src/virtio/device.bend as D
import ./t.bend as T

# virtio-input's eventq pass and config selection on simulated guest memory.
# Layout (decimal): memory 4096..5120; descriptor table 4096 (8 entries),
# available ring 4224, used ring 4352. Descriptors 0..2 are writable 8-byte
# event buffers at 4608, 4616, 4624.

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def vq(na: U32, nu: U32) -> Q.Vq:
  Q.Vq{8, u64(4096), u64(4224), u64(4352), na, nu}

def desc(s: S.Sim, +i: U32, addr: U32) -> S.Sim:
  bs = List.append(&2, U32, B.Bytes.le64(u64(addr)),
    List.append(&2, U32, B.Bytes.le32(8), List.append(&2, U32, B.Bytes.le16(2), B.Bytes.le16(0))))
  S.Sim.write(s, u64((4096 + (i * 16 : U32) : U32)), bs)

def ring16(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      List.append(&2, U32, B.Bytes.le16(x), ring16(t))

def mem(+heads: +List<U32>) -> S.Sim:
  s = S.Sim.new(u64(4096), 1024n)
  s = desc(s, 0, 4608)
  s = desc(s, 1, 4616)
  s = desc(s, 2, 4624)
  idx = B.Bytes.le16(U32.from_nat(List.length(&2, U32, heads)))
  S.Sim.write(s, u64(4224), List.append(&2, U32, [0, 0], List.append(&2, U32, idx, ring16(heads))))

def run(s: S.Sim, evs: +List<+List<U32>>) -> Maybe<&1, S.Sim & In.InRx>:
  S.Sim.exec(In.InRx, s, In.Input.rx(In.InRx, In.InputState{0, 0, evs}, vq(0, 0)))

def check(+name: String, r: Maybe<&1, S.Sim & In.InRx>, left: Nat, used: Bool, ring: String, +na: U32, bufs: String) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, In.InRx{st, q, u})}:
      do IO<Unit>:
        T.ok(name ++ " left", Nat.is_eq(In.InputState.pending(st), left))
        T.ok(name ++ " used flag", Bool.not(Bool.xor(u, used)))
        T.eq_str(name ++ " used ring", show(S.Sim.read(s, u64(4352), (4 + (na * 8 : U32) : U32))), ring)
        T.ok(name ++ " state", Q.Vq.is_eq(q, vq(na, na)))
        T.eq_str(name ++ " buffers", show(S.Sim.read(s, u64(4608), 24)), bufs)

def key_a() -> +List<+List<U32>>:
  In.Input.events(False{}, In.HidKey{30, True{}})

# Reads config byte off of a device after writing select and subsel through
# the transport.
def snd(r: D.Dev & U32) -> U32:
  match r:
    case (d, x):
      x

def cfg_byte(r: Maybe<&1, S.Sim & D.DevOut>, off: U32) -> U32:
  match r:
    case None{}:
      999
    case Some{(s, D.DevOut{d, c, f, v})}:
      snd(D.Dev.read(d, off, 1))

def selected.then(r: Maybe<&1, S.Sim & D.DevOut>, sub: U32) -> Maybe<&1, S.Sim & D.DevOut>:
  match r:
    case None{}:
      None{}
    case Some{(s2, D.DevOut{d, c, f, v})}:
      S.Sim.exec(D.DevOut, s2, D.Dev.write(D.DevOut, d, 257, sub))

def selected(tablet: Bool, sel: U32, sub: U32) -> Maybe<&1, S.Sim & D.DevOut>:
  selected.then(S.Sim.exec(D.DevOut, S.Sim.new(u64(4096), 16n), D.Dev.write(D.DevOut, D.Dev.new(D.InputKind{tablet}), 256, sel)), sub)

def main() -> IO(Unit):
  do IO<Unit>:
    check("rx key", run(mem([0, 1]), key_a()), 0n, True{},
      "[0, 0, 2, 0, 0, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0]", 2,
      "[1, 0, 30, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
    check("rx one chain short", run(mem([2]), key_a()), 1n, True{},
      "[0, 0, 1, 0, 2, 0, 0, 0, 8, 0, 0, 0]", 1,
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 30, 0, 1, 0, 0, 0]")
    check("rx no chains", run(mem([]), key_a()), 2n, False{}, "[0, 0, 0, 0]", 0,
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
    check("rx nothing pending", run(mem([0]), []), 0n, False{}, "[0, 0, 0, 0]", 0,
      "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]")
    T.eq_u32("config select byte", cfg_byte(selected(True{}, 18, 0), 256), 18)
    T.eq_u32("config subsel byte", cfg_byte(selected(True{}, 18, 0), 257), 0)
    T.eq_u32("config abs size", cfg_byte(selected(True{}, 18, 0), 258), 20)
    T.eq_u32("config abs max", cfg_byte(selected(True{}, 18, 0), 268), 255)
    T.eq_u32("config keyboard name size", cfg_byte(selected(False{}, 1, 0), 258), 17)
    T.eq_u32("config keyboard name byte", cfg_byte(selected(False{}, 1, 0), 264), 98)
