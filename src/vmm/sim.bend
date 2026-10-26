import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ./abi.bend as V

# A pure interpreter for Vm programs: the stand-in for the macOS host in
# tests and proofs. Guest memory is one flat region of bytes at `base`; every
# other effect is recorded so a test can assert on it.

type SetReg is Data:
  SetReg{reg: U32, value: U.U64}

type Irq is Data:
  Irq{intid: U32, level: Bool}

type CpuOn is Data:
  CpuOn{cpu: U32, entry: U.U64, ctx: U.U64}

# Recorded lists are newest first.
type Sim is Data:
  Sim{
    base: U.U64,
    mem: +List<U32>,
    console: +List<U32>,
    regs: +List<SetReg>,
    pc_steps: Nat,
    irqs: +List<Irq>,
    power: +List<V.PowerOp>,
    cpu_ons: +List<CpuOn>,
    log: +List<String>
  }

# A machine with size bytes of zeroed memory at base.
def Sim.new(base: U.U64, size: Nat) -> Sim:
  Sim{base, B.Bytes.zeros(size), [], [], 0n, [], [], [], []}

# The same, with memory initialised to the given bytes.
def Sim.with_mem(base: U.U64, mem: +List<U32>) -> Sim:
  Sim{base, mem, [], [], 0n, [], [], [], []}

# Offset of addr in the region; addresses below base wrap and read as absent.
def Sim.offset(+base: U.U64, addr: U.U64) -> Nat:
  U32.to_nat(U.U64.lo(U.U64.sub(addr, base)))

def Sim.read(s: Sim, addr: U.U64, len: U32) -> +List<U32>:
  match s:
    case Sim{+base, +mem, c, r, p, i, pw, co, l}:
      B.Bytes.slice(mem, Sim.offset(base, addr), U32.to_nat(len))

def Sim.splice(mem: +List<U32>, +off: Nat, +bs: +List<U32>) -> +List<U32>:
  +mem = mem
  head = List.take(&2, U32, mem, off)
  tail = List.drop(&2, U32, mem, Nat.add(off, List.length(&2, U32, bs)))
  List.append(&2, U32, head, List.append(&2, U32, bs, tail))

def Sim.write(s: Sim, addr: U.U64, bytes: +List<U32>) -> Sim:
  match s:
    case Sim{+base, mem, c, r, p, i, pw, co, l}:
      Sim{base, Sim.splice(mem, Sim.offset(base, addr), bytes), c, r, p, i, pw, co, l}

def Sim.set_reg(s: Sim, reg: U32, value: U.U64) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, SetReg{reg, value} <> r, p, i, pw, co, l}

def Sim.advance_pc(s: Sim) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, r, 1n+p, i, pw, co, l}

def Sim.console(s: Sim, bytes: +List<U32>) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, List.append(&2, U32, c, bytes), r, p, i, pw, co, l}

def Sim.irq(s: Sim, intid: U32, level: Bool) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, r, p, Irq{intid, level} <> i, pw, co, l}

def Sim.power(s: Sim, op: V.PowerOp) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, r, p, i, op <> pw, co, l}

def Sim.cpu_on(s: Sim, cpu: U32, entry: U.U64, ctx: U.U64) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, r, p, i, pw, CpuOn{cpu, entry, ctx} <> co, l}

def Sim.log(s: Sim, msg: String) -> Sim:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      Sim{b, m, c, r, p, i, pw, co, msg <> l}

# Runs a Vm program for at most fuel steps. None when the fuel runs out.
def Sim.run(fuel: Nat, -A: Type, s: Sim, m: V.Vm<A>) -> Maybe<&1, Sim & A>:
  match fuel:
    case 0n:
      None{}
    case 1n+f:
      match m:
        case V.VmRet{x}:
          Some{(s, x)}
        case V.VmRead{+a, n, k}:
          +s = s
          Sim.run(f, A, s, k(Sim.read(s, a, n)))
        case V.VmWrite{a, bs, next}:
          Sim.run(f, A, Sim.write(s, a, bs), next)
        case V.VmSetReg{r, v, next}:
          Sim.run(f, A, Sim.set_reg(s, r, v), next)
        case V.VmAdvancePc{next}:
          Sim.run(f, A, Sim.advance_pc(s), next)
        case V.VmConsole{bs, next}:
          Sim.run(f, A, Sim.console(s, bs), next)
        case V.VmIrq{i, l, next}:
          Sim.run(f, A, Sim.irq(s, i, l), next)
        case V.VmPower{op, next}:
          Sim.run(f, A, Sim.power(s, op), next)
        case V.VmCpuOn{c, e, x, next}:
          Sim.run(f, A, Sim.cpu_on(s, c, e, x), next)
        case V.VmLog{msg, next}:
          Sim.run(f, A, Sim.log(s, msg), next)

# Runs an Op to completion with a generous step budget.
def Sim.exec(-A: Type, s: Sim, m: V.Op<A, A>) -> Maybe<&1, Sim & A>:
  Sim.run(100000n, A, s, V.Op.finish(A, m))

def Sim.mem(s: Sim) -> +List<U32>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      m

def Sim.console_out(s: Sim) -> +List<U32>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      c

def Sim.regs(s: Sim) -> +List<SetReg>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      r

def Sim.pc_steps(s: Sim) -> Nat:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      p

def Sim.irqs(s: Sim) -> +List<Irq>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      i

def Sim.powers(s: Sim) -> +List<V.PowerOp>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      pw

def Sim.cpu_ons(s: Sim) -> +List<CpuOn>:
  match s:
    case Sim{b, m, c, r, p, i, pw, co, l}:
      co
