import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ../vmm/layout.bend as L
import ../vmm/machine.bend as M
import ./acpi.bend as A

# The x86 guest's port IO: the devices behind IN and OUT (KVM_EXIT_IO).
# KVM itself answers the PIC (32, 33, 160, 161), the PIT (64..67, 97) and
# the ELCR; everything else comes here:
#   1016..1023 (0x3F8..0x3FF)  COM1, a 16550A UART: its output goes to the
#                              console, the console's input to its receive
#                              FIFO; its interrupt line is the machine's
#                              L.Layout.uart_intid() (IOAPIC pin 4, X86.gsi_at)
#   112, 113 (0x70, 0x71)      the CMOS clock (MC146818): index, data
#   1536..1538 (0x600..0x602)  ACPI sleep control, sleep status, reset
#                              (src/x86/acpi.bend)
#   100 (0x64)                 the keyboard controller: 254 (0xFE) resets
#   3321 (0xCF9)               the reset control register: bit 2 resets
# Anything else reads as all ones (no device: the PCI configuration ports
# too, so the guest finds no PCI) and ignores writes.

# The 16550A: interrupt enable, line control, modem control, scratch, the
# divisor latch, FIFO control, the transmit-empty interrupt pending, the
# receive FIFO (at most 64 bytes), and the interrupt line's level.
type Uart is Data:
  Uart{ier: U32, lcr: U32, mcr: U32, scr: U32, dll: U32, dlm: U32, fcr: U32, thri: Bool, rx: +List<U32>, line: Bool}

# The port machine: the UART, the CMOS index register.
type Pio is Data:
  Pio{uart: Uart, cmos: U32}

# The machine after a port access, and what the vCPU does next.
type XStep is Data:
  XStep{pio: Pio, control: M.Control}

def Uart.new() -> Uart:
  Uart{0, 0, 0, 0, 12, 0, 0, False{}, [], False{}}

def Pio.new() -> Pio:
  Pio{Uart.new(), 0}

def Uart.fifo() -> Nat:
  64n

def Uart.base() -> U32:
  1016

# Bit helpers.
def Pio.bit(+v: U32, +b: U32) -> Bool:
  U32.is_ne((v .&. b : U32), 0)

# The interrupt identification: 0xC0 when the FIFOs are on, then received
# data (4) before transmit empty (2); 1 when nothing is pending.
def Uart.iid(u: Uart) -> U32:
  match u:
    case Uart{+ier, lcr, mcr, scr, dll, dlm, +fcr, thri, +rx, line}:
      +fifo = Bool.pick(U32, Pio.bit(fcr, 1), 192, 0)
      +rda = Pio.bit(ier, 1) && Bool.not(List.is_empty(&2, U32, rx))
      +thre = Pio.bit(ier, 2) && thri
      (fifo .|. Bool.pick(U32, rda, 4, Bool.pick(U32, thre, 2, 1)) : U32)

# The line: an interrupt pending and OUT2 (MCR bit 3) set, as on a PC.
def Uart.level(+u: Uart) -> Bool:
  match u:
    case Uart{ier, lcr, +mcr, scr, dll, dlm, fcr, thri, rx, line}:
      U32.is_ne((Uart.iid(u) .&. 1 : U32), 1) && Pio.bit(mcr, 8)

def Uart.with_line(u: Uart, +l: Bool) -> Uart:
  match u:
    case Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}:
      Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, l}

def Uart.line(u: Uart) -> Bool:
  match u:
    case Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}:
      line

def Pio.irq_if(-R: Type, change: Bool, level: Bool) -> V.Op<R, Unit>:
  match change:
    case True{}:
      V.Op.irq(R, L.Layout.uart_intid(), level)
    case False{}:
      V.Op.pure(R, Unit, Unit{})

# Sets the line to the UART's level, raising or lowering it when it changed.
def Uart.sync(-R: Type, +u: Uart) -> V.Op<R, Uart>:
  +now = Uart.level(u)
  do V.Op<R, Uart>:
    Pio.irq_if(R, Bool.xor(now, Uart.line(u)), now)
    return Uart.with_line(u, now)

