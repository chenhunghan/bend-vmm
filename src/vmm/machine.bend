import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../arm64/esr.bend as E
import ../arm64/psci.bend as P
import ../dev/pl011.bend as Uart
import ../virtio/device.bend as D
import ./layout.bend as L
import ./abi.bend as V

# The machine: every device model behind the MMIO bus, and the exit handler
# that turns one vCPU exit into a Vm program for the host.
#
# Bus: device 0 is the PL011 at L.Layout.uart_base() (4 KiB); device n+1 is
# virtio slot n at L.Layout.virtio_slot(n) (512 bytes), one per entry of devs.
#
# Machine.on_exit(cpu, m, exit), by exit:
#   Exception: decode with E.Trap.decode(esr, ipa, xt), then by trap:
#     Mmio read:  the device's 32-bit read at the offset; the value is masked
#                 to the access size, then, when sse is set, sign-extended from
#                 size*8 bits to 64 bits (sf) or 32 bits (not sf). It goes to
#                 register srt (VmSetReg) unless srt is 31. Then VmAdvancePc.
#     Mmio write: the device's write of the low 32 bits of value (UART output
#                 goes to VmConsole). Then VmAdvancePc.
#     Mmio at an address no device holds: reads give 0, writes are dropped,
#                 a VmLog line names the access; then VmAdvancePc. Run.
#     After any device access: for each interrupt line whose level changed,
#                 VmIrq(intid, level) (UART L.Layout.uart_intid(), slot n
#                 L.Layout.virtio_intid(n)) and the new level is recorded.
#     MmioNoIsv:  VmLog, Stop{2}.
#     Hvc{0}:     PSCI: P.Psci.decode(x0, x1, x2, x3) then P.Psci.handle(cpu,
#                 ...). VmSetReg(0, result x0). Effects: StartCpu -> VmCpuOn,
#                 Run; StopCpu -> CpuStop; Off -> VmPower(PowerOff),
#                 Stop{0}; Reset -> VmPower(PowerReset), Stop{1}; none ->
#                 Run. The trapped PC already points past an HVC.
#     Hvc{imm}, imm != 0: VmSetReg(0, NOT_SUPPORTED = 2^64 - 1). Run.
#     Smc{_}:     as Hvc{0}, then VmAdvancePc (an SMC trap returns to the SMC).
#     Wfx:        VmAdvancePc, Idle.
#     SysReg:     a read (MRS) sets register rt to 0 unless rt is 31; both
#                 directions VmLog the register; VmAdvancePc. Run.
#     InsnAbort:  VmLog, Stop{3}.
#     Other{ec}:  VmLog, Stop{4}.
#   VtimerActivated, Canceled: Run, no effects.
#   UnknownExit: VmLog, Stop{5}.

type Control is Data:
  Run{}
  # WFI/WFE: the vCPU may sleep until an interrupt or its timer.
  Idle{}
  # PSCI CPU_OFF: this vCPU stops; the VM goes on.
  CpuStop{}
  # The VM stops: 0 power off, 1 reset, 2.. an error the VMM cannot handle.
  Stop{code: U32}

type Machine is Data:
  Machine{psci: P.PsciState, uart: Uart.Pl011, uart_irq: Bool, devs: +List<D.Dev>, dev_irqs: +List<Bool>}

# One fresh device per kind, in slot order.
def Machine.devs(kinds: +List<D.DevKind>) -> +List<D.Dev>:
  match kinds:
    case Nil{}:
      []
    case k <> t:
      D.Dev.new(k) <> Machine.devs(t)

# One low interrupt line per kind.
def Machine.lows(kinds: +List<D.DevKind>) -> +List<Bool>:
  match kinds:
    case Nil{}:
      []
    case k <> t:
      False{} <> Machine.lows(t)

# ncpus CPUs (only CPU 0 on), a fresh UART, one virtio device per kind in
# slot order, every interrupt line low.
def Machine.new(ncpus: Nat, kinds: +List<D.DevKind>) -> Machine:
  # The devices and their lines are independent.
  +kinds = kinds
  devs lines = Machine.devs(kinds) Machine.lows(kinds)
  Machine{P.PsciState.boot(ncpus), Uart.Pl011.new(), False{}, devs, lines}

