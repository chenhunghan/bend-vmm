import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/device.bend as D
import ../src/vmm/machine.bend as M
import ./t.bend as T

# Sequences of exits through one Machine on the simulator, plus the single
# exits tests/machine.bend leaves out. Syndromes (decimal):
#   2474704960 str w1   2474704896 ldr w1   1509949440 hvc #0
#   1644167265 mrs x3   1644167264 msr x3   2449473536 data abort, no ISV
#   2147483648 instruction abort  2476670976 ldr wzr  0 unknown class
# Addresses: UART 150994944 (DR +0, FR +24, IMSC +56); virtio slot 0
# 167772160, slot 1 167772672.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def z() -> U.U64:
  U.U64{0, 0}

def exc(esr: U32, ipa: U32, x0: U32, x1: U32, x2: U32, x3: U32, xt: U32) -> V.RawExit:
  V.Exception{w(esr), z(), w(ipa), w(x0), w(x1), w(x2), w(x3), w(xt)}

def store(ipa: U32, v: U32) -> V.RawExit:
  exc(2474704960, ipa, 0, 0, 0, 0, v)

def load(ipa: U32) -> V.RawExit:
  exc(2474704896, ipa, 0, 0, 0, 0, 0)

def hvc(x0: U32, x1: U32, x2: U32, x3: U32) -> V.RawExit:
  exc(1509949440, 0, x0, x1, x2, x3, 0)

def show_reg(r: S.SetReg) -> String:
  match r:
    case S.SetReg{n, v}:
      "x" ++ U32.show(n) ++ "=" ++ U.U64.show_hex(v)

def show_irq(i: S.Irq) -> String:
  match i:
    case S.Irq{n, l}:
      U32.show(n) ++ ":" ++ U32.show(Bool.to_u32(l))

def show_power(p: V.PowerOp) -> String:
  match p:
    case V.PowerOff{}:
      "off"
    case V.PowerReset{}:
      "reset"

def show_ctl(c: M.Control) -> String:
  match c:
    case M.Run{}:
      "run"
    case M.Idle{}:
      "idle"
    case M.CpuStop{}:
      "cpu-stop"
    case M.Stop{n}:
      "stop " ++ U32.show(n)

