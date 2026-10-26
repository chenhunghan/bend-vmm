import Base
import ../src/dev/pl011.bend as P
import ./t.bend as T

# The PL011 UART: behaviour past the laws (register masks, FIFO depth, the
# ID block, read-only and unknown registers, a Linux-like probe sequence).

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def val_of(r: P.Pl011 & U32) -> U32:
  match r:
    case (s, v):
      v

def st_of(r: P.Pl011 & U32) -> P.Pl011:
  match r:
    case (s, v):
      s

def wst_of(r: P.Pl011 & +List<U32>) -> P.Pl011:
  match r:
    case (s, o):
      s

def wout_of(r: P.Pl011 & +List<U32>) -> +List<U32>:
  match r:
    case (s, o):
      o

def rd(s: P.Pl011, off: U32) -> U32:
  val_of(P.Pl011.read(s, off))

def wr(s: P.Pl011, off: U32, v: U32) -> P.Pl011:
  wst_of(P.Pl011.write(s, off, v))

def out(s: P.Pl011, off: U32, v: U32) -> +List<U32>:
  wout_of(P.Pl011.write(s, off, v))

def pop(s: P.Pl011) -> P.Pl011:
  st_of(P.Pl011.read(s, 0))

def seq.go(n: Nat) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +p = p
      U32.from_nat(p) <> seq.go(p)

# Bytes 0, 1, .., n-1.
def seq(n: Nat) -> +List<U32>:
  List.reverse(&2, U32, seq.go(n))

def rx_len(s: P.Pl011) -> U32:
  match s:
    case P.Pl011{i, f, l, c, fl, m, rx}:
      U32.from_nat(List.length(&2, U32, rx))

# Pops n bytes and collects them.
def drain(n: Nat, +s: P.Pl011) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      rd(s, 0) <> drain(p, pop(s))

def full() -> P.Pl011:
  P.Pl011.push_rx(P.Pl011.new(), seq(40n))

def main() -> IO(Unit):
  do IO<Unit>:
    +s0 : P.Pl011 = P.Pl011.new()
    T.eq_u32("cr reset", rd(s0, 48), 768)
    T.eq_u32("ifls reset", rd(s0, 52), 18)
    T.eq_u32("imsc reset", rd(s0, 56), 0)
    T.eq_u32("mis reset", rd(s0, 64), 0)
    T.ok("irq reset off", Bool.not(P.Pl011.irq(s0)))
    T.eq_u32("rsr reads zero", rd(s0, 4), 0)
    T.eq_u32("ilpr reads zero", rd(s0, 32), 0)
    T.eq_u32("dmacr reads zero", rd(s0, 72), 0)
    T.eq_u32("ibrd roundtrip", rd(wr(s0, 36, 26), 36), 26)
    T.eq_u32("ibrd 16 bits", rd(wr(s0, 36, 4294967295), 36), 65535)
    T.eq_u32("fbrd roundtrip", rd(wr(s0, 40, 3), 40), 3)
    T.eq_u32("fbrd 6 bits", rd(wr(s0, 40, 255), 40), 63)
    T.eq_u32("lcr_h 8 bits", rd(wr(s0, 44, 4095), 44), 255)
    T.eq_u32("cr 16 bits", rd(wr(s0, 48, 131071), 48), 65535)
    T.eq_u32("ifls 6 bits", rd(wr(s0, 52, 255), 52), 63)
    T.eq_u32("imsc 11 bits", rd(wr(s0, 56, 4095), 56), 2047)
    T.eq_u32("fr ignores writes", rd(wr(s0, 24, 0), 24), 144)
    T.eq_u32("ris ignores writes", rd(wr(s0, 60, 0), 60), 32)
    T.eq_u32("icr keeps tx pending", rd(wr(s0, 68, 2047), 60), 32)
    T.eq_u32("unknown write ignored", rd(wr(s0, 8, 7), 8), 0)
    T.eq_u32("unaligned reads zero", rd(wr(s0, 49, 7), 48), 768)
    T.eq_str("rsr write prints nothing", show(out(s0, 4, 65)), "[]")
    T.eq_str("tx high bits dropped", show(out(s0, 0, 4294967050)), "[10]")
    T.eq_u32("periph id1", rd(s0, 4068), 16)
    T.eq_u32("periph id3", rd(s0, 4076), 0)
    T.eq_u32("cell id0", rd(s0, 4080), 13)
    T.eq_u32("cell id1", rd(s0, 4084), 240)
    T.eq_u32("cell id2", rd(s0, 4088), 5)
    T.eq_u32("past ids reads zero", rd(s0, 4096), 0)
    T.eq_u32("fifo holds 32", rx_len(full()), 32)
    T.eq_u32("fifo full fr", rd(full(), 24), 192)
    T.eq_str("fifo keeps oldest", show(drain(3n, full())), "[0, 1, 2]")
    T.eq_u32("fifo frees after pop", rx_len(P.Pl011.push_rx(pop(full()), [99, 98])), 32)
    T.eq_u32("pop from full clears rxff", rd(pop(full()), 24), 128)
    T.eq_u32("push appends", rd(pop(P.Pl011.push_rx(P.Pl011.push_rx(s0, [1]), [2])), 0), 2)
    T.eq_u32("drain empties", rd(pop(P.Pl011.push_rx(s0, [7])), 24), 144)
    T.eq_u32("empty pop keeps state", rd(pop(s0), 48), 768)
    T.eq_u32("rx irq clears on drain", rd(pop(wr(P.Pl011.push_rx(s0, [7]), 56, 80)), 64), 0)
    T.ok("irq rt", P.Pl011.irq(wr(P.Pl011.push_rx(s0, [7]), 56, 64)))
    T.ok("irq off after drain", Bool.not(P.Pl011.irq(pop(wr(P.Pl011.push_rx(s0, [7]), 56, 80)))))
    T.eq_u32("mis all", rd(wr(P.Pl011.push_rx(s0, [7]), 56, 2047), 64), 112)
    T.eq_u32("write keeps fifo", rd(wr(P.Pl011.push_rx(s0, [5]), 48, 0), 0), 5)
