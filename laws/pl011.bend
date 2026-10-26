import Base
import ../src/dev/pl011.bend as P

# Frozen spec for src/dev/pl011.bend.

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

def after_read(s: P.Pl011, off: U32) -> P.Pl011:
  st_of(P.Pl011.read(s, off))

def rx_of(s: P.Pl011) -> +List<U32>:
  match s:
    case P.Pl011{i, f, l, c, fl, m, rx}:
      rx

law pl011.new:
  {P.Pl011.new() == P.Pl011{0, 0, 0, 768, 18, 0, []} : P.Pl011}

law pl011.fr_idle:
  # TXFE | RXFE
  {rd(P.Pl011.new(), 24) == 144 : U32}

law pl011.fr_rx_ready:
  # TXFE only
  {rd(P.Pl011.push_rx(P.Pl011.new(), [97]), 24) == 128 : U32}

law pl011.tx:
  {out(P.Pl011.new(), 0, 65) == [65] : +List<U32>}

law pl011.tx_low_byte:
  {out(P.Pl011.new(), 0, 321) == [65] : +List<U32>}

law pl011.write_other_prints_nothing:
  {out(P.Pl011.new(), 48, 769) == [] : +List<U32>}

law pl011.rx:
  {rd(P.Pl011.push_rx(P.Pl011.new(), [97, 98]), 0) == 97 : U32}

law pl011.rx_pops:
  {rd(after_read(P.Pl011.push_rx(P.Pl011.new(), [97, 98]), 0), 0) == 98 : U32}

law pl011.rx_empty_reads_zero:
  {rd(P.Pl011.new(), 0) == 0 : U32}

law pl011.cr_roundtrip:
  {rd(wr(P.Pl011.new(), 48, 769), 48) == 769 : U32}

law pl011.lcr_roundtrip:
  {rd(wr(P.Pl011.new(), 44, 112), 44) == 112 : U32}

law pl011.periph_id0:
  {rd(P.Pl011.new(), 4064) == 17 : U32}

law pl011.periph_id2:
  {rd(P.Pl011.new(), 4072) == 20 : U32}

law pl011.cell_id3:
  {rd(P.Pl011.new(), 4092) == 177 : U32}

law pl011.ris_idle:
  # TX always pending
  {rd(P.Pl011.new(), 60) == 32 : U32}

law pl011.ris_rx:
  # TX | RX | RT
  {rd(P.Pl011.push_rx(P.Pl011.new(), [10]), 60) == 112 : U32}

law pl011.mis_masked:
  {rd(wr(P.Pl011.push_rx(P.Pl011.new(), [10]), 56, 16), 64) == 16 : U32}

law pl011.irq_off_when_masked:
  {P.Pl011.irq(P.Pl011.push_rx(P.Pl011.new(), [10])) == False{} : Bool}

law pl011.irq_rx:
  {P.Pl011.irq(wr(P.Pl011.push_rx(P.Pl011.new(), [10]), 56, 16)) == True{} : Bool}

law pl011.irq_tx:
  {P.Pl011.irq(wr(P.Pl011.new(), 56, 32)) == True{} : Bool}

law pl011.unknown_reads_zero:
  {rd(P.Pl011.new(), 8) == 0 : U32}

# General: register writes never touch the receive FIFO.
law pl011.write_keeps_rx:
  for s: P.Pl011
  for off: U32
  for v: U32
  {rx_of(wr(s, off, v)) == rx_of(s) : +List<U32>}

# General: the FIFO never holds more than 32 bytes.
law pl011.fifo_bound:
  for s: P.Pl011
  for bs: +List<U32>
  {Nat.is_le(List.length(&2, U32, rx_of(P.Pl011.push_rx(s, bs))), Nat.max(32n, List.length(&2, U32, rx_of(s)))) == True{} : Bool}