# The modem status: in loopback (MCR bit 4) the outputs fed back (RTS to
# CTS, DTR to DSR, OUT1 to RI, OUT2 to DCD), else carrier, ready, clear to
# send (0xB0).
def Uart.msr(+mcr: U32) -> U32:
  +loop = (((((mcr .&. 2 : U32) << 3n : U32) .|. ((mcr .&. 1 : U32) << 5n : U32) : U32) .|. ((mcr .&. 4 : U32) << 4n : U32) : U32) .|. ((mcr .&. 8 : U32) << 4n : U32) : U32)
  Bool.pick(U32, Pio.bit(mcr, 16), loop, 176)

# A read of register off (0..7): the value, and the UART after it.
type URead is Data:
  URead{uart: Uart, value: U32}

def Uart.read(u: Uart, +off: U32) -> URead:
  match u:
    case Uart{+ier, +lcr, +mcr, +scr, +dll, +dlm, +fcr, +thri, +rx, +line}:
      +dlab = Pio.bit(lcr, 128)
      +iid = Uart.iid(Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line})
      +rbr = Maybe.default(&2, U32, List.head(&2, U32, rx), 0)
      +rest = List.drop(&2, U32, rx, 1n)
      +same : Uart = Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}
      +lsr = (96 .|. Bool.pick(U32, List.is_empty(&2, U32, rx), 0, 1) : U32)
      Bool.pick(URead, U32.is_eq(off, 0),
        Bool.pick(URead, dlab, URead{same, dll}, URead{Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rest, line}, rbr}),
      Bool.pick(URead, U32.is_eq(off, 1), URead{same, Bool.pick(U32, dlab, dlm, ier)},
      Bool.pick(URead, U32.is_eq(off, 2), URead{Uart{ier, lcr, mcr, scr, dll, dlm, fcr, Bool.pick(Bool, U32.is_eq((iid .&. 15 : U32), 2), False{}, thri), rx, line}, iid},
      Bool.pick(URead, U32.is_eq(off, 3), URead{same, lcr},
      Bool.pick(URead, U32.is_eq(off, 4), URead{same, mcr},
      Bool.pick(URead, U32.is_eq(off, 5), URead{same, lsr},
      Bool.pick(URead, U32.is_eq(off, 6), URead{same, Uart.msr(mcr)}, URead{same, scr})))))))

# What a write does: the UART after it, and the byte transmitted (THR)
# when there is one.
type UWrite is Data:
  UWrite{uart: Uart, out: +List<U32>}

def Uart.push(+rx: +List<U32>, +bs: +List<U32>) -> +List<U32>:
  List.take(&2, U32, List.append(&2, U32, rx, bs), Uart.fifo())

def Uart.write(u: Uart, +off: U32, +v: U32) -> UWrite:
  match u:
    case Uart{+ier, +lcr, +mcr, +scr, +dll, +dlm, +fcr, +thri, +rx, +line}:
      +dlab = Pio.bit(lcr, 128)
      +b = (v .&. 255 : U32)
      +loop = Pio.bit(mcr, 16)
      +same : Uart = Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}
      # THR: transmitted at once, so the holding register is empty again
      +thr : UWrite = UWrite{Uart{ier, lcr, mcr, scr, dll, dlm, fcr, True{}, Bool.pick(+List<U32>, loop, Uart.push(rx, [b]), rx), line}, Bool.pick(+List<U32>, loop, [], [b])}
      # IER: enabling the transmit-empty interrupt raises it (the register
      # is always empty)
      +ier2 = (b .&. 15 : U32)
      +thri2 = Bool.pick(Bool, Pio.bit(ier2, 2) && Bool.not(Pio.bit(ier, 2)), True{}, thri)
      # FCR: bit 1 clears the receive FIFO
      +rx2 = Bool.pick(+List<U32>, Pio.bit(b, 2), [], rx)
      Bool.pick(UWrite, U32.is_eq(off, 0),
        Bool.pick(UWrite, dlab, UWrite{Uart{ier, lcr, mcr, scr, b, dlm, fcr, thri, rx, line}, []}, thr),
      Bool.pick(UWrite, U32.is_eq(off, 1),
        Bool.pick(UWrite, dlab, UWrite{Uart{ier, lcr, mcr, scr, dll, b, fcr, thri, rx, line}, []}, UWrite{Uart{ier2, lcr, mcr, scr, dll, dlm, fcr, thri2, rx, line}, []}),
      Bool.pick(UWrite, U32.is_eq(off, 2), UWrite{Uart{ier, lcr, mcr, scr, dll, dlm, (b .&. 1 : U32), thri, rx2, line}, []},
      Bool.pick(UWrite, U32.is_eq(off, 3), UWrite{Uart{ier, b, mcr, scr, dll, dlm, fcr, thri, rx, line}, []},
      Bool.pick(UWrite, U32.is_eq(off, 4), UWrite{Uart{ier, lcr, (b .&. 31 : U32), scr, dll, dlm, fcr, thri, rx, line}, []},
      Bool.pick(UWrite, U32.is_eq(off, 7), UWrite{Uart{ier, lcr, mcr, b, dll, dlm, fcr, thri, rx, line}, []}, UWrite{same, []}))))))

