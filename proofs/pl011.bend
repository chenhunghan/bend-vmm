import Base
import ../laws/pl011.bend as L
import ../src/dev/pl011.bend as P

# Lemma: a list cut to n holds at most n items.
law T.take_le:
  for xs: +List<U32>
  for n: Nat
  {Nat.is_le(List.length(&2, U32, List.take(&2, U32, xs, n)), n) == True{} : Bool}

def T.take_le(xs, n):
  match xs n:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+p:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      T.take_le(t, p)

def L.pl011.new():
  {==}

def L.pl011.fr_idle():
  {==}

def L.pl011.fr_rx_ready():
  {==}

def L.pl011.tx():
  {==}

def L.pl011.tx_low_byte():
  {==}

def L.pl011.write_other_prints_nothing():
  {==}

def L.pl011.rx():
  {==}

def L.pl011.rx_pops():
  {==}

def L.pl011.rx_empty_reads_zero():
  {==}

def L.pl011.cr_roundtrip():
  {==}

def L.pl011.lcr_roundtrip():
  {==}

def L.pl011.periph_id0():
  {==}

def L.pl011.periph_id2():
  {==}

def L.pl011.cell_id3():
  {==}

def L.pl011.ris_idle():
  {==}

def L.pl011.ris_rx():
  {==}

def L.pl011.mis_masked():
  {==}

def L.pl011.irq_off_when_masked():
  {==}

def L.pl011.irq_rx():
  {==}

def L.pl011.irq_tx():
  {==}

def L.pl011.unknown_reads_zero():
  {==}

# write rebuilds the state with its rx field untouched.
def L.pl011.write_keeps_rx(s, off, v):
  match s:
    case P.Pl011{i, f, l, c, fl, m, rx}:
      {==}

# push_rx keeps the first max(32, |rx|) bytes of rx ++ bs.
def L.pl011.fifo_bound(s, bs):
  match s:
    case P.Pl011{i, f, l, c, fl, m, +rx}:
      T.take_le(List.append(&2, U32, rx, bs), Nat.max(32n, List.length(&2, U32, rx)))