# The regions of virtio slots n, n+1, ... for the devices left.
def Machine.slots(devs: +List<D.Dev>, +n: U32) -> +List<L.Region>:
  match devs:
    case Nil{}:
      []
    case d <> t:
      L.Region{L.Layout.virtio_slot(n), U.U64{0, L.Layout.virtio_slot_size()}, (n + 1 : U32)} <> Machine.slots(t, (n + 1 : U32))

def Machine.bus(m: Machine) -> +List<L.Region>:
  match m:
    case Machine{p, u, ui, devs, lines}:
      L.Region{L.Layout.uart_base(), U.U64{0, 4096}, 0} <> Machine.slots(devs, 0)

# One handled exit: the machine after it and what the vCPU does next.
type Step is Data:
  Step{machine: Machine, control: Control}

# Interrupt lines

# The new level of a line; VmIrq when it differs from the old one.
def Machine.line(-R: Type, intid: U32, old: Bool, new: Bool) -> V.Op<R, Bool>:
  match old new:
    case True{} True{}:
      V.Op.pure(R, Bool, True{})
    case False{} False{}:
      V.Op.pure(R, Bool, False{})
    case True{} False{}:
      do V.Op<R, Bool>:
        V.Op.irq(R, intid, False{})
        return False{}
    case False{} True{}:
      do V.Op<R, Bool>:
        V.Op.irq(R, intid, True{})
        return True{}

# The lines of the virtio devices in slots n, n+1, ...; a device without a
# recorded level counts as low.
def Machine.dev_lines(-R: Type, devs: +List<D.Dev>, lines: +List<Bool>, +n: U32) -> V.Op<R, +List<Bool>>:
  match devs lines:
    case Nil{} _:
      V.Op.pure(R, +List<Bool>, [])
    case d <> t Nil{}:
      do V.Op<R, +List<Bool>>:
        l : Bool <- Machine.line(R, L.Layout.virtio_intid(n), False{}, D.Dev.irq(d))
        ls : +List<Bool> <- Machine.dev_lines(R, t, [], (n + 1 : U32))
        return l <> ls
    case d <> t old <> rest:
      do V.Op<R, +List<Bool>>:
        l : Bool <- Machine.line(R, L.Layout.virtio_intid(n), old, D.Dev.irq(d))
        ls : +List<Bool> <- Machine.dev_lines(R, t, rest, (n + 1 : U32))
        return l <> ls

# Raises or lowers every line whose level changed and records the new levels.
def Machine.irqs(-R: Type, m: Machine) -> V.Op<R, Machine>:
  match m:
    case Machine{p, +u, ui, +devs, lines}:
      do V.Op<R, Machine>:
        ui : Bool <- Machine.line(R, L.Layout.uart_intid(), ui, Uart.Pl011.irq(u))
        lines : +List<Bool> <- Machine.dev_lines(R, devs, lines, 0)
        return Machine{p, u, ui, devs, lines}

# Device access

def Machine.devs_read.head(t: +List<D.Dev>, r: D.Dev & U32) -> +List<D.Dev> & U32:
  match r:
    case (d, v):
      (d <> t, v)

def Machine.devs_read.tail(d: D.Dev, r: +List<D.Dev> & U32) -> +List<D.Dev> & U32:
  match r:
    case (t, v):
      (d <> t, v)

# The read of virtio device n of the list; 0 past its end.
def Machine.devs_read(devs: +List<D.Dev>, n: Nat, off: U32, size: U32) -> +List<D.Dev> & U32:
  match devs n:
    case Nil{} _:
      ([], 0)
    case d <> t 0n:
      Machine.devs_read.head(t, D.Dev.read(d, off, size))
    case d <> t 1n+i:
      Machine.devs_read.tail(d, Machine.devs_read(t, i, off, size))

