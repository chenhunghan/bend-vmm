import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/vmm/machine.bend as M
import ../src/x86/pio.bend as P
import ./t.bend as T

# Tests for src/x86/pio.bend, run on the simulator: each access's effects
# (console bytes, RAX answers, interrupt changes, power) and the state after.

type Acc is Data:
  Acc{write: Bool, port: U32, size: U32, value: U32}

def W(port: U32, v: U32) -> Acc:
  Acc{True{}, port, 1, v}

def R(port: U32) -> Acc:
  Acc{False{}, port, 1, 0}

type Run is Data:
  Run{sim: S.Sim, pio: P.Pio, stopped: U32}

def ctl_code(c: M.Control) -> U32:
  match c:
    case M.Stop{code}:
      code
    case _:
      99

def step.fin(r: Maybe<&1, S.Sim & P.XStep>, +old: Run) -> Run:
  match r:
    case None{}:
      old
    case Some{(s, P.XStep{p, c})}:
      Run{s, p, ctl_code(c)}

def step(r: Run, a: Acc) -> Run:
  match r a:
    case Run{+s, +p, st} Acc{w, port, size, v}:
      step.fin(S.Sim.run(1000n, P.XStep, s, P.Pio.on_io(p, w, port, size, v)), Run{s, p, st})

def steps.go(xs: +List<Acc>, r: Run) -> Run:
  match xs:
    case Nil{}:
      r
    case Con{a, rest}:
      steps.go(rest, step(r, a))

def steps(r: Run, xs: +List<Acc>) -> Run:
  steps.go(xs, r)

def start() -> Run:
  Run{S.Sim.new(U.U64.zero(), 0n), P.Pio.new(), 99}

def run(xs: +List<Acc>) -> Run:
  steps(start(), xs)

def at_now(+now: U32, xs: +List<Acc>) -> Run:
  steps(Run{S.Sim.with_now(S.Sim.new(U.U64.zero(), 0n), U.U64{0, now}), P.Pio.new(), 99}, xs)

def console(r: Run) -> String:
  match r:
    case Run{s, p, st}:
      List.show(~&2, ~U32, ~U32.show, S.Sim.console_out(s))

def reg_vals(rs: +List<S.SetReg>) -> +List<U32>:
  match rs:
    case Nil{}:
      []
    case Con{S.SetReg{r, v}, rest}:
      U.U64.lo(v) <> reg_vals(rest)

# The RAX answers, oldest first.
def answers(r: Run) -> String:
  match r:
    case Run{s, p, st}:
      List.show(~&2, ~U32, ~U32.show, List.reverse(&2, U32, reg_vals(S.Sim.regs(s))))

def irq_show(xs: +List<S.Irq>) -> +List<String>:
  match xs:
    case Nil{}:
      []
    case Con{S.Irq{i, l}, rest}:
      (U32.show(i) ++ ":" ++ Bool.show(l)) <> irq_show(rest)

def irqs(r: Run) -> String:
  match r:
    case Run{s, p, st}:
      String.join(List.reverse(&2, String, irq_show(S.Sim.irqs(s))), " ")

def stopped(r: Run) -> U32:
  match r:
    case Run{s, p, st}:
      st

def input.fin(r: Maybe<&1, S.Sim & P.Pio>, +old: Run) -> Run:
  match r:
    case None{}:
      old
    case Some{(s, p)}:
      match old:
        case Run{s0, p0, st}:
          Run{s, p, st}

def input(r: Run, bs: +List<U32>) -> Run:
  match r:
    case Run{+s, +p, st}:
      input.fin(S.Sim.run(1000n, P.Pio, s, P.Pio.input(p, bs)), Run{s, p, st})

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("thr to console", console(run([W(1016, 72), W(1016, 105)])), "[72, 105]")
    T.eq_str("lsr empty", answers(run([R(1021)])), "[96]")
    T.eq_str("divisor latch", answers(run([W(1019, 128), W(1016, 1), W(1017, 2), R(1016), R(1017), W(1019, 3), R(1019)])), "[1, 2, 3]")
    T.eq_str("dlab write is not output", console(run([W(1019, 128), W(1016, 1)])), "[]")
    T.eq_str("scratch", answers(run([W(1023, 165), R(1023)])), "[165]")
    T.eq_str("loopback msr", answers(run([W(1020, 26), R(1022)])), "[144]")
    T.eq_str("msr normal", answers(run([R(1022)])), "[176]")
    T.eq_str("loopback byte", answers(run([W(1020, 16), W(1016, 7), R(1021), R(1016), R(1021)])), "[97, 7, 96]")
    T.eq_str("fifo iir", answers(run([W(1018, 7), R(1018)])), "[193]")
    T.eq_str("thri raised", irqs(run([W(1020, 8), W(1017, 2)])), "33:True")
    T.eq_str("thri iir clears", answers(run([W(1020, 8), W(1017, 2), R(1018), R(1018)])), "[2, 1]")
    T.eq_str("thri lowered", irqs(run([W(1020, 8), W(1017, 2), R(1018)])), "33:True 33:False")
    T.eq_str("no out2 no line", irqs(run([W(1017, 2)])), "")
    T.eq_str("rx input", answers(steps(input(run([W(1020, 8), W(1017, 1)]), [65, 66]), [R(1021), R(1016), R(1016), R(1021)])), "[97, 65, 66, 96]")
    T.eq_str("rx line", irqs(steps(input(run([W(1020, 8), W(1017, 1)]), [65]), [R(1016)])), "33:True 33:False")
    T.eq_str("cmos 2026-11-16 13:07:09", answers(at_now(1794834429, [W(112, 0), R(113), W(112, 2), R(113), W(112, 4), R(113), W(112, 6), R(113), W(112, 7), R(113), W(112, 8), R(113), W(112, 9), R(113), W(112, 50), R(113), W(112, 11), R(113), W(112, 10), R(113)])), "[9, 7, 19, 2, 22, 17, 38, 32, 2, 38]")
    T.eq_str("cmos 2000-02-29", answers(at_now(951782400, [W(112, 7), R(113), W(112, 8), R(113), W(112, 9), R(113)])), "[41, 2, 0]")
    T.eq_str("cmos index nmi bit", answers(run([W(112, 141), R(112)])), "[13]")
    T.eq_u32("power off", stopped(run([W(1536, 52)])), 0)
    T.eq_u32("sleep s3 ignored", stopped(run([W(1536, 44)])), 99)
    T.eq_u32("acpi reset", stopped(run([W(1538, 1)])), 1)
    T.eq_u32("kbd reset", stopped(run([W(100, 254)])), 1)
    T.eq_u32("cf9 reset", stopped(run([W(3321, 6)])), 1)
    T.eq_u32("cf9 other", stopped(run([W(3321, 2)])), 99)
    T.eq_str("no device 16", answers(run([Acc{False{}, 3324, 2, 0}])), "[65535]")
    T.eq_str("no device 32", answers(run([Acc{False{}, 3320, 4, 0}])), "[4294967295]")
    T.eq_str("sleep status", answers(run([R(1537)])), "[0]")
