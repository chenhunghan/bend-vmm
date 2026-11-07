import Base
import ../src/lib/u64.bend as U
import ../src/net/limits.bend as N
import ../src/net/flush.bend as F

# Spec for src/net/flush.bend: what a NAT connection's flusher does on
# waking, under the default limits (4 MiB cap, 64 MiB budget, 60 s stall).

def lim() -> N.Limits:
  N.Lim.default()

def w(x: U32) -> U.U64:
  U.U64{0, x}

# pending, total, idle; no error, not over, not closing, not overdue, no shut
def facts(p: U32, t: U32, i: U.U64) -> F.Facts:
  F.Facts{False{}, False{}, w(p), w(t), i, False{}, False{}, False{}}

law flush.wait:
  {F.Flush.decide(facts(1000, 1000, w(5)), False{}, lim()) == F.FWait{} : F.Act}

law flush.block_cap:
  {F.Flush.decide(facts(4194305, 4194305, w(5)), False{}, lim()) == F.FBlock{} : F.Act}

law flush.at_cap_waits:
  {F.Flush.decide(facts(4194304, 4194304, w(5)), False{}, lim()) == F.FWait{} : F.Act}

law flush.block_budget:
  {F.Flush.decide(facts(1000, 67108865, w(5)), False{}, lim()) == F.FBlock{} : F.Act}

law flush.blocked_waits:
  {F.Flush.decide(facts(3000000, 3000000, w(5)), True{}, lim()) == F.FWait{} : F.Act}

law flush.unblock_half:
  {F.Flush.decide(facts(2097152, 2097152, w(5)), True{}, lim()) == F.FUnblock{} : F.Act}

law flush.drained_unblocks:
  {F.Flush.decide(facts(0, 0, w(5)), True{}, lim()) == F.FUnblock{} : F.Act}

law flush.drained_ends:
  {F.Flush.decide(facts(0, 0, w(5)), False{}, lim()) == F.FEnd{} : F.Act}

law flush.drained_shut:
  {F.Flush.decide(F.Facts{False{}, False{}, w(0), w(0), w(5), False{}, False{}, True{}}, False{}, lim()) == F.FShut{} : F.Act}

law flush.drained_closed:
  {F.Flush.decide(F.Facts{False{}, False{}, w(0), w(0), w(5), True{}, False{}, True{}}, True{}, lim()) == F.FClosed{} : F.Act}

# 60 s without a byte taken, data pending: reset
law flush.stall:
  {F.Flush.decide(facts(1000, 1000, U.U64{13, 4165425152}), False{}, lim()) == F.FReset{False{}} : F.Act}

law flush.stall_nothing_pending:
  {F.Flush.decide(facts(0, 0, U.U64{13, 4165425152}), False{}, lim()) == F.FEnd{} : F.Act}

law flush.over_hard:
  {F.Flush.decide(F.Facts{False{}, True{}, w(1000), w(1000), w(5), False{}, False{}, False{}}, False{}, lim()) == F.FReset{False{}} : F.Act}

law flush.error:
  {F.Flush.decide(F.Facts{True{}, False{}, w(0), w(0), w(5), False{}, False{}, False{}}, False{}, lim()) == F.FReset{False{}} : F.Act}

# closed with data past the linger time: reset, quietly (the NAT closed it)
law flush.overdue_quiet:
  {F.Flush.decide(F.Facts{False{}, False{}, w(1000), w(1000), w(5), True{}, True{}, False{}}, False{}, lim()) == F.FReset{True{}} : F.Act}

# a closing connection is never blocked or unblocked
law flush.closing_no_block:
  {F.Flush.decide(F.Facts{False{}, False{}, w(4194305), w(4194305), w(5), True{}, False{}, False{}}, False{}, lim()) == F.FWait{} : F.Act}

law flush.facts_wire:
  {F.Flush.facts([0, 1, 0, 7, 0, 9, 1, 2, 1, 0, 1]) == Some{F.Facts{False{}, True{}, w(7), w(9), U.U64{1, 2}, True{}, False{}, True{}}} : Maybe<&2, F.Facts>}

law flush.facts_gone:
  {F.Flush.facts([]) == None{} : Maybe<&2, F.Facts>}

# Proposed: the bound on what a send may leave queued (32 MiB per
# connection, 96 MiB over all).
law flush.over_hard_limit:
  {F.Flush.over(w(33554433), w(33554433), lim()) == True{} : Bool}

law flush.at_hard_limit:
  {F.Flush.over(w(33554432), w(33554432), lim()) == False{} : Bool}

law flush.over_wall:
  {F.Flush.over(w(1000), w(100663297), lim()) == True{} : Bool}