# The write to virtio device n of the list; nothing past its end.
def Machine.devs_write(-R: Type, devs: +List<D.Dev>, n: Nat, off: U32, v: U32) -> V.Op<R, +List<D.Dev>>:
  match devs n:
    case Nil{} _:
      V.Op.pure(R, +List<D.Dev>, [])
    case d <> t 0n:
      do V.Op<R, +List<D.Dev>>:
        d : D.Dev <- D.Dev.write(R, d, off, v)
        return d <> t
    case d <> t 1n+i:
      do V.Op<R, +List<D.Dev>>:
        t : +List<D.Dev> <- Machine.devs_write(R, t, i, off, v)
        return d <> t

def Machine.uart_read(p: P.PsciState, ui: Bool, devs: +List<D.Dev>, lines: +List<Bool>, r: Uart.Pl011 & U32) -> Machine & U32:
  match r:
    case (u, v):
      (Machine{p, u, ui, devs, lines}, v)

def Machine.virtio_read(p: P.PsciState, u: Uart.Pl011, ui: Bool, lines: +List<Bool>, r: +List<D.Dev> & U32) -> Machine & U32:
  match r:
    case (devs, v):
      (Machine{p, u, ui, devs, lines}, v)

# The 32-bit read of bus device n (0 the UART, k+1 virtio slot k) at off.
def Machine.dev_read(n: Nat, m: Machine, off: U32, size: U32) -> Machine & U32:
  match n m:
    case 0n Machine{p, u, ui, devs, lines}:
      Machine.uart_read(p, ui, devs, lines, Uart.Pl011.read(u, off))
    case 1n+k Machine{p, u, ui, devs, lines}:
      Machine.virtio_read(p, u, ui, lines, Machine.devs_read(devs, k, off, size))

# Prints bytes on the console, when there are any.
def Machine.print(-R: Type, bs: +List<U32>) -> V.Op<R, Unit>:
  match bs:
    case Nil{}:
      V.Op.pure(R, Unit, Unit{})
    case h <> t:
      V.Op.console(R, h <> t)

def Machine.uart_write(-R: Type, p: P.PsciState, ui: Bool, devs: +List<D.Dev>, lines: +List<Bool>, r: Uart.Pl011 & +List<U32>) -> V.Op<R, Machine>:
  match r:
    case (u, bs):
      do V.Op<R, Machine>:
        Machine.print(R, bs)
        return Machine{p, u, ui, devs, lines}

# The 32-bit write of v to bus device n at off.
def Machine.dev_write(-R: Type, n: Nat, m: Machine, off: U32, v: U32) -> V.Op<R, Machine>:
  match n m:
    case 0n Machine{p, u, ui, devs, lines}:
      Machine.uart_write(R, p, ui, devs, lines, Uart.Pl011.write(u, off, v))
    case 1n+k Machine{p, u, ui, devs, lines}:
      do V.Op<R, Machine>:
        devs : +List<D.Dev> <- Machine.devs_write(R, devs, k, off, v)
        return Machine{p, u, ui, devs, lines}

# MMIO

# Sets register r unless it is 31 (XZR).
def Machine.put(-R: Type, xzr: Bool, r: U32, v: U.U64) -> V.Op<R, Unit>:
  match xzr:
    case True{}:
      V.Op.pure(R, Unit, Unit{})
    case False{}:
      V.Op.set_reg(R, r, v)

def Machine.put_reg(-R: Type, +r: U32, v: U.U64) -> V.Op<R, Unit>:
  Machine.put(R, U32.is_eq(r, 31), r, v)

# The bits of an access of size bytes, within 32 bits.
def Machine.mask(+size: U32) -> U32:
  Bool.pick(U32, U32.is_eq(size, 1), 255, Bool.pick(U32, U32.is_eq(size, 2), 65535, 4294967295))

# The loaded value: v masked to size bytes, then, when sse is set, sign-
# extended from size*8 bits to 64 bits (sf) or 32 bits (not sf).
def Machine.extend(+v: U32, +size: U32, sse: Bool, +sf: Bool) -> U.U64:
  +mask = Machine.mask(size)
  +top = (mask .^. (mask >> 1n) : U32)
  +neg = sse && U32.is_ne(size, 8) && U32.is_ne((v .&. top : U32), 0)
  +lo = (v .&. mask : U32)
  U.U64{Bool.pick(U32, neg && sf, 4294967295, 0), Bool.pick(U32, neg, (lo .|. U32.not(mask) : U32), lo)}