# Console input: queued in the receive FIFO (what does not fit is dropped,
# as by the hardware).
def Uart.input(u: Uart, +bs: +List<U32>) -> Uart:
  match u:
    case Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}:
      Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, Uart.push(rx, bs), line}

def Uart.room(u: Uart) -> Nat:
  match u:
    case Uart{ier, lcr, mcr, scr, dll, dlm, fcr, thri, rx, line}:
      Nat.sub(Uart.fifo(), List.length(&2, U32, rx))

# The CMOS clock from the host's wall clock (seconds since the epoch, the
# low 32 bits: good to 2106), in BCD 24-hour mode (status B 2: x86 Linux
# reads the clock as BCD whatever status B says, RTC_ALWAYS_BCD); each
# date and time register below holds its value in BCD:
#   0 seconds, 2 minutes, 4 hours, 6 the day of the week (1 Sunday), 7 the
#   day, 8 the month, 9 the year in the century, 50 (0x32) the century,
#   10 status A (38: no update in progress), 11 status B (2), 13 status D
#   (128: the battery is good); every other register reads 0.
# Civil dates from days since 1970-01-01 (H. Hinnant's days_from_civil
# inverse, all in unsigned arithmetic).
type Date is Data:
  Date{year: U32, month: U32, day: U32}

def Cmos.date(+days: U32) -> Date:
  +z = (days + 719468 : U32)
  +era = (z / 146097 : U32)
  +doe = (z - (era * 146097 : U32) : U32)
  +yoe = ((((doe - (doe / 1460 : U32) : U32) + (doe / 36524 : U32) : U32) - (doe / 146096 : U32) : U32) / 365 : U32)
  +doy = (doe - ((((365 * yoe : U32) + (yoe / 4 : U32) : U32) - (yoe / 100 : U32)) : U32) : U32)
  +mp = ((((5 * doy : U32) + 2 : U32)) / 153 : U32)
  +d = ((doy - ((((153 * mp : U32) + 2 : U32)) / 5 : U32) : U32) + 1 : U32)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), (mp + 3 : U32), (mp - 9 : U32))
  +y = ((yoe + (era * 400 : U32) : U32) + Bool.pick(U32, U32.is_le(m, 2), 1, 0) : U32)
  Date{y, m, d}

# Two decimal digits as BCD.
def Cmos.bcd(+v: U32) -> U32:
  (((v / 10 : U32) << 4n : U32) .|. (v % 10 : U32) : U32)

