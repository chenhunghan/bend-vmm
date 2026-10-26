import Base

# The Arm PL031 real-time clock (Arm DDI 0224), so the guest knows the wall
# clock time. It sits at 0x0901_0000 (4 KiB), SPI 2 (INTID 34), like QEMU's
# "virt" machine. Registers (decimal; hex in comments):
#   DR 0 (0x000)  RO: the current time in seconds
#   MR 4 (0x004)  RW: match value
#   LR 8 (0x008)  RW: writing sets the current time (DR) to the value; reads
#                     the last value written
#   CR 12 (0x00C) RW: bit 0 starts the clock; it reads 1 (always running)
#   IMSC 16 (0x010) RW: bit 0 masks the alarm interrupt
#   RIS 20 (0x014) RO: bit 0 set once DR >= MR while MR != 0
#   MIS 24 (0x018) RO: RIS & IMSC
#   ICR 28 (0x01C) WO: writing 1 clears RIS (until the next match)
#   PeriphID0..3 at 4064..4076 read 49, 16, 20, 0 (0x31, 0x10, 0x14, 0x00);
#   PCellID0..3 at 4080..4092 read 13, 240, 5, 177.
# Unknown offsets read 0 and ignore writes. `now` is the host wall clock in
# seconds (low 32 bits); DR = now + offset (mod 2^32), and a write to LR sets
# offset = value - now.

type Pl031 is Data:
  Pl031{offset: U32, mr: U32, lr: U32, imsc: U32, ris: U32}

def Pl031.new() -> Pl031:
  Pl031{0, 0, 0, 0, 0}

def Pl031.read(s: Pl031, off: U32, now: U32) -> Pl031 & U32:
  ?TODO

def Pl031.write(s: Pl031, off: U32, v: U32, now: U32) -> Pl031:
  ?TODO

# The alarm line: MIS is non-zero at time now (a match latches RIS).
def Pl031.irq(s: Pl031, now: U32) -> Bool:
  ?TODO