def show_bytes(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

# The recorded effects, newest first: regs | pc steps | console | irqs | power
# | log lines.
def effects(+s: S.Sim) -> String:
  List.show(~&2, ~S.SetReg, ~show_reg, S.Sim.regs(s)) ++ " | pc+" ++ Nat.show(S.Sim.pc_steps(s)) ++ " | " ++ show_bytes(S.Sim.console_out(s)) ++ " | " ++ List.show(~&2, ~S.Irq, ~show_irq, S.Sim.irqs(s)) ++ " | " ++ List.show(~&2, ~V.PowerOp, ~show_power, S.Sim.powers(s)) ++ " | log " ++ Nat.show(List.length(&2, String, S.Sim.logs(s)))

# One exit on a fresh machine: control | effects.
def one(r: Maybe<&1, S.Sim & M.Step>) -> String:
  match r:
    case None{}:
      "out of fuel"
    case Some{(s, step)}:
      match step:
        case M.Step{m, c}:
          show_ctl(c) ++ " | " ++ effects(s)

def run(cpu: U32, e: V.RawExit) -> String:
  one(S.Sim.run(100000n, M.Step, S.Sim.new(w(1073741824), 64n), M.Machine.on_exit(cpu, M.Machine.new(2n, [D.RngKind{}]), e)))

# A step of a sequence: an exit on a cpu, or bytes typed on the console.
type Ev is Data:
  At{cpu: U32, exit: V.RawExit}
  Typed{bytes: +List<U32>}

def Ev.after(r: Maybe<&1, S.Sim & M.Step>) -> Maybe<&1, S.Sim & M.Machine>:
  match r:
    case None{}:
      None{}
    case Some{(s, step)}:
      match step:
        case M.Step{m, c}:
          Some{(s, m)}

def Ev.step(ev: Ev, st: Maybe<&1, S.Sim & M.Machine>) -> Maybe<&1, S.Sim & M.Machine>:
  match ev st:
    case _ None{}:
      None{}
    case At{cpu, e} Some{(s, m)}:
      Ev.after(S.Sim.run(100000n, M.Step, s, M.Machine.on_exit(cpu, m, e)))
    case Typed{bs} Some{(s, m)}:
      S.Sim.run(100000n, M.Machine, s, M.Machine.input(m, bs))

def trace(evs: List<Ev>, st: Maybe<&1, S.Sim & M.Machine>) -> Maybe<&1, S.Sim & M.Machine>:
  match evs:
    case Nil{}:
      st
    case Con{ev, rest}:
      trace(rest, Ev.step(ev, st))

def outcome(r: Maybe<&1, S.Sim & M.Machine>) -> String:
  match r:
    case None{}:
      "out of fuel"
    case Some{(s, m)}:
      effects(s)

def seq(s: S.Sim, kinds: +List<D.DevKind>, evs: List<Ev>) -> String:
  outcome(trace(evs, Some{(s, M.Machine.new(2n, kinds))}))

# The guest memory of tests/device.bend: one 4-byte WRITE request posted in
# queue 0 (descriptors 4096, available 8192, used 12288, buffer 16384).
def mem() -> S.Sim:
  +s = S.Sim.new(w(4096), 12320n)
  s = S.Sim.write(s, w(4096), [0, 64, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0])
  S.Sim.write(s, w(8192), [0, 0, 1, 0, 0, 0])

# Enable the RX interrupt, type two bytes, read FR then DR until empty; then
# a DR write prints, and slot 1 answers its device id.
def uart() -> List<Ev>:
  [At{0, store(150995000, 16)}, Typed{[104, 105]}, At{0, load(150994968)}, At{0, load(150994944)}, At{0, load(150994944)}, At{0, load(150994944)}, At{0, store(150994944, 33)}, At{0, load(167772680)}]

# Overflow: 40 bytes typed, 32 kept, FR reads RXFF.
def overflow() -> List<Ev>:
  [Typed{List.replicate(U32, 40n, 120)}, At{0, load(150994968)}]

# Linux's virtio_mmio probe of the rng in slot 0, a notify, then the ack.
def probe() -> List<Ev>:
  +b = {167772160 : U32}
  [At{0, load(b)}, At{0, load((b + 8 : U32))},
   At{0, store((b + 112 : U32), 0)}, At{0, store((b + 112 : U32), 1)}, At{0, store((b + 112 : U32), 3)},
   At{0, store((b + 36 : U32), 1)}, At{0, store((b + 32 : U32), 1)}, At{0, store((b + 36 : U32), 0)}, At{0, store((b + 32 : U32), 0)},
   At{0, store((b + 112 : U32), 11)},
   At{0, store((b + 48 : U32), 0)}, At{0, store((b + 56 : U32), 8)},
   At{0, store((b + 128 : U32), 4096)}, At{0, store((b + 132 : U32), 0)},
   At{0, store((b + 144 : U32), 8192)}, At{0, store((b + 148 : U32), 0)},
   At{0, store((b + 160 : U32), 12288)}, At{0, store((b + 164 : U32), 0)},
   At{0, store((b + 68 : U32), 1)}, At{0, store((b + 112 : U32), 15)},
   At{0, store((b + 80 : U32), 0)}, At{0, load((b + 96 : U32))}, At{0, store((b + 100 : U32), 1)}]

def probed(r: Maybe<&1, S.Sim & M.Machine>) -> String:
  match r:
    case None{}:
      "out of fuel"
    case Some{(+s, m)}:
      effects(s) ++ " | buf " ++ show_bytes(S.Sim.read(s, w(16384), 5))

# CPU_ON cpu 1 twice, AFFINITY_INFO, then cpu 1 calls CPU_OFF and
# AFFINITY_INFO again.
def psci() -> List<Ev>:
  [At{0, hvc(3288334339, 1, 1073741824, 7)}, At{0, hvc(3288334339, 1, 1073741824, 7)}, At{0, hvc(3288334340, 1, 0, 0)}, At{1, hvc(2214592514, 0, 0, 0)}, At{0, hvc(3288334340, 1, 0, 0)}]

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("machine seq uart rx irq", seq(S.Sim.new(w(1073741824), 64n), [D.RngKind{}, D.BlkKind{0, w(8)}], uart()), "[x1=0x2, x1=0x0, x1=0x69, x1=0x68, x1=0x80] | pc+7 | [33] | [33:0, 33:1] | [] | log 0")
    T.eq_str("machine seq rx overflow", seq(S.Sim.new(w(1073741824), 64n), [], overflow()), "[x1=0xc0] | pc+1 | [] | [] | [] | log 0")
    T.eq_str("machine seq virtio probe", probed(trace(probe(), Some{(mem(), M.Machine.new(1n, [D.RngKind{}]))})), "[x1=0x1, x1=0x4, x1=0x74726976] | pc+23 | [] | [48:0, 48:1] | [] | log 0 | buf [0, 1, 2, 3, 0]")
    T.eq_str("machine seq psci", seq(S.Sim.new(w(1073741824), 64n), [], psci()), "[x0=0x1, x0=0x0, x0=0x0, x0=0xfffffffffffffffc, x0=0x0] | pc+0 | [] | [] | [] | log 0")
    T.eq_str("machine mrs", run(0, exc(1644167265, 0, 0, 0, 0, 0, 0)), "run | [x3=0x0] | pc+1 | [] | [] | [] | log 1")
    T.eq_str("machine msr", run(0, exc(1644167264, 0, 0, 0, 0, 0, 0)), "run | [] | pc+1 | [] | [] | [] | log 1")
    T.eq_str("machine unknown mmio store", run(0, store(184549376, 7)), "run | [] | pc+1 | [] | [] | [] | log 1")
    T.eq_str("machine load to xzr", run(0, exc(2476670976, 150994968, 0, 0, 0, 0, 0)), "run | [] | pc+1 | [] | [] | [] | log 0")
    T.eq_str("machine no isv", run(0, exc(2449473536, 167772160, 0, 0, 0, 0, 0)), "stop 2 | [] | pc+0 | [] | [] | [] | log 1")
    T.eq_str("machine insn abort", run(0, exc(2147483648, 0, 0, 0, 0, 0, 0)), "stop 3 | [] | pc+0 | [] | [] | [] | log 1")
    T.eq_str("machine other class", run(0, exc(0, 0, 0, 0, 0, 0, 0)), "stop 4 | [] | pc+0 | [] | [] | [] | log 1")
    T.eq_str("machine system reset", run(0, hvc(2214592521, 0, 0, 0)), "stop 1 | [x0=0x0] | pc+0 | [] | [] | [reset] | log 0")
    T.eq_str("machine cpu off", run(0, hvc(2214592514, 0, 0, 0)), "cpu-stop | [x0=0x0] | pc+0 | [] | [] | [] | log 0")
    T.eq_str("machine canceled", run(0, V.Canceled{}), "run | [] | pc+0 | [] | [] | [] | log 0")
    T.eq_str("machine unknown exit", run(0, V.UnknownExit{9}), "stop 5 | [] | pc+0 | [] | [] | [] | log 1")
