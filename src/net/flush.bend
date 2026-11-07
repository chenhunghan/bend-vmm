import Base
import ../lib/u64.bend as U
import ./limits.bend as N

# A NAT connection's flusher (laws/flush.bend): guest data a host socket did
# not take at once waits on the host, and the flusher sends it as the socket
# drains. Each time it wakes (the socket took data, or the tick), the host
# answers what it sees (Facts) and the flusher decides here what to do.
#
#   the socket is gone (closed under it)                     -> End
#   over its hard limit (the guest sent on regardless), a socket error,
#   no byte taken for the stall time, or closed with data longer than the
#   linger time                                              -> Reset (quiet
#                                                               when the NAT
#                                                               already closed
#                                                               the connection)
#   nothing pending and the NAT closed the connection         -> Closed
#   nothing pending and the NAT shut it down                  -> Shut (then on)
#   nothing pending while the guest is blocked                -> Unblock
#   nothing pending                                          -> End
#   past the cap (per connection) or the budget (over all)
#   while not blocked and not closing                        -> Block
#   blocked, not closing, back to half the cap and the budget -> Unblock
#   otherwise                                                -> Wait (until the
#                                                               socket takes
#                                                               more, or the tick)

type Facts is Data:
  Facts{err: Bool, over: Bool, pending: U.U64, total: U.U64, idle: U.U64, closing: Bool, overdue: Bool, shut: Bool}

type Act is Data:
  FReset{quiet: Bool}
  FClosed{}
  FShut{}
  FBlock{}
  FUnblock{}
  FEnd{}
  FWait{}

def Flush.half(+a: U.U64) -> U.U64:
  U.U64.shr(1n, a)

def Flush.drained(+f: Facts, +blocked: Bool) -> Act:
  match f:
    case Facts{e, o, p, t, i, closing, ov, shut}:
      Bool.pick(Act, closing, FClosed{}, Bool.pick(Act, shut, FShut{}, Bool.pick(Act, blocked, FUnblock{}, FEnd{})))

def Flush.pressure(+f: Facts, +blocked: Bool, l: N.Limits) -> Act:
  match f l:
    case Facts{e, o, +p, +t, i, closing, ov, sh} N.Limits{+cap, h, s, k, +budget, w, lg, lm, um, ui}:
      +over = U.U64.is_lt(cap, p) || U.U64.is_lt(budget, t)
      +under = U.U64.is_le(p, Flush.half(cap)) && U.U64.is_le(t, Flush.half(budget))
      Bool.pick(Act, Bool.not(closing) && Bool.not(blocked) && over, FBlock{},
        Bool.pick(Act, Bool.not(closing) && blocked && under, FUnblock{}, FWait{}))

def Flush.fatal(+f: Facts, l: N.Limits) -> Bool:
  match f l:
    case Facts{err, over, +p, t, +idle, closing, overdue, sh} N.Limits{c, h, +stall, k, b, w, lg, lm, um, ui}:
      +pend = Bool.not(U.U64.is_zero(p))
      err || over || (pend && U.U64.is_le(stall, idle)) || (pend && overdue)

def Flush.closing(f: Facts) -> Bool:
  match f:
    case Facts{e, o, p, t, i, closing, ov, sh}:
      closing

def Flush.pending(f: Facts) -> U.U64:
  match f:
    case Facts{e, o, p, t, i, c, ov, sh}:
      p

# What the flusher does on waking with facts f, the guest blocked or not,
# under the limits l.
def Flush.decide(+f: Facts, +blocked: Bool, +l: N.Limits) -> Act:
  Bool.pick(Act, Flush.fatal(f, l), FReset{Flush.closing(f)},
    Bool.pick(Act, U.U64.is_zero(Flush.pending(f)), Flush.drained(f, blocked), Flush.pressure(f, blocked, l)))

# A send the host queued past the limits: its connection's pending bytes
# over the hard limit (the guest sent on although it was blocked), or all
# connections' pending bytes over the wall. The host then drops what the
# connection holds and its flusher resets it (Facts.over).
def Flush.over(+pending: U.U64, +total: U.U64, l: N.Limits) -> Bool:
  match l:
    case N.Limits{c, +hard, s, k, b, +wall, lg, lm, um, ui}:
      U.U64.is_lt(hard, pending) || U.U64.is_lt(wall, total)

# What a close the NAT asks for does (V.TcpClose): with nothing pending the
# socket closes now; with data pending it lingers (sends it, up to the
# linger time) unless the most closes already linger, when it resets.
type Close is Data:
  CNow{}
  CLinger{}
  CReset{}

def Flush.close(+pending: Bool, +lingering: U32, l: N.Limits) -> Close:
  match l:
    case N.Limits{c, h, s, k, b, w, lg, +most, um, ui}:
      Bool.pick(Close, Bool.not(pending), CNow{}, Bool.pick(Close, U32.is_le(most, lingering), CReset{}, CLinger{}))

def Flush.close.code(c: Close) -> U32:
  match c:
    case CNow{}:
      0
    case CLinger{}:
      1
    case CReset{}:
      2

# The facts as the host answers them (Hvf.tcp_flush): [err, over, pending,
# total, idle (each hi, lo), closing, overdue, shut]; None for [] (the
# socket is gone) or a malformed answer.
def Flush.word(+ws: +List<U32>, k: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, k), 0)

def Flush.u64(+ws: +List<U32>, +k: Nat) -> U.U64:
  U.U64{Flush.word(ws, k), Flush.word(ws, 1n+k)}

def Flush.flag(+ws: +List<U32>, k: Nat) -> Bool:
  U32.is_ne(Flush.word(ws, k), 0)

def Flush.facts(+ws: +List<U32>) -> Maybe<&2, Facts>:
  Bool.pick(Maybe<&2, Facts>, Nat.is_eq(List.length(&2, U32, ws), 11n),
    Some{Facts{Flush.flag(ws, 0n), Flush.flag(ws, 1n), Flush.u64(ws, 2n), Flush.u64(ws, 4n), Flush.u64(ws, 6n), Flush.flag(ws, 8n), Flush.flag(ws, 9n), Flush.flag(ws, 10n)}},
    None{})
