import Base
import ../src/x86/pio.bend as P

# Spec for src/x86/pio.bend: the 16550A, the CMOS clock and the ports that
# power off and reset.

def value(r: P.URead) -> U32:
  match r:
    case P.URead{u, v}:
      v

def uart(r: P.UWrite) -> P.Uart:
  match r:
    case P.UWrite{u, o}:
      u

def out(r: P.UWrite) -> List<&2, U32>:
  match r:
    case P.UWrite{u, o}:
      o

law x86pio.lsr_empty:
  {value(P.Uart.read(P.Uart.new(), 5)) == 96 : U32}

law x86pio.thr_out:
  {out(P.Uart.write(P.Uart.new(), 0, 72)) == [72] : List<&2, U32>}

# with the divisor latch open, offset 0 is the divisor, not output
law x86pio.dlab_no_out:
  {out(P.Uart.write(uart(P.Uart.write(P.Uart.new(), 3, 128)), 0, 1)) == [] : List<&2, U32>}

law x86pio.iid_none:
  {P.Uart.iid(P.Uart.new()) == 1 : U32}

# enabling the transmit-empty interrupt raises it
law x86pio.thri_on_enable:
  {P.Uart.iid(uart(P.Uart.write(P.Uart.new(), 1, 2))) == 2 : U32}

# a received byte comes first, and needs its enable bit
law x86pio.rx_iid:
  {P.Uart.iid(uart(P.Uart.write(P.Uart.input(P.Uart.new(), [65]), 1, 1))) == 4 : U32}

law x86pio.rx_lsr:
  {value(P.Uart.read(P.Uart.input(P.Uart.new(), [65]), 5)) == 97 : U32}

law x86pio.rx_byte:
  {value(P.Uart.read(P.Uart.input(P.Uart.new(), [65]), 0)) == 65 : U32}

# loopback: RTS and OUT2 read back as CTS and DCD (the 8250 driver's test)
law x86pio.loop_msr:
  {P.Uart.msr(26) == 144 : U32}

law x86pio.msr:
  {P.Uart.msr(0) == 176 : U32}

law x86pio.room:
  {P.Uart.room(P.Uart.input(P.Uart.new(), [1, 2, 3])) == 61n : Nat}

# 2000-02-29 is day 11016 of the epoch
law x86pio.date_leap:
  {P.Cmos.date(11016) == P.Date{2000, 2, 29} : P.Date}

law x86pio.date_epoch:
  {P.Cmos.date(0) == P.Date{1970, 1, 1} : P.Date}

# 2026-11-16 13:07:09 UTC: hours 0x13, minutes 0x07, the year 0x26, a Monday
law x86pio.cmos_hour:
  {P.Cmos.reg(4, 1794834429) == 19 : U32}

law x86pio.cmos_minute:
  {P.Cmos.reg(2, 1794834429) == 7 : U32}

law x86pio.cmos_year:
  {P.Cmos.reg(9, 1794834429) == 38 : U32}

law x86pio.cmos_century:
  {P.Cmos.reg(50, 1794834429) == 32 : U32}

law x86pio.cmos_weekday:
  {P.Cmos.reg(6, 1794834429) == 2 : U32}

law x86pio.cmos_status_b:
  {P.Cmos.reg(11, 0) == 2 : U32}

law x86pio.cmos_valid:
  {P.Cmos.reg(13, 0) == 128 : U32}

law x86pio.bcd:
  {P.Cmos.bcd(59) == 89 : U32}

# SLP_EN | SLP_TYP 5 powers off; another sleep type does not
law x86pio.poweroff:
  {P.Pio.sleeps(52) == True{} : Bool}

law x86pio.no_s3:
  {P.Pio.sleeps(44) == False{} : Bool}

law x86pio.reset_acpi:
  {P.Pio.resets(1538, 1) == True{} : Bool}

law x86pio.reset_kbd:
  {P.Pio.resets(100, 254) == True{} : Bool}

law x86pio.reset_cf9:
  {P.Pio.resets(3321, 6) == True{} : Bool}

law x86pio.no_reset_cf9:
  {P.Pio.resets(3321, 2) == False{} : Bool}

law x86pio.ones:
  {P.Pio.ones(2) == 65535 : U32}

law x86pio.saved_new:
  {P.Pio.saved(P.Pio.new()) == [0, 0, 0, 0, 12, 0, 0, 0] : List<&2, U32>}

law x86pio.restored_roundtrip:
  {P.Pio.saved(P.Pio.restored([2, 3, 11, 0, 1, 0, 1, 13, 65])) == [2, 3, 11, 0, 1, 0, 1, 13, 65] : List<&2, U32>}

# a restore raises a transmit-empty interrupt where it is enabled
law x86pio.restored_thri:
  {P.Uart.iid(P.Uart.restored_uart(P.Pio.restored([2, 3, 11, 0, 1, 0, 0, 0]))) == 2 : U32}

law x86pio.restored_short:
  {P.Pio.saved(P.Pio.restored([1, 2])) == [0, 0, 0, 0, 12, 0, 0, 0] : List<&2, U32>}