def Machine.access_name(write: Bool) -> String:
  match write:
    case True{}:
      "write"
    case False{}:
      "read"

# An access no device holds: reads give 0, writes are dropped.
def Machine.unmapped(write: Bool, m: Machine, ipa: U.U64, size: U32, +srt: U32) -> V.Op<Step, Step>:
  +write = write
  do V.Op<Step, Step>:
    V.Op.log(Step, "mmio: unmapped " ++ U32.show(size) ++ "-byte " ++ Machine.access_name(write) ++ " at " ++ U.U64.show_hex(ipa))
    Machine.put(Step, write || U32.is_eq(srt, 31), srt, U.U64{0, 0})
    V.Op.advance_pc(Step)
    return Step{m, Run{}}

# A device read has happened: the register, the lines, the PC.
def Machine.loaded(r: Machine & U32, +size: U32, srt: U32, sse: Bool, sf: Bool) -> V.Op<Step, Step>:
  match r:
    case (m, v):
      do V.Op<Step, Step>:
        Machine.put_reg(Step, srt, Machine.extend(v, size, sse, sf))
        m : Machine <- Machine.irqs(Step, m)
        V.Op.advance_pc(Step)
        return Step{m, Run{}}

def Machine.access(write: Bool, n: Nat, m: Machine, off: U32, size: U32, srt: U32, value: U.U64, sse: Bool, sf: Bool) -> V.Op<Step, Step>:
  match write:
    case True{}:
      do V.Op<Step, Step>:
        m : Machine <- Machine.dev_write(Step, n, m, off, U.U64.lo(value))
        m : Machine <- Machine.irqs(Step, m)
        V.Op.advance_pc(Step)
        return Step{m, Run{}}
    case False{}:
      +size = size
      Machine.loaded(Machine.dev_read(n, m, off, size), size, srt, sse, sf)

def Machine.route(hit: Maybe<&2, L.Hit>, m: Machine, ipa: U.U64, write: Bool, size: U32, srt: U32, value: U.U64, sse: Bool, sf: Bool) -> V.Op<Step, Step>:
  match hit:
    case None{}:
      Machine.unmapped(write, m, ipa, size, srt)
    case Some{L.Hit{dev, off}}:
      Machine.access(write, U32.to_nat(dev), m, U.U64.lo(off), size, srt, value, sse, sf)

def Machine.mmio(m: Machine, ipa: U.U64, write: Bool, size: U32, srt: U32, value: U.U64, sse: Bool, sf: Bool) -> V.Op<Step, Step>:
  +m = m
  +ipa = ipa
  Machine.route(L.Bus.find(Machine.bus(m), ipa), m, ipa, write, size, srt, value, sse, sf)

# PSCI

def Machine.psci.effect(e: P.PsciEffect, m: Machine) -> V.Op<Step, Step>:
  match e:
    case P.NoEffect{}:
      V.Op.pure(Step, Step, Step{m, Run{}})
    case P.StartCpu{cpu, entry, ctx}:
      do V.Op<Step, Step>:
        V.Op.cpu_on(Step, cpu, entry, ctx)
        return Step{m, Run{}}
    case P.StopCpu{}:
      V.Op.pure(Step, Step, Step{m, CpuStop{}})
    case P.Off{}:
      do V.Op<Step, Step>:
        V.Op.power(Step, V.PowerOff{})
        return Step{m, Stop{0}}
    case P.Reset{}:
      do V.Op<Step, Step>:
        V.Op.power(Step, V.PowerReset{})
        return Step{m, Stop{1}}

def Machine.psci.fin(r: P.PsciResult, u: Uart.Pl011, ui: Bool, devs: +List<D.Dev>, lines: +List<Bool>) -> V.Op<Step, Step>:
  match r:
    case P.PsciResult{p, x0, e}:
      do V.Op<Step, Step>:
        V.Op.set_reg(Step, 0, x0)
        Machine.psci.effect(e, Machine{p, u, ui, devs, lines})

