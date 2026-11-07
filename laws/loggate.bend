import Base
import ../src/lib/u64.bend as U
import ../src/vmm/loggate.bend as G

# Spec for src/vmm/loggate.bend: 200 messages at once, then 20 a second.

def ms(x: U32) -> U.U64:
  U.U64{0, x}

law loggate.first:
  {G.Gate.step(G.Gate{200000, ms(0), 0}, ms(5000)) == G.GateOut{G.Gate{199000, ms(5000), 0}, 1} : G.GateOut}

law loggate.empty_drops:
  {G.Gate.step(G.Gate{999, ms(1000), 3}, ms(1000)) == G.GateOut{G.Gate{999, ms(1000), 4}, 0} : G.GateOut}

# 50 ms later one more message's worth has come back: it passes, telling
# of the 4 dropped
law loggate.refills:
  {G.Gate.step(G.Gate{0, ms(1000), 4}, ms(1050)) == G.GateOut{G.Gate{0, ms(1050), 0}, 5} : G.GateOut}

law loggate.caps:
  {G.Gate.step(G.Gate{100000, ms(1000), 0}, ms(60000)) == G.GateOut{G.Gate{199000, ms(60000), 0}, 1} : G.GateOut}
