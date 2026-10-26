import Base
import ../lib/bytes.bend as B

# A DHCP server (RFC 2131) for the NAT's single guest. Every lease is the same:
#   address 10.0.2.15 (167772687), netmask 255.255.255.0, router 10.0.2.2
#   (167772674), DNS 10.0.2.3 (167772675), lease 86400 s, server 10.0.2.2.
# A reply copies xid, flags and chaddr from the request; op 2, htype 1,
# hlen 6, hops 0, secs 0, ciaddr 0, yiaddr 10.0.2.15, siaddr 10.0.2.2,
# giaddr 0, sname and file zero, the magic cookie 99 130 83 99, then the
# options in this order: 53 (message type), 54 (server id), 51 (lease time),
# 1 (subnet mask), 3 (router), 6 (DNS), and 255 (end); no padding after.
# DISCOVER (53 = 1) gets OFFER (2); REQUEST (53 = 3) gets ACK (5); anything
# else (or a message shorter than 240 bytes, or op != 1, or no cookie) gets
# nothing.

# Option parsing. A walk over the options list finds the first option 53
# (message type) before the end option 255; pad options (0) are skipped. A
# list that ends inside an option, or a type option whose length is not 1,
# yields no type. The walk takes one byte of fuel per option, so the list's
# length is always enough.

# The value of a message-type option: its length must be 1.
def Dhcp.type_of(ok: Bool, body: +List<U32>) -> Maybe<&2, U32>:
  match ok body:
    case True{} v <> _:
      Some{v}
    case _ _:
      None{}

# One step of the walk: the answer, or the options left to walk.
type Dhcp.Step is Data:
  Dhcp.Done{t: Maybe<&2, U32>}
  Dhcp.Next{rest: +List<U32>}

# An option's data: complete, then either the type or skipped.
def Dhcp.step.body(fits: Bool, typ: Bool, one: Bool, n: Nat, +body: +List<U32>) -> Dhcp.Step:
  match fits:
    case False{}:
      Dhcp.Done{None{}}
    case True{}:
      match typ:
        case True{}:
          Dhcp.Done{Dhcp.type_of(one, body)}
        case False{}:
          Dhcp.Next{List.drop(&2, U32, body, n)}

# One option: pad, end, message type, or another option to skip.
def Dhcp.step.code(pad: Bool, end: Bool, typ: Bool, +rest: +List<U32>) -> Dhcp.Step:
  match pad:
    case True{}:
      Dhcp.Next{rest}
    case False{}:
      match end:
        case True{}:
          Dhcp.Done{None{}}
        case False{}:
          match rest:
            case Nil{}:
              Dhcp.Done{None{}}
            case +len <> +body:
              +n = U32.to_nat(len)
              Dhcp.step.body(Nat.is_le(n, List.length(&2, U32, body)), typ, U32.is_eq(len, 1), n, body)

def Dhcp.step(opts: +List<U32>) -> Dhcp.Step:
  match opts:
    case Nil{}:
      Dhcp.Done{None{}}
    case +code <> rest:
      Dhcp.step.code(U32.is_eq(code, 0), U32.is_eq(code, 255), U32.is_eq(code, 53), rest)

def Dhcp.walk(fuel: Nat, st: Dhcp.Step) -> Maybe<&2, U32>:
  match fuel st:
    case _ Dhcp.Done{t}:
      t
    case 0n Dhcp.Next{_}:
      None{}
    case 1n+p Dhcp.Next{rest}:
      Dhcp.walk(p, Dhcp.step(rest))

# The message type of a BOOTREQUEST with the magic cookie, if it has one.
def Dhcp.msg_type(ok: Bool, +msg: +List<U32>) -> Maybe<&2, U32>:
  match ok:
    case False{}:
      None{}
    case True{}:
      +opts = List.drop(&2, U32, msg, 240n)
      Dhcp.walk(List.length(&2, U32, opts), Dhcp.step(opts))

def Dhcp.is_request(+msg: +List<U32>) -> Bool:
  +op = B.Bytes.slice(msg, 0n, 1n)
  +ck = B.Bytes.slice(msg, 236n, 4n)
  Nat.is_le(240n, List.length(&2, U32, msg)) && U32.is_eq(B.Bytes.read_le(1n, op), 1) && U32.is_eq(B.Bytes.read_be32(ck), 1669485411) # 0x63825363

# The options of a reply of type t, after the magic cookie.
def Dhcp.options(t: U32) -> +List<U32>:
  [99, 130, 83, 99, 53, 1, t, 54, 4, 10, 0, 2, 2, 51, 4, 0, 1, 81, 128, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 3, 255]

# The reply of type t (2 OFFER, 5 ACK) to msg: xid, flags and chaddr copied.
def Dhcp.build(t: U32, +msg: +List<U32>) -> +List<U32>:
  List.append(&2, U32, [2, 1, 6, 0],
  List.append(&2, U32, B.Bytes.slice(msg, 4n, 4n),
  List.append(&2, U32, [0, 0],
  List.append(&2, U32, B.Bytes.slice(msg, 10n, 2n),
  List.append(&2, U32, [0, 0, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 0, 0, 0, 0],
  List.append(&2, U32, B.Bytes.slice(msg, 28n, 16n),
  List.append(&2, U32, B.Bytes.zeros(192n), Dhcp.options(t))))))))

def Dhcp.answer.pick(discover: Bool, request: Bool, +msg: +List<U32>) -> Maybe<&2, +List<U32>>:
  match discover:
    case True{}:
      Some{Dhcp.build(2, msg)}
    case False{}:
      match request:
        case True{}:
          Some{Dhcp.build(5, msg)}
        case False{}:
          None{}

# DISCOVER (1) gets OFFER (2); REQUEST (3) gets ACK (5); else nothing.
def Dhcp.answer(t: Maybe<&2, U32>, +msg: +List<U32>) -> Maybe<&2, +List<U32>>:
  match t:
    case None{}:
      None{}
    case Some{+v}:
      Dhcp.answer.pick(U32.is_eq(v, 1), U32.is_eq(v, 3), msg)

def Dhcp.reply(msg: +List<U32>) -> Maybe<&2, +List<U32>>:
  +m = msg
  Dhcp.answer(Dhcp.msg_type(Dhcp.is_request(m), m), m)
