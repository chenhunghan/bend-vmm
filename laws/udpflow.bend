import Base
import ../src/lib/u64.bend as U
import ../src/net/limits.bend as N
import ../src/net/udpflow.bend as F

# Spec for src/net/udpflow.bend: which UDP flow closes past the most (128
# by default), and when an idle one closes (60 s).

def lim() -> N.Limits:
  N.Lim.default()

def few(+n: Nat) -> +List<F.Age>:
  match n:
    case 0n:
      []
    case 1n+(+p):
      F.Age{U32.from_nat(1n+p), U.U64{0, U32.from_nat(1n+p)}} <> few(p)

law udpflow.under_limit:
  {F.Udp.evict(few(128n), 1, lim()) == None{} : Maybe<&2, U32>}

# 129 flows, ages 1..129 (flow i is i ns old): the oldest, 129, closes
law udpflow.past_limit:
  {F.Udp.evict(few(129n), 1, lim()) == Some{129} : Maybe<&2, U32>}

# never the flow just opened, even when it is the oldest
law udpflow.not_fresh:
  {F.Udp.evict(few(129n), 129, lim()) == Some{128} : Maybe<&2, U32>}

law udpflow.idle:
  {F.Udp.idle(U.U64{13, 4165425152}, lim()) == True{} : Bool}

law udpflow.not_idle:
  {F.Udp.idle(U.U64{13, 4165425151}, lim()) == False{} : Bool}

law udpflow.ages_wire:
  {F.Udp.ages([7, 0, 5, 9, 1, 2]) == [F.Age{7, U.U64{0, 5}}, F.Age{9, U.U64{1, 2}}] : +List<F.Age>}
