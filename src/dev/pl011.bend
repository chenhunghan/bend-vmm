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

# The reset state: CR 768 (0x300, TXE | RXE), IFLS 18 (0x12), the rest 0.
def Pl011.new() -> Pl011:
  ?TODO

# Reads a 32-bit register; returns the new state (a DR read pops the FIFO).
def Pl011.read(s: Pl011, off: U32) -> Pl011 & U32:
  ?TODO

# Writes a 32-bit register; returns the new state and the bytes to print.
# Writing ICR clears nothing that would stay asserted (RX/RT follow the FIFO,
# TX is always pending).
def Pl011.write(s: Pl011, off: U32, v: U32) -> Pl011 & +List<U32>:
  ?TODO

# Queues bytes typed on the host console, dropping those past the FIFO depth.
def Pl011.push_rx(s: Pl011, bytes: +List<U32>) -> Pl011:
  ?TODO

# The interrupt line's level: MIS (RIS & IMSC) is non-zero.
def Pl011.irq(s: Pl011) -> Bool:
  ?TODO
