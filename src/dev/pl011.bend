import Base

# The Arm PL011 UART (Arm DDI 0183), the guest's serial console. Register
# offsets (decimal; hex in comments):
#   DR 0 (0x000)  RSR/ECR 4 (0x004)  FR 24 (0x018)  ILPR 32 (0x020)
#   IBRD 36 (0x024)  FBRD 40 (0x028)  LCR_H 44 (0x02C)  CR 48 (0x030)
#   IFLS 52 (0x034)  IMSC 56 (0x038)  RIS 60 (0x03C)  MIS 64 (0x040)
#   ICR 68 (0x044)  DMACR 72 (0x048)
#   PeriphID0..3 at 4064, 4068, 4072, 4076 (0xFE0..0xFEC) read 17, 16, 20, 0
#   (0x11, 0x10, 0x14, 0x00); PCellID0..3 at 4080..4092 (0xFF0..0xFFC) read
#   13, 240, 5, 177 (0x0D, 0xF0, 0x05, 0xB1).
# FR bits: BUSY 8 (bit 3), RXFE 16 (bit 4), TXFF 32 (bit 5), RXFF 64 (bit 6),
# TXFE 128 (bit 7). Interrupt bits (IMSC/RIS/MIS/ICR): RX 16 (bit 4), TX 32
# (bit 5), RT 64 (bit 6).
# Transmission is instant: a DR write goes straight to the console, so the
# transmit FIFO is always empty and TX in RIS is always set. Received bytes
# queue in a FIFO of up to 32; RX and RT in RIS are set while it is non-empty.
# Unknown offsets read 0 and ignore writes.

type Pl011 is Data:
  Pl011{
    ibrd: U32,
    fbrd: U32,
    lcr_h: U32,
    cr: U32,
    ifls: U32,
    imsc: U32,
    rx: +List<U32>
  }

