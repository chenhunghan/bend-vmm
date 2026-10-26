import Base
import ../src/dev/pl031.bend as R
import ./t.bend as T

# The PL031 RTC: setting and reading the time, the alarm (MR, IMSC, RIS, MIS,
# ICR) around a match, the ID block and unknown offsets.

def val_of(r: R.Pl031 & U32) -> U32:
  match r:
    case (s, v):
      v

def st_of(r: R.Pl031 & U32) -> R.Pl031:
  match r:
    case (s, v):
      s

def rd(s: R.Pl031, off: U32, now: U32) -> U32:
  val_of(R.Pl031.read(s, off, now))

def wr(s: R.Pl031, off: U32, v: U32, now: U32) -> R.Pl031:
  R.Pl031.write(s, off, v, now)

# MR 10 with the interrupt unmasked, set up at host time 0.
def armed() -> R.Pl031:
  wr(wr(R.Pl031.new(), 4, 10, 0), 16, 1, 0)

# armed(), its alarm acknowledged through ICR at host time 20.
def acked() -> R.Pl031:
  wr(armed(), 28, 1, 20)

def main() -> IO(Unit):
  do IO<Unit>:
    +s0 : R.Pl031 = R.Pl031.new()
    T.eq_u32("dr follows host", rd(s0, 0, 1700000000), 1700000000)
    T.eq_u32("dr ticks", rd(s0, 0, 1700000005), 1700000005)
    T.eq_u32("lr sets time", rd(wr(s0, 8, 100, 1000), 0, 1005), 105)
    T.eq_u32("lr sets time forward", rd(wr(s0, 8, 2000, 1000), 0, 1010), 2010)
    T.eq_u32("lr wraps", rd(wr(s0, 8, 4294967295, 0), 0, 2), 1)
    T.eq_u32("lr reads back", rd(wr(s0, 8, 100, 1000), 8, 3000), 100)
    T.eq_u32("lr reset", rd(s0, 8, 3000), 0)
    T.eq_u32("dr ignores writes", rd(wr(s0, 0, 5, 50), 0, 60), 60)
    T.eq_u32("second lr write", rd(wr(wr(s0, 8, 100, 0), 8, 7, 10), 0, 12), 9)
    T.eq_u32("read keeps time", rd(st_of(R.Pl031.read(wr(s0, 8, 100, 0), 0, 3)), 0, 4), 104)
    T.eq_u32("cr reads 1", rd(s0, 12, 0), 1)
    T.eq_u32("cr ignores writes", rd(wr(s0, 12, 0, 0), 12, 0), 1)
    T.eq_u32("mr reset", rd(s0, 4, 0), 0)
    T.eq_u32("mr roundtrip", rd(wr(s0, 4, 77, 0), 4, 0), 77)
    T.eq_u32("imsc reset", rd(s0, 16, 0), 0)
    T.eq_u32("imsc bit 0", rd(wr(s0, 16, 4294967295, 0), 16, 0), 1)
    T.eq_u32("ris reset", rd(s0, 20, 1000), 0)
    T.eq_u32("ris mr 0 never", rd(wr(s0, 16, 1, 0), 20, 4000000000), 0)
    T.eq_u32("ris before match", rd(armed(), 20, 9), 0)
    T.eq_u32("ris at match", rd(armed(), 20, 10), 1)
    T.eq_u32("ris after match", rd(armed(), 20, 20), 1)
    T.eq_u32("mis before match", rd(armed(), 24, 9), 0)
    T.eq_u32("mis at match", rd(armed(), 24, 10), 1)
    T.eq_u32("ris masked", rd(wr(s0, 4, 10, 0), 20, 20), 1)
    T.eq_u32("mis masked", rd(wr(s0, 4, 10, 0), 24, 20), 0)
    T.ok("irq masked off", Bool.not(R.Pl031.irq(wr(s0, 4, 10, 0), 20)))
    T.ok("irq before match off", Bool.not(R.Pl031.irq(armed(), 9)))
    T.ok("irq at match", R.Pl031.irq(armed(), 10))
    T.ok("irq unmasked late", R.Pl031.irq(wr(wr(s0, 4, 10, 0), 16, 1, 30), 30))
    T.ok("irq mask after match", Bool.not(R.Pl031.irq(wr(armed(), 16, 0, 20), 20)))
    T.ok("irq follows lr", R.Pl031.irq(wr(armed(), 8, 50, 0), 0))
    T.eq_u32("ris latches", rd(wr(armed(), 8, 0, 20), 20, 21), 1)
    T.eq_u32("icr clears ris", rd(acked(), 20, 21), 0)
    T.eq_u32("icr clears mis", rd(acked(), 24, 21), 0)
    T.ok("icr clears irq", Bool.not(R.Pl031.irq(acked(), 30)))
    T.eq_u32("icr bit 0 only", rd(wr(armed(), 28, 2, 20), 20, 21), 1)
    T.eq_u32("icr before match keeps alarm", rd(wr(armed(), 28, 1, 5), 20, 10), 1)
    T.eq_u32("icr reads zero", rd(acked(), 28, 21), 0)
    T.ok("mr write rearms", R.Pl031.irq(wr(acked(), 4, 40, 21), 40))
    T.ok("rearmed waits", Bool.not(R.Pl031.irq(wr(acked(), 4, 40, 21), 39)))
    T.ok("lr write rearms", R.Pl031.irq(wr(wr(acked(), 8, 0, 21), 8, 10, 22), 22))
    T.eq_u32("ris ignores writes", rd(wr(armed(), 20, 1, 0), 20, 5), 0)
    T.eq_u32("periph id0", rd(s0, 4064, 0), 49)
    T.eq_u32("periph id1", rd(s0, 4068, 0), 16)
    T.eq_u32("periph id2", rd(s0, 4072, 0), 20)
    T.eq_u32("periph id3", rd(s0, 4076, 0), 0)
    T.eq_u32("cell id0", rd(s0, 4080, 0), 13)
    T.eq_u32("cell id1", rd(s0, 4084, 0), 240)
    T.eq_u32("cell id2", rd(s0, 4088, 0), 5)
    T.eq_u32("cell id3", rd(s0, 4092, 0), 177)
    T.eq_u32("unknown reads zero", rd(s0, 32, 9), 0)
    T.eq_u32("past ids reads zero", rd(s0, 4096, 9), 0)
    T.eq_u32("unaligned reads zero", rd(s0, 1, 9), 0)
    T.eq_u32("unknown write ignored", rd(wr(s0, 32, 7, 0), 32, 0), 0)
    T.eq_u32("unknown write keeps mr", rd(wr(wr(s0, 4, 5, 0), 36, 7, 0), 4, 0), 5)
    T.eq_u32("id write ignored", rd(wr(s0, 4064, 7, 0), 4064, 0), 49)
