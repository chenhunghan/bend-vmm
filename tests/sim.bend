import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ./t.bend as T

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

# Writes 3 bytes, reads 2 of them back, echoes them to the console, steps PC.
def prog() -> V.Op<U32, U32>:
  do V.Op<U32, U32>:
    _ : Unit <- V.Op.write(U32, U.U64{0, 4098}, [7, 8, 9])
    +bs : +List<U32> <- V.Op.read(U32, U.U64{0, 4099}, 2)
    _ : Unit <- V.Op.console(U32, bs)
    _ : Unit <- V.Op.advance_pc(U32)
    return List.foldl(~&2, ~U32, ~U32, ~U32.add, bs, 0)

def check(r: Maybe<&1, S.Sim & U32>) -> IO(Unit):
  match r:
    case None{}:
      T.ok("sim ran", False{})
    case Some{(+s, v)}:
      do IO<Unit>:
        T.eq_u32("sim result", v, 17)
        T.eq_str("sim mem", show(S.Sim.mem(s)), "[0, 0, 7, 8, 9, 0, 0, 0]")
        T.eq_str("sim console", show(S.Sim.console_out(s)), "[8, 9]")
        T.ok("sim pc", Nat.is_eq(S.Sim.pc_steps(s), 1n))

def main() -> IO(Unit):
  check(S.Sim.exec(U32, S.Sim.new(U.U64{0, 4096}, 8n), prog()))
