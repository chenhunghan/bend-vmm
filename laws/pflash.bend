import Base
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/dev/pflash.bend as Pf

# Frozen spec for src/dev/pflash.bend: the command sequences edk2's
# VirtNorFlashDeviceLib.c sends (commands doubled into both 16-bit halves).

def cmd(c: U32) -> U32:
  Pf.Pflash.dual(c)

def state(o: Pf.PfOut) -> Pf.Pflash:
  match o:
    case Pf.PfOut{f, cs}:
      f

def cmds(o: Pf.PfOut) -> +List<V.FlashCmd>:
  match o:
    case Pf.PfOut{f, cs}:
      cs

# The commands of the last of a run of writes, in order.
def run(ws: List<(U32 & U32)>, f: Pf.Pflash) -> Pf.PfOut:
  match ws:
    case Nil{}:
      Pf.PfOut{f, []}
    case Con{(off, v), Nil{}}:
      Pf.Pflash.write(f, off, v)
    case Con{(off, v), rest}:
      run(rest, state(Pf.Pflash.write(f, off, v)))

law pflash.fresh_reads_array:
  {Pf.Pflash.read(Pf.Pflash.new(), 64) == None{} : Maybe<&2, U32>}

law pflash.status_unmaps:
  {cmds(Pf.Pflash.write(Pf.Pflash.new(), 0, cmd(112))) == [V.FlashMap{False{}}] : +List<V.FlashCmd>}

law pflash.status_reads_ready:
  {Pf.Pflash.read(state(Pf.Pflash.write(Pf.Pflash.new(), 0, cmd(112))), 0) == Some{8388736} : Maybe<&2, U32>}

law pflash.read_array_maps:
  {cmds(run([(0, cmd(112)), (0, cmd(255))], Pf.Pflash.new())) == [V.FlashMap{True{}}] : +List<V.FlashCmd>}

law pflash.read_array_again:
  {state(run([(0, cmd(112)), (0, cmd(255))], Pf.Pflash.new())) == Pf.Pflash.new() : Pf.Pflash}

law pflash.erase:
  {cmds(run([(524296, cmd(32)), (524296, cmd(208))], Pf.Pflash.new())) == [V.FlashErase{524288, 262144}] : +List<V.FlashCmd>}

law pflash.erase_then_status:
  {Pf.Pflash.read(state(run([(524296, cmd(32)), (524296, cmd(208))], Pf.Pflash.new())), 524288) == Some{8388736} : Maybe<&2, U32>}

law pflash.erase_needs_confirm:
  {cmds(run([(524288, cmd(32)), (524288, cmd(255))], Pf.Pflash.new())) == [] : +List<V.FlashCmd>}

law pflash.buffered_ready:
  {Pf.Pflash.read(state(Pf.Pflash.write(Pf.Pflash.new(), 4096, cmd(232))), 4096) == Some{8388736} : Maybe<&2, U32>}

law pflash.buffered_program:
  {cmds(run([(4096, cmd(232)), (4096, cmd(1)), (4096, 67305985), (4100, 4294967295), (0, cmd(208))], Pf.Pflash.new())) == [V.FlashWrite{4096, [1, 2, 3, 4, 255, 255, 255, 255]}] : +List<V.FlashCmd>}

law pflash.buffered_waits_for_words:
  {cmds(run([(4096, cmd(232)), (4096, cmd(1)), (4096, 67305985)], Pf.Pflash.new())) == [] : +List<V.FlashCmd>}

law pflash.word_program:
  {cmds(run([(8, cmd(64)), (8, 305419896)], Pf.Pflash.new())) == [V.FlashWrite{8, [120, 86, 52, 18]}] : +List<V.FlashCmd>}

law pflash.unlocked:
  {Pf.Pflash.read(state(Pf.Pflash.write(Pf.Pflash.new(), 262152, cmd(144))), 262152) == Some{0} : Maybe<&2, U32>}

law pflash.manufacturer:
  {Pf.Pflash.read(state(Pf.Pflash.write(Pf.Pflash.new(), 0, cmd(144))), 0) == Some{8978569} : Maybe<&2, U32>}

law pflash.query_q:
  {Pf.Pflash.read(state(Pf.Pflash.write(Pf.Pflash.new(), 0, cmd(152))), 64) == Some{5308497} : Maybe<&2, U32>}

law pflash.unlock_then_status:
  {Pf.Pflash.read(state(run([(0, cmd(96)), (0, cmd(208))], Pf.Pflash.new())), 0) == Some{8388736} : Maybe<&2, U32>}
