import Base

# Where the NAT's addresses lead on the host. The guest sees the gateway
# 10.0.2.2 and a DNS server 10.0.2.3: the gateway is the host itself
# (127.0.0.1), the DNS server is the host's own resolver (the first
# nameserver of /etc/resolv.conf, 1.1.1.1 when there is none). Replies map
# back the other way. Addresses are IPv4 as U32 (a.b.c.d = a << 24 | ...).

def Addr.gateway() -> U32:
  167772674

def Addr.dns() -> U32:
  167772675

def Addr.loopback() -> U32:
  2130706433

# 1.1.1.1
def Addr.fallback_dns() -> U32:
  16843009

def Addr.byte.go(m: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case None{}:
      None{}
    case Some{+v}:
      Bool.pick(Maybe<&2, U32>, U32.is_le(v, 255), Some{v}, None{})

# A decimal byte, if s is one (at most 255).
def Addr.byte(s: String) -> Maybe<&2, U32>:
  Addr.byte.go(U32.read(s))

def Addr.quad(a: Maybe<&2, U32>, b: Maybe<&2, U32>, c: Maybe<&2, U32>, d: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match a b c d:
    case Some{x} Some{y} Some{z} Some{w}:
      Some{((x << 24n : U32) .|. ((y << 16n : U32) .|. ((z << 8n : U32) .|. w : U32) : U32) : U32)}
    case _ _ _ _:
      None{}

def Addr.parts(ps: List<&2, String>) -> Maybe<&2, U32>:
  match ps:
    case Con{a, Con{b, Con{c, Con{d, Nil{}}}}}:
      Addr.quad(Addr.byte(a), Addr.byte(b), Addr.byte(c), Addr.byte(d))
    case _:
      None{}

# A dotted quad.
def Addr.parse(s: String) -> Maybe<&2, U32>:
  Addr.parts(String.split(String.trim(s), '.'))

def Addr.line(ws: List<&2, String>) -> Maybe<&2, U32>:
  match ws:
    case Con{k, Con{v, rest}}:
      Bool.pick(Maybe<&2, U32>, String.eq(k, "nameserver"), Addr.parse(v), None{})
    case _:
      None{}

def Addr.first(ls: List<&2, String>) -> U32:
  match ls:
    case Nil{}:
      Addr.fallback_dns()
    case Con{l, rest}:
      Maybe.default(&2, U32, Addr.line(String.split(String.trim(l), ' ')), Addr.first(rest))

# The first IPv4 nameserver of a resolv.conf.
def Addr.nameserver(text: String) -> U32:
  Addr.first(String.lines(text))

# A guest-side destination as the host reaches it.
def Addr.to_host(+ip: U32, +dns: U32) -> U32:
  Bool.pick(U32, U32.is_eq(ip, Addr.gateway()), Addr.loopback(), Bool.pick(U32, U32.is_eq(ip, Addr.dns()), dns, ip))

# A host-side source as the guest sees it.
def Addr.to_guest(+ip: U32, +dns: U32) -> U32:
  Bool.pick(U32, U32.is_eq(ip, Addr.loopback()), Addr.gateway(), Bool.pick(U32, U32.is_eq(ip, dns), Addr.dns(), ip))
