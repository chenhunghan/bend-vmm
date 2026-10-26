import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/device.bend as D
import ../src/vmm/machine.bend as M
import ./t.bend as T

# FROZEN SPEC (architect-owned): single exits through Machine.on_exit on the
# simulator, one scenario per rule of src/vmm/machine.bend. Syndromes:
#   2474704960 str w1  (ISV, SAS 2, SRT 1, WnR)   2474704896 ldr w1 (SAS 2, SRT 1)
#   2468478976 ldrsb w2 (SAS 0, SSE, SRT 2)        1509949440 hvc #0
#   1509949445 hvc #5   1577058304 smc #0          100663296 wfi

def w(x: U32) -> U.U64:
  U.U64{0, x}

def z() -> U.U64:
  U.U64{0, 0}

def exc(esr: U32, ipa: U32, x0: U32, x1: U32, x2: U32, x3: U32, xt: U32) -> V.RawExit:
  V.Exception{w(esr), z(), w(ipa), w(x0), w(x1), w(x2), w(x3), w(xt)}

def machine() -> M.Machine:
  M.Machine.new(2n, [D.RngKind{}])

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

def show_cpu_on(c: S.CpuOn) -> String:
  match c:
    case S.CpuOn{n, e, x}:
      "cpu" ++ U32.show(n) ++ "@" ++ U.U64.show_hex(e) ++ "/" ++ U.U64.show_hex(x)

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

# What one exit did, as a line: control | regs | pc steps | console | irqs |
# power | cpu_on | log lines.
def summary(+s: S.Sim, step: M.Step) -> String:
  match step:
    case M.Step{m, c}:
      show_ctl(c) ++ " | " ++ List.show(~&2, ~S.SetReg, ~show_reg, S.Sim.regs(s)) ++ " | pc+" ++ Nat.show(S.Sim.pc_steps(s)) ++ " | " ++ show_bytes(S.Sim.console_out(s)) ++ " | " ++ List.show(~&2, ~S.Irq, ~show_irq, S.Sim.irqs(s)) ++ " | " ++ List.show(~&2, ~V.PowerOp, ~show_power, S.Sim.powers(s)) ++ " | " ++ List.show(~&2, ~S.CpuOn, ~show_cpu_on, S.Sim.cpu_ons(s)) ++ " | log " ++ Nat.show(List.length(&2, String, S.Sim.logs(s)))

def outcome(r: Maybe<&1, S.Sim & M.Step>) -> String:
  match r:
    case None{}:
      "out of fuel"
    case Some{(s, step)}:
      summary(s, step)

def run(e: V.RawExit) -> String:
  outcome(S.Sim.run(100000n, M.Step, S.Sim.new(w(1073741824), 64n), M.Machine.on_exit(0, machine(), e)))

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("machine uart store", run(exc(2474704960, 150994944, 0, 0, 0, 0, 65)), "run | [] | pc+1 | [65] | [] | [] | [] | log 0")
    T.eq_str("machine uart fr", run(exc(2474704896, 150994968, 0, 0, 0, 0, 0)), "run | [x1=0x90] | pc+1 | [] | [] | [] | [] | log 0")
    T.eq_str("machine uart irq", run(exc(2474704960, 150995000, 0, 0, 0, 0, 32)), "run | [] | pc+1 | [] | [33:1] | [] | [] | log 0")
    T.eq_str("machine ldrsb sign-extends", run(exc(2468478976, 150999028, 0, 0, 0, 0, 0)), "run | [x2=0xfffffff0] | pc+1 | [] | [] | [] | [] | log 0")
    T.eq_str("machine virtio magic", run(exc(2474704896, 167772160, 0, 0, 0, 0, 0)), "run | [x1=0x74726976] | pc+1 | [] | [] | [] | [] | log 0")
    T.eq_str("machine unknown mmio", run(exc(2474704896, 184549376, 0, 0, 0, 0, 0)), "run | [x1=0x0] | pc+1 | [] | [] | [] | [] | log 1")
    T.eq_str("machine psci version", run(exc(1509949440, 0, 2214592512, 0, 0, 0, 0)), "run | [x0=0x10001] | pc+0 | [] | [] | [] | [] | log 0")
    T.eq_str("machine smc version", run(exc(1577058304, 0, 2214592512, 0, 0, 0, 0)), "run | [x0=0x10001] | pc+1 | [] | [] | [] | [] | log 0")
    T.eq_str("machine hvc imm", run(exc(1509949445, 0, 2214592512, 0, 0, 0, 0)), "run | [x0=0xffffffffffffffff] | pc+0 | [] | [] | [] | [] | log 0")
    T.eq_str("machine system off", run(exc(1509949440, 0, 2214592520, 0, 0, 0, 0)), "stop 0 | [x0=0x0] | pc+0 | [] | [] | [off] | [] | log 0")
    T.eq_str("machine cpu on", run(exc(1509949440, 0, 3288334339, 1, 1073741824, 42, 0)), "run | [x0=0x0] | pc+0 | [] | [] | [] | [cpu1@0x40000000/0x2a] | log 0")
    T.eq_str("machine wfi", run(exc(100663296, 0, 0, 0, 0, 0, 0)), "idle | [] | pc+1 | [] | [] | [] | [] | log 0")
    T.eq_str("machine vtimer", run(V.VtimerActivated{}), "run | [] | pc+0 | [] | [] | [] | [] | log 0")