# x when b holds, else y.
def Pl011.pick(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

# A register write: the masked new value at offset k, else the old value.
def Pl011.set(+off: U32, k: U32, mask: U32, +v: U32, old: U32) -> U32:
  Pl011.pick(U32.is_eq(off, k), (v .&. mask : U32), old)

# FR: TXFE always (instant TX, never BUSY or TXFF), RXFE when the FIFO is
# empty, RXFF when it holds 32 bytes.
def Pl011.fr(rx: +List<U32>) -> U32:
  match rx:
    case Nil{}:
      144
    case h <> t:
      Pl011.pick(Nat.is_le(31n, List.length(&2, U32, t)), 192, 128)

# RIS: TX always; RX and RT while the FIFO is non-empty.
def Pl011.ris(rx: +List<U32>) -> U32:
  match rx:
    case Nil{}:
      32
    case h <> t:
      112

def Pl011.mis(+imsc: U32, rx: +List<U32>) -> U32:
  (Pl011.ris(rx) .&. imsc : U32)

# PeriphID0..3 and PCellID0..3; 0 elsewhere.
def Pl011.id(+off: U32) -> U32:
  Pl011.pick(U32.is_eq(off, 4064), 17,
  Pl011.pick(U32.is_eq(off, 4068), 16,
  Pl011.pick(U32.is_eq(off, 4072), 20,
  Pl011.pick(U32.is_eq(off, 4080), 13,
  Pl011.pick(U32.is_eq(off, 4084), 240,
  Pl011.pick(U32.is_eq(off, 4088), 5,
  Pl011.pick(U32.is_eq(off, 4092), 177, 0)))))))

# A side-effect-free register read (every register but DR). RSR/ECR, ILPR
# and DMACR read 0: no receive errors, no IrDA, no DMA.
def Pl011.peek(s: Pl011, +off: U32) -> U32:
  match s:
    case Pl011{i, f, l, c, fl, +m, +rx}:
      Pl011.pick(U32.is_eq(off, 24), Pl011.fr(rx),
      Pl011.pick(U32.is_eq(off, 36), i,
      Pl011.pick(U32.is_eq(off, 40), f,
      Pl011.pick(U32.is_eq(off, 44), l,
      Pl011.pick(U32.is_eq(off, 48), c,
      Pl011.pick(U32.is_eq(off, 52), fl,
      Pl011.pick(U32.is_eq(off, 56), m,
      Pl011.pick(U32.is_eq(off, 60), Pl011.ris(rx),
      Pl011.pick(U32.is_eq(off, 64), Pl011.mis(m, rx), Pl011.id(off))))))))))

# A DR read: pops the oldest byte; an empty FIFO reads 0 and keeps its state.
def Pl011.pop(s: Pl011) -> Pl011 & U32:
  match s:
    case Pl011{i, f, l, c, fl, m, rx}:
      match rx:
        case Nil{}:
          (Pl011{i, f, l, c, fl, m, []}, 0)
        case h <> t:
          (Pl011{i, f, l, c, fl, m, t}, (h .&. 255 : U32))

def Pl011.read.go(is_dr: Bool, s: Pl011, off: U32) -> Pl011 & U32:
  match is_dr:
    case True{}:
      Pl011.pop(s)
    case False{}:
      +s = s
      (s, Pl011.peek(s, off))

# The bytes a write prints: the low byte of a DR write, nothing elsewhere.
def Pl011.tx(is_dr: Bool, v: U32) -> +List<U32>:
  match is_dr:
    case True{}:
      [(v .&. 255 : U32)]
    case False{}:
      []

def Pl011.write.go(s: Pl011, +off: U32, +v: U32) -> Pl011 & +List<U32>:
  match s:
    case Pl011{i, f, l, c, fl, m, rx}:
      st : Pl011 = Pl011{
        Pl011.set(off, 36, 65535, v, i),
        Pl011.set(off, 40, 63, v, f),
        Pl011.set(off, 44, 255, v, l),
        Pl011.set(off, 48, 65535, v, c),
        Pl011.set(off, 52, 63, v, fl),
        Pl011.set(off, 56, 2047, v, m),
        rx
      }
      (st, Pl011.tx(U32.is_eq(off, 0), v))

# The reset state: CR 768 (0x300, TXE | RXE), IFLS 18 (0x12), the rest 0.
def Pl011.new() -> Pl011:
  Pl011{0, 0, 0, 768, 18, 0, []}

# Reads a 32-bit register; returns the new state (a DR read pops the FIFO).
def Pl011.read(s: Pl011, off: U32) -> Pl011 & U32:
  +off = off
  Pl011.read.go(U32.is_eq(off, 0), s, off)

# Writes a 32-bit register; returns the new state and the bytes to print.
# Writing ICR clears nothing that would stay asserted (RX/RT follow the FIFO,
# TX is always pending).
def Pl011.write(s: Pl011, off: U32, v: U32) -> Pl011 & +List<U32>:
  Pl011.write.go(s, off, v)

# Queues bytes typed on the host console, dropping those past the FIFO depth.
# The FIFO keeps its first max(32, |rx|) bytes of rx ++ bytes (a reachable
# state never holds more than 32, so that is 32).
def Pl011.push_rx(s: Pl011, bytes: +List<U32>) -> Pl011:
  match s:
    case Pl011{i, f, l, c, fl, m, +rx}:
      n = Nat.max(32n, List.length(&2, U32, rx))
      Pl011{i, f, l, c, fl, m, List.take(&2, U32, List.append(&2, U32, rx, bytes), n)}

# How many more bytes the receive FIFO takes.
def Pl011.room(s: Pl011) -> Nat:
  match s:
    case Pl011{i, f, l, c, fl, m, rx}:
      Nat.sub(32n, List.length(&2, U32, rx))

# The interrupt line's level: MIS (RIS & IMSC) is non-zero.
def Pl011.irq(s: Pl011) -> Bool:
  match s:
    case Pl011{i, f, l, c, fl, m, rx}:
      U32.is_ne(Pl011.mis(m, rx), 0)