def Cmos.reg.at(+idx: U32, +days: U32, +tod: U32, date: Date) -> U32:
  match date:
    case Date{+y, +mo, +d}:
      Bool.pick(U32, U32.is_eq(idx, 0), Cmos.bcd((tod % 60 : U32)),
      Bool.pick(U32, U32.is_eq(idx, 2), Cmos.bcd(((tod / 60 : U32) % 60 : U32)),
      Bool.pick(U32, U32.is_eq(idx, 4), Cmos.bcd((tod / 3600 : U32)),
      Bool.pick(U32, U32.is_eq(idx, 6), (((days + 4 : U32) % 7 : U32) + 1 : U32),
      Bool.pick(U32, U32.is_eq(idx, 7), Cmos.bcd(d),
      Bool.pick(U32, U32.is_eq(idx, 8), Cmos.bcd(mo),
      Bool.pick(U32, U32.is_eq(idx, 9), Cmos.bcd((y % 100 : U32)),
      Bool.pick(U32, U32.is_eq(idx, 50), Cmos.bcd((y / 100 : U32)),
      Bool.pick(U32, U32.is_eq(idx, 10), 38,
      Bool.pick(U32, U32.is_eq(idx, 11), 2,
      Bool.pick(U32, U32.is_eq(idx, 13), 128, 0)))))))))))

def Cmos.reg(+idx: U32, +secs: U32) -> U32:
  +days = (secs / 86400 : U32)
  +tod = (secs % 86400 : U32)
  Cmos.reg.at(idx, days, tod, Cmos.date(days))


# The value of an access of size bytes (1, 2 or 4) with no device: all ones.
def Pio.ones(+size: U32) -> U32:
  Bool.pick(U32, U32.is_eq(size, 1), 255, Bool.pick(U32, U32.is_eq(size, 2), 65535, 4294967295))

def Pio.in_uart(+port: U32) -> Bool:
  U32.is_ge(port, Uart.base()) && U32.is_lt(port, (Uart.base() + 8 : U32))

# A read answers in RAX (VmSetReg 0; KVM moves it to the IN's destination).
def Pio.answer(-R: Type, +v: U32) -> V.Op<R, Unit>:
  V.Op.set_reg(R, 0, U.U64{0, v})

def Pio.run(-R: Type, +p: Pio) -> V.Op<R, XStep>:
  V.Op.pure(R, XStep, XStep{p, M.Run{}})

def Pio.stop(-R: Type, +p: Pio, +code: U32) -> V.Op<R, XStep>:
  do V.Op<R, XStep>:
    V.Op.power(R, Bool.pick(V.PowerOp, U32.is_eq(code, 0), V.PowerOff{}, V.PowerReset{}))
    return XStep{p, M.Stop{code}}

def Pio.read.uart.fin(-R: Type, r: URead, +cmos: U32) -> V.Op<R, XStep>:
  match r:
    case URead{u2, +v}:
      do V.Op<R, XStep>:
        Pio.answer(R, v)
        u3 : Uart <- Uart.sync(R, u2)
        return XStep{Pio{u3, cmos}, M.Run{}}

def Pio.read.uart(-R: Type, +u: Uart, +cmos: U32, +off: U32) -> V.Op<R, XStep>:
  Pio.read.uart.fin(R, Uart.read(u, off), cmos)

def Pio.read.cmos(-R: Type, +p: Pio, +idx: U32) -> V.Op<R, XStep>:
  do V.Op<R, XStep>:
    +now : U.U64 <- V.Op.now(R)
    Pio.answer(R, Cmos.reg(idx, U.U64.lo(now)))
    return XStep{p, M.Run{}}

# IN of size bytes from port.
def Pio.read(-R: Type, p: Pio, +port: U32, +size: U32) -> V.Op<R, XStep>:
  match p:
    case Pio{+u, +cmos}:
      Bool.pick(V.Op<R, XStep>, Pio.in_uart(port), Pio.read.uart(R, u, cmos, (port - Uart.base() : U32)),
      Bool.pick(V.Op<R, XStep>, U32.is_eq(port, 113), Pio.read.cmos(R, Pio{u, cmos}, cmos),
      Bool.pick(V.Op<R, XStep>, U32.is_eq(port, 112), V.Op.bind(R, Unit, XStep, Pio.answer(R, cmos), x => Pio.run(R, Pio{u, cmos})),
      Bool.pick(V.Op<R, XStep>, U32.is_eq(port, A.Acpi.status_port()), V.Op.bind(R, Unit, XStep, Pio.answer(R, 0), x => Pio.run(R, Pio{u, cmos})),
        V.Op.bind(R, Unit, XStep, Pio.answer(R, Pio.ones(size)), x => Pio.run(R, Pio{u, cmos}))))))

