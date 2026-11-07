import Base
import ../lib/u64.bend as U

# The VMM's log gate (laws/loggate.bend): a guest that traps in a loop (an
# unmapped access, an unknown register) cannot flood stderr. A token bucket
# in thousandths of a message: full at 200 messages, refilled at 20 a
# second; a message takes one. The host keeps the bucket and the clock
# (Hvf.log_state); the gate decides.

type Gate is Data:
  Gate{tokens: U32, last: U.U64, dropped: U32}

type GateOut is Data:
  GateOut{gate: Gate, verdict: U32}

def Gate.full() -> U32:
  200000

# The bucket at now (ms), from the gate's last time: 20 thousandths a ms,
# at most full (10 s of refill is all it takes).
def Gate.refill(+tokens: U32, +last: U.U64, +now: U.U64) -> U32:
  +ms = U.U64.sub(now, last)
  +add = Bool.pick(U32, U.U64.is_lt(ms, U.U64{0, 10000}), (U.U64.lo(ms) * 20 : U32), Gate.full())
  Bool.pick(U32, U.U64.is_zero(last), tokens, U32.min((tokens + add : U32), Gate.full()))

# A message at now: dropped (verdict 0, one more counted) when the bucket
# holds less than one; else it passes, taking one, with verdict 1 + the
# messages dropped since the last that passed.
def Gate.step(g: Gate, +now: U.U64) -> GateOut:
  match g:
    case Gate{tk, last, +dropped}:
      +t = Gate.refill(tk, last, now)
      Bool.pick(GateOut, U32.is_lt(t, 1000), GateOut{Gate{t, now, (dropped + 1 : U32)}, 0},
        GateOut{Gate{(t - 1000 : U32), now, 0}, (dropped + 1 : U32)})

def Gate.wire(+ws: +List<U32>) -> Gate:
  Gate{Maybe.default(&2, U32, List.get(&2, U32, ws, 0n), 200000), U.U64{Maybe.default(&2, U32, List.get(&2, U32, ws, 1n), 0), Maybe.default(&2, U32, List.get(&2, U32, ws, 2n), 0)}, Maybe.default(&2, U32, List.get(&2, U32, ws, 3n), 0)}

def Gate.now(+ws: +List<U32>) -> U.U64:
  U.U64{Maybe.default(&2, U32, List.get(&2, U32, ws, 4n), 0), Maybe.default(&2, U32, List.get(&2, U32, ws, 5n), 0)}
