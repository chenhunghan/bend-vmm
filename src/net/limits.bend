import Base
import ../lib/u64.bend as U

# The user-mode NAT's host-side limits (laws/limits.bend). The host keeps
# guest data a socket has not taken yet, and closes idle UDP flows; these
# numbers say how much and how long. host/hvf.c takes them once at startup
# (Hvf.net_limits) and applies them where it sends.
#
# Per TCP connection: past cap bytes pending the NAT stops taking the
# guest's data until it drains to half; past hard (the guest sent on
# regardless), or with no byte taken for stall ns, the connection is reset;
# the flusher looks again every tick ns. Over all connections: past budget
# every flusher holding data blocks the guest, and a send that would pass
# wall resets its connection. A close with data pending sends it for at
# most linger ns, at most linger_max connections at once. UDP: at most
# udp_max flows (the least recently used goes first), each closed after
# udp_idle ns without a datagram.
type Limits is Data:
  Limits{cap: U.U64, hard: U.U64, stall: U.U64, tick: U.U64, budget: U.U64, wall: U.U64, linger: U.U64, linger_max: U32, udp_max: U32, udp_idle: U.U64}

def Lim.mib(n: U32) -> U.U64:
  U.U64.shl(20n, U.U64{0, n})

# a * b by shifts and adds over a's 32 bits
def Lim.mul.go(n: Nat, +a: U32, +b: U.U64, +acc: U.U64) -> U.U64:
  match n:
    case 0n:
      acc
    case 1n+p:
      Lim.mul.go(p, (a >> 1n : U32), U.U64.shl1(b), Bool.pick(U.U64, U32.is_eq((a .&. 1 : U32), 1), U.U64.add(acc, b), acc))

def Lim.mul(a: U32, b: U32) -> U.U64:
  Lim.mul.go(32n, a, U.U64{0, b}, U.U64.zero())

# s seconds in ns.
def Lim.secs(s: U32) -> U.U64:
  # 10^9 = 2^9 * 1953125
  U.U64.shl(9n, Lim.mul(s, 1953125))

def Lim.millis(ms: U32) -> U.U64:
  Lim.mul(ms, 1000000)

def Lim.default() -> Limits:
  Limits{Lim.mib(4), Lim.mib(32), Lim.secs(60), Lim.millis(100), Lim.mib(64), Lim.mib(96), Lim.secs(30), 64, 128, Lim.secs(60)}

# The limits hold together: a connection blocks before it is reset
# (cap <= hard), the total blocks before it resets (budget <= wall), one
# connection's hard limit fits in the total, the flusher looks again well
# within a stall, and there is room for one UDP flow and one lingering
# close.
def Lim.sane(l: Limits) -> Bool:
  match l:
    case Limits{+c, +h, +s, +t, +b, +w, lg, +lm, +um, ui}:
      U.U64.is_le(c, h) && U.U64.is_le(b, w) && U.U64.is_le(h, w) && U.U64.is_lt(t, s)
        && Bool.not(U32.is_zero(lm)) && Bool.not(U32.is_zero(um)) && U32.is_le(um, 1024)

def Lim.w64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      [h, l]

# For the host: cap, hard, stall, tick, budget, wall, linger (each hi, lo),
# linger_max, udp_max, udp_idle (hi, lo).
def Lim.wire(l: Limits) -> +List<U32>:
  match l:
    case Limits{c, h, s, t, b, w, lg, lm, um, ui}:
      List.concat(&2, U32, [Lim.w64(c), Lim.w64(h), Lim.w64(s), Lim.w64(t), Lim.w64(b), Lim.w64(w), Lim.w64(lg), [lm, um], Lim.w64(ui)])