def Pio.console(-R: Type, +out: +List<U32>) -> V.Op<R, Unit>:
  Bool.pick(V.Op<R, Unit>, List.is_empty(&2, U32, out), V.Op.pure(R, Unit, Unit{}), V.Op.console(R, out))

def Pio.write.uart.fin(-R: Type, w: UWrite, +cmos: U32) -> V.Op<R, XStep>:
  match w:
    case UWrite{u2, +out}:
      do V.Op<R, XStep>:
        Pio.console(R, out)
        u3 : Uart <- Uart.sync(R, u2)
        return XStep{Pio{u3, cmos}, M.Run{}}

def Pio.write.uart(-R: Type, +u: Uart, +cmos: U32, +off: U32, +v: U32) -> V.Op<R, XStep>:
  Pio.write.uart.fin(R, Uart.write(u, off, v), cmos)

# Power off: SLP_EN with SLP_TYP 5 (\_S5) in the sleep control register.
def Pio.sleeps(+v: U32) -> Bool:
  Pio.bit(v, 32) && U32.is_eq(((v >> 2n : U32) .&. 7 : U32), A.Acpi.s5())

def Pio.resets(+port: U32, +v: U32) -> Bool:
  (U32.is_eq(port, A.Acpi.reset_port()) && U32.is_eq(v, A.Acpi.reset_value()))
    || (U32.is_eq(port, 100) && U32.is_eq(v, 254))
    || (U32.is_eq(port, 3321) && Pio.bit(v, 4))

# OUT of size bytes of v to port.
def Pio.write(-R: Type, p: Pio, +port: U32, +size: U32, +v: U32) -> V.Op<R, XStep>:
  match p:
    case Pio{+u, +cmos}:
      Bool.pick(V.Op<R, XStep>, Pio.in_uart(port), Pio.write.uart(R, u, cmos, (port - Uart.base() : U32), v),
      Bool.pick(V.Op<R, XStep>, U32.is_eq(port, 112), Pio.run(R, Pio{u, (v .&. 127 : U32)}),
      Bool.pick(V.Op<R, XStep>, U32.is_eq(port, A.Acpi.sleep_port()) && Pio.sleeps(v), Pio.stop(R, Pio{u, cmos}, 0),
      Bool.pick(V.Op<R, XStep>, Pio.resets(port, v), Pio.stop(R, Pio{u, cmos}, 1), Pio.run(R, Pio{u, cmos})))))

# One port access: a write of v, or a read answered in RAX.
def Pio.io(-R: Type, p: Pio, write: Bool, +port: U32, +size: U32, +v: U32) -> V.Op<R, XStep>:
  match write:
    case True{}:
      Pio.write(R, p, port, size, v)
    case False{}:
      Pio.read(R, p, port, size)

# The port machine's program for one access (an exit).
def Pio.on_io(p: Pio, write: Bool, port: U32, size: U32, v: U32) -> V.Vm<XStep>:
  V.Op.finish(XStep, Pio.io(XStep, p, write, port, size, v))

# Console input: into the receive FIFO, then the line.
def Pio.input.go(-R: Type, p: Pio, +bs: +List<U32>) -> V.Op<R, Pio>:
  match p:
    case Pio{u, +cmos}:
      do V.Op<R, Pio>:
        u2 : Uart <- Uart.sync(R, Uart.input(u, bs))
        return Pio{u2, cmos}

def Pio.input(p: Pio, bs: +List<U32>) -> V.Vm<Pio>:
  V.Op.finish(Pio, Pio.input.go(Pio, p, bs))

def Pio.room(p: Pio) -> Nat:
  match p:
    case Pio{u, cmos}:
      Uart.room(u)
