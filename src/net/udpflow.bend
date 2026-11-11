import Base
import ../lib/u64.bend as U
import ./limits.bend as N

# The NAT's UDP flows (laws/udpflow.bend): each is a host socket connected
# to the one address and port a guest port sent to. The host keeps the
# sockets and finds a datagram's flow; which flow closes when there are too
# many, and when an idle one closes, is decided here.

# A flow's number and how long since a datagram went either way (ns).
type Age is Data:
  Age{id: U32, age: U.U64}

def Udp.count(+as: +List<Age>) -> U32:
  U32.from_nat(List.length(&2, Age, as))

def Udp.age_of(a: Age) -> U.U64:
  match a:
    case Age{i, g}:
      g

def Udp.older(skip: Bool, +a: Age, best: Maybe<&2, Age>) -> Maybe<&2, Age>:
  match skip best:
    case True{} _:
      best
    case False{} None{}:
      Some{a}
    case False{} Some{+b}:
      Bool.pick(Maybe<&2, Age>, U.U64.is_lt(Udp.age_of(b), Udp.age_of(a)), Some{a}, Some{b})

# The oldest flow but fresh (the one just opened).
def Udp.oldest(as: +List<Age>, +fresh: U32, best: Maybe<&2, Age>) -> Maybe<&2, Age>:
  match as:
    case Nil{}:
      best
    case Con{Age{+id, +age}, rest}:
      Udp.oldest(rest, fresh, Udp.older(U32.is_eq(id, fresh), Age{id, age}, best))

def Udp.id_of(m: Maybe<&2, Age>) -> Maybe<&2, U32>:
  match m:
    case None{}:
      None{}
    case Some{Age{i, g}}:
      Some{i}

# Past the most flows (l's udp_max) after fresh opened: the least recently
# used other flow closes.
def Udp.evict(+as: +List<Age>, +fresh: U32, l: N.Limits) -> Maybe<&2, U32>:
  match l:
    case N.Limits{c, h, s, k, b, w, lg, lm, +max, ui}:
      Bool.pick(Maybe<&2, U32>, U32.is_lt(max, Udp.count(as)), Udp.id_of(Udp.oldest(as, fresh, None{})), None{})

# A flow no datagram crossed for l's udp_idle closes.
def Udp.idle(+age: U.U64, l: N.Limits) -> Bool:
  match l:
    case N.Limits{c, h, s, k, b, w, lg, lm, um, +idle}:
      U.U64.is_le(idle, age)

# The host's flows (Hvf.udp_ages): [id, age hi, age lo]*.
def Udp.ages(ws: +List<U32>) -> +List<Age>:
  match ws:
    case Con{id, Con{h, Con{lo, rest}}}:
      Age{id, U.U64{h, lo}} <> Udp.ages(rest)
    case _:
      []

# The flow a datagram goes out on, from the open flows as the host reports
# them ([id, guest port, address, port]* on the host's side, Hvf.udp_flows):
# the one connected to the same address and port from the same guest port,
# or 0, none (the host opens one).
def Udp.find(ws: +List<U32>, +sport: U32, +ip: U32, +port: U32) -> U32:
  match ws:
    case Nil{}:
      0
    case Con{+id, r1}:
      match r1:
        case Nil{}:
          0
        case Con{+s, r2}:
          match r2:
            case Nil{}:
              0
            case Con{+a, r3}:
              match r3:
                case Nil{}:
                  0
                case Con{+p, more}:
                  Bool.pick(U32, U32.is_eq(s, sport) && U32.is_eq(a, ip) && U32.is_eq(p, port), id, Udp.find(more, sport, ip, port))