# A PSCI call (HVC #0, or any SMC) from cpu.
def Machine.psci(cpu: U32, m: Machine, x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64) -> V.Op<Step, Step>:
  match m:
    case Machine{p, u, ui, devs, lines}:
      Machine.psci.fin(P.Psci.handle(cpu, p, P.Psci.decode(x0, x1, x2, x3)), u, ui, devs, lines)

def Machine.hvc(zero: Bool, cpu: U32, m: Machine, x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64) -> V.Op<Step, Step>:
  match zero:
    case True{}:
      Machine.psci(cpu, m, x0, x1, x2, x3)
    case False{}:
      do V.Op<Step, Step>:
        V.Op.set_reg(Step, 0, U.U64{4294967295, 4294967295})
        return Step{m, Run{}}

# Logs a line and stops the VM with code.
def Machine.fail(m: Machine, msg: String, code: U32) -> V.Op<Step, Step>:
  do V.Op<Step, Step>:
    V.Op.log(Step, msg)
    return Step{m, Stop{code}}

def Machine.trap(cpu: U32, m: Machine, t: E.Trap, x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64) -> V.Op<Step, Step>:
  match t:
    case E.Mmio{ipa, write, size, srt, value, sse, sf}:
      Machine.mmio(m, ipa, write, size, srt, value, sse, sf)
    case E.MmioNoIsv{ipa}:
      Machine.fail(m, "mmio: data abort without a valid syndrome at " ++ U.U64.show_hex(ipa), 2)
    case E.Hvc{+imm}:
      Machine.hvc(U32.is_eq(imm, 0), cpu, m, x0, x1, x2, x3)
    case E.Smc{imm}:
      do V.Op<Step, Step>:
        s : Step <- Machine.psci(cpu, m, x0, x1, x2, x3)
        V.Op.advance_pc(Step)
        return s
    case E.Wfx{wfe}:
      do V.Op<Step, Step>:
        V.Op.advance_pc(Step)
        return Step{m, Idle{}}
    case E.SysReg{op0, op1, crn, crm, op2, +rt, +read}:
      do V.Op<Step, Step>:
        V.Op.log(Step, "sysreg: " ++ Machine.access_name(Bool.not(read)) ++ " of S" ++ U32.show(op0) ++ "_" ++ U32.show(op1) ++ "_C" ++ U32.show(crn) ++ "_C" ++ U32.show(crm) ++ "_" ++ U32.show(op2) ++ " ignored")
        Machine.put(Step, Bool.not(read) || U32.is_eq(rt, 31), rt, U.U64{0, 0})
        V.Op.advance_pc(Step)
        return Step{m, Run{}}
    case E.InsnAbort{ipa}:
      Machine.fail(m, "instruction abort at " ++ U.U64.show_hex(ipa), 3)
    case E.Other{ec}:
      Machine.fail(m, "unhandled exception class " ++ U32.show(ec), 4)

def Machine.on_exit(cpu: U32, m: Machine, e: V.RawExit) -> V.Vm<Step>:
  match e:
    case V.Exception{esr, far, ipa, x0, x1, x2, x3, xt}:
      V.Op.finish(Step, Machine.trap(cpu, m, E.Trap.decode(esr, ipa, xt), x0, x1, x2, x3))
    case V.VtimerActivated{}:
      V.VmRet{Step{m, Run{}}}
    case V.Canceled{}:
      V.VmRet{Step{m, Run{}}}
    case V.UnknownExit{reason}:
      V.VmLog{"unknown exit reason " ++ U32.show(reason), V.VmRet{Step{m, Stop{5}}}}

# Bytes typed on the host console: queued in the UART (Uart.Pl011.push_rx),
# then the UART interrupt line is updated as after a device access.
def Machine.input(m: Machine, bytes: +List<U32>) -> V.Vm<Machine>:
  match m:
    case Machine{p, u, ui, devs, lines}:
      V.Op.finish(Machine, Machine.irqs(Machine, Machine{p, Uart.Pl011.push_rx(u, bytes), ui, devs, lines}))
