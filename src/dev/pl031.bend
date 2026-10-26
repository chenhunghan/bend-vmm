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

# The ris field holds the alarm latch: 0 armed (no match yet), 1 matched (RIS
# reads 1), 2 acknowledged through ICR (RIS reads 0; a write to MR or LR arms
# it again, so the next match latches it anew).

# x when b holds, else y.
def Pl031.pick(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

# The latch after time reaches dr: an armed alarm matches once dr >= mr while
# mr != 0; a matched or acknowledged one stays as it is.
def Pl031.latch(+r: U32, +mr: U32, dr: U32) -> U32:
  hit = U32.is_eq(r, 0) && U32.is_ne(mr, 0) && U32.is_ge(dr, mr)
  Pl031.pick(hit, 1, r)

# The state at host time now: the alarm latched if DR has reached MR.
def Pl031.sync(s: Pl031, +now: U32) -> Pl031:
  match s:
    case Pl031{+o, +m, lr, imsc, r}:
      Pl031{o, m, lr, imsc, Pl031.latch(r, m, (now + o : U32))}

# RIS bit 0 of a latch.
def Pl031.ris(r: U32) -> U32:
  Pl031.pick(U32.is_eq(r, 1), 1, 0)

# A write to MR or LR arms an acknowledged alarm again.
def Pl031.rearm(+r: U32) -> U32:
  Pl031.pick(U32.is_eq(r, 2), 0, r)

# ICR: bit 0 acknowledges a matched alarm; an armed one stays armed.
def Pl031.ack(+r: U32, v: U32) -> U32:
  Pl031.pick(U32.is_eq(r, 1) && U32.is_eq((v .&. 1 : U32), 1), 2, r)

# A register write: v at offset k, else the old value.
def Pl031.set(+off: U32, k: U32, v: U32, old: U32) -> U32:
  Pl031.pick(U32.is_eq(off, k), v, old)

# PeriphID0..3 and PCellID0..3; 0 elsewhere.
def Pl031.id(+off: U32) -> U32:
  Pl031.pick(U32.is_eq(off, 4064), 49,
  Pl031.pick(U32.is_eq(off, 4068), 16,
  Pl031.pick(U32.is_eq(off, 4072), 20,
  Pl031.pick(U32.is_eq(off, 4080), 13,
  Pl031.pick(U32.is_eq(off, 4084), 240,
  Pl031.pick(U32.is_eq(off, 4088), 5,
  Pl031.pick(U32.is_eq(off, 4092), 177, 0)))))))

# A register read of a synced state.
def Pl031.peek(s: Pl031, +off: U32, now: U32) -> U32:
  match s:
    case Pl031{o, m, lr, +imsc, +r}:
      Pl031.pick(U32.is_eq(off, 0), (now + o : U32),
      Pl031.pick(U32.is_eq(off, 4), m,
      Pl031.pick(U32.is_eq(off, 8), lr,
      Pl031.pick(U32.is_eq(off, 12), 1,
      Pl031.pick(U32.is_eq(off, 16), imsc,
      Pl031.pick(U32.is_eq(off, 20), Pl031.ris(r),
      Pl031.pick(U32.is_eq(off, 24), (Pl031.ris(r) .&. imsc : U32), Pl031.id(off))))))))

# A register write to a synced state.
def Pl031.poke(s: Pl031, +off: U32, +v: U32, +now: U32) -> Pl031:
  match s:
    case Pl031{o, m, lr, imsc, +r}:
      mr_lr = U32.is_eq(off, 4) || U32.is_eq(off, 8)
      +r1 = Pl031.pick(mr_lr, Pl031.rearm(r), r)
      Pl031{
        Pl031.set(off, 8, (v - now : U32), o),
        Pl031.set(off, 4, v, m),
        Pl031.set(off, 8, v, lr),
        Pl031.set(off, 16, (v .&. 1 : U32), imsc),
        Pl031.pick(U32.is_eq(off, 28), Pl031.ack(r1, v), r1)
      }

def Pl031.read(s: Pl031, off: U32, now: U32) -> Pl031 & U32:
  +now = now
  +st = Pl031.sync(s, now)
  (st, Pl031.peek(st, off, now))

def Pl031.write(s: Pl031, off: U32, v: U32, now: U32) -> Pl031:
  +now = now
  Pl031.poke(Pl031.sync(s, now), off, v, now)

# The alarm line: MIS is non-zero at time now (a match latches RIS).
def Pl031.irq(s: Pl031, now: U32) -> Bool:
  match s:
    case Pl031{+o, +m, lr, imsc, r}:
      +ris = Pl031.ris(Pl031.latch(r, m, (now + o : U32)))
      U32.is_ne((ris .&. imsc : U32), 0)
