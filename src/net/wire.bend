import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# Network wire formats for the user-mode NAT: Ethernet II, ARP, IPv4, ICMP,
# UDP, TCP, and the Internet checksum (RFC 1071). Frames and packets are byte
# lists (+List<U32>); IPv4 addresses are U32 in network order read as a
# number (10.0.2.15 = 167772687); MACs are 6-byte lists. All multi-byte fields
# on the wire are big-endian.
#
# Parsers are total: they answer None for anything too short or malformed
# (bad version, IHL < 5, a length field past the data), never crash.
# Builders compute every length and checksum field themselves.

# One end-around-carry step: the high half added back into the low half.
def Csum.fold1(+x: U32) -> U32:
  ((x .&. 65535) + (x >> 16n) : U32)

# Folds a 32-bit sum of 16-bit words to 16 bits (end-around carry).
# Two steps suffice: the first leaves at most 0x1_fffe, the second at most 0xffff.
def Csum.fold(x: U32) -> U32:
  Csum.fold1(Csum.fold1(x))

# One's-complement addition of two 16-bit values.
def Csum.add(a: U32, b: U32) -> U32:
  Csum.fold((a + b : U32))

# The folded sum, word by word.
def Csum.seq(bs: +List<U32>) -> U32:
  match bs:
    case Nil{}:
      0
    case Con{a, Nil{}}:
      ((a .&. 255) << 8n : U32)
    case Con{a, Con{b, t}}:
      Csum.add((((a .&. 255) << 8n) .|. (b .&. 255) : U32), Csum.seq(t))

# Buffers up to this many bytes are summed sequentially.
def Csum.leaf() -> Nat:
  128n

def Csum.small(+n: Nat) -> Bool:
  Nat.is_le(n, Csum.leaf())

# The folded sum of bs (n bytes), as a balanced parallel fold: the halves split
# at an even offset, so each half's words are words of bs, and one's-complement
# addition is associative and commutative. d bounds the depth.
def Csum.par(d: Nat, small: Bool, +n: Nat, +bs: +List<U32>) -> U32:
  match d small:
    case 0n _:
      Csum.seq(bs)
    case 1n+p True{}:
      Csum.seq(bs)
    case 1n+(+p) False{}:
      +h = Nat.mul(2n, Nat.div(n, 4n))
      +m = Nat.sub(n, h)
      +l = List.take(&2, U32, bs, h)
      +r = List.drop(&2, U32, bs, h)
      +sl = Csum.small(h)
      +sr = Csum.small(m)
      a b = Csum.par(p, sl, h, l) Csum.par(p, sr, m, r)
      Csum.add(a, b)

# The 16-bit one's-complement sum of bs (an odd final byte is padded with a
# zero), folded, not complemented: Csum.fold(Csum.sum(bs)).
def Csum.sum(bs: +List<U32>) -> U32:
  +bs = bs
  +n = List.length(&2, U32, bs)
  Csum.par(24n, Csum.small(n), n, bs)

# The Internet checksum of bs: the complement of the folded sum, in 0..65535.
def Csum.of(bs: +List<U32>) -> U32:
  (65535 .^. Csum.sum(bs) : U32)

# Some{x} when ok, else None.
def Wire.when(-A: Data, ok: Bool, x: A) -> Maybe<&2, A>:
  match ok:
    case True{}:
      Some{x}
    case False{}:
      None{}

# The byte at off (0 past the end).
def Wire.u8(bs: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_be(1n, List.drop(&2, U32, bs, off))

# The big-endian 16-bit field at off.
def Wire.u16(bs: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_be(2n, List.drop(&2, U32, bs, off))

def Wire.u32(bs: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_be32(List.drop(&2, U32, bs, off))

def Wire.be16(x: U32) -> +List<U32>:
  B.Bytes.be(2n, x)

def Wire.len(bs: +List<U32>) -> Nat:
  List.length(&2, U32, bs)

def Wire.cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

# The IPv4 pseudo-header of a TCP or UDP checksum.
def Wire.pseudo(src: U32, dst: U32, proto: U32, len: U32) -> +List<U32>:
  Wire.cat(B.Bytes.be32(src), Wire.cat(B.Bytes.be32(dst), Wire.cat([0, (proto .&. 255 : U32)], Wire.be16(len))))

# Ethernet II: dst MAC, src MAC, ethertype (2048 IPv4, 2054 ARP), payload.
type Eth is Data:
  Eth{dst: +List<U32>, src: +List<U32>, ethertype: U32, payload: +List<U32>}

def Eth.parse(frame: +List<U32>) -> Maybe<&2, Eth>:
  +frame = frame
  e = {Eth{B.Bytes.slice(frame, 0n, 6n), B.Bytes.slice(frame, 6n, 6n), Wire.u16(frame, 12n), List.drop(&2, U32, frame, 14n)} : Eth}
  Wire.when(Eth, Nat.is_le(14n, Wire.len(frame)), e)

def Eth.build(e: Eth) -> +List<U32>:
  match e:
    case Eth{dst, src, ethertype, payload}:
      Wire.cat(dst, Wire.cat(src, Wire.cat(Wire.be16(ethertype), payload)))

# ARP for IPv4 over Ethernet (htype 1, ptype 2048, hlen 6, plen 4); op 1
# request, 2 reply.
type Arp is Data:
  Arp{op: U32, sha: +List<U32>, spa: U32, tha: +List<U32>, tpa: U32}

# The fixed prefix: htype 1, ptype 0x0800, hlen 6, plen 4 (read as
# 0x0001_0800 = 67584 and 0x0604 = 1540).
def Arp.prefix() -> +List<U32>:
  [0, 1, 8, 0, 6, 4]

def Arp.parse(bs: +List<U32>) -> Maybe<&2, Arp>:
  +bs = bs
  ok = Nat.is_le(28n, Wire.len(bs)) && U32.is_eq(Wire.u32(bs, 0n), 67584) && U32.is_eq(Wire.u16(bs, 4n), 1540)
  a = {Arp{Wire.u16(bs, 6n), B.Bytes.slice(bs, 8n, 6n), Wire.u32(bs, 14n), B.Bytes.slice(bs, 18n, 6n), Wire.u32(bs, 24n)} : Arp}
  Wire.when(Arp, ok, a)

def Arp.build(a: Arp) -> +List<U32>:
  match a:
    case Arp{op, sha, spa, tha, tpa}:
      Wire.cat(Arp.prefix(), Wire.cat(Wire.be16(op), Wire.cat(sha, Wire.cat(B.Bytes.be32(spa), Wire.cat(tha, B.Bytes.be32(tpa))))))

# IPv4 without options on build (IHL 5, TOS 0, flags DF, fragment offset 0);
# parse skips any options and drops bytes past total length. proto: 1 ICMP,
# 6 TCP, 17 UDP.
type Ipv4 is Data:
  Ipv4{src: U32, dst: U32, proto: U32, ttl: U32, id: U32, payload: +List<U32>}

def Ipv4.parse(bs: +List<U32>) -> Maybe<&2, Ipv4>:
  +bs = bs
  +b0 = Wire.u8(bs, 0n)
  +hl = Nat.mul(4n, U32.to_nat((b0 .&. 15 : U32)))
  +total = U32.to_nat(Wire.u16(bs, 2n))
  ok = Nat.is_le(20n, Wire.len(bs)) && U32.is_eq((b0 >> 4n : U32), 4) && Nat.is_le(20n, hl) && Nat.is_le(hl, total) && Nat.is_le(total, Wire.len(bs))
  p = {Ipv4{Wire.u32(bs, 12n), Wire.u32(bs, 16n), Wire.u8(bs, 9n), Wire.u8(bs, 8n), Wire.u16(bs, 4n), B.Bytes.slice(bs, hl, Nat.sub(total, hl))} : Ipv4}
  Wire.when(Ipv4, ok, p)

# The 20-byte header with the given checksum field.
def Ipv4.header(+p: Ipv4, csum: U32) -> +List<U32>:
  match p:
    case Ipv4{src, dst, proto, ttl, id, payload}:
      +len = (20 + U32.from_nat(Wire.len(payload)) : U32)
      head = Wire.cat([69, 0], Wire.cat(Wire.be16(len), Wire.cat(Wire.be16(id), [64, 0, (ttl .&. 255 : U32), (proto .&. 255 : U32)])))
      Wire.cat(head, Wire.cat(Wire.be16(csum), Wire.cat(B.Bytes.be32(src), B.Bytes.be32(dst))))

def Ipv4.payload(p: Ipv4) -> +List<U32>:
  match p:
    case Ipv4{src, dst, proto, ttl, id, payload}:
      payload

def Ipv4.build(p: Ipv4) -> +List<U32>:
  +p = p
  Wire.cat(Ipv4.header(p, Csum.of(Ipv4.header(p, 0))), Ipv4.payload(p))

# ICMP: kind is the ICMP type (0 echo reply, 8 echo request), code, and the rest of the
# message after the checksum (for echo: id, sequence, data).
type Icmp is Data:
  Icmp{kind: U32, code: U32, rest: +List<U32>}

def Icmp.parse(bs: +List<U32>) -> Maybe<&2, Icmp>:
  +bs = bs
  m = {Icmp{Wire.u8(bs, 0n), Wire.u8(bs, 1n), List.drop(&2, U32, bs, 4n)} : Icmp}
  Wire.when(Icmp, Nat.is_le(4n, Wire.len(bs)), m)

def Icmp.build(m: Icmp) -> +List<U32>:
  match m:
    case Icmp{kind, code, rest}:
      +head = {[(kind .&. 255 : U32), (code .&. 255 : U32)] : +List<U32>}
      +rest = rest
      Wire.cat(head, Wire.cat(Wire.be16(Csum.of(Wire.cat(head, Wire.cat([0, 0], rest)))), rest))

type Udp is Data:
  Udp{sport: U32, dport: U32, payload: +List<U32>}

# Parse drops bytes past the length field.
def Udp.parse(bs: +List<U32>) -> Maybe<&2, Udp>:
  +bs = bs
  +len = U32.to_nat(Wire.u16(bs, 4n))
  ok = Nat.is_le(8n, Wire.len(bs)) && Nat.is_le(8n, len) && Nat.is_le(len, Wire.len(bs))
  u = {Udp{Wire.u16(bs, 0n), Wire.u16(bs, 2n), B.Bytes.slice(bs, 8n, Nat.sub(len, 8n))} : Udp}
  Wire.when(Udp, ok, u)

# 0 is sent as 65535: a UDP checksum of 0 means none.
def Udp.nonzero(+c: U32) -> U32:
  Bool.pick(U32, U32.is_zero(c), 65535, c)

# The UDP datagram with its checksum over the IPv4 pseudo-header of src, dst
# (a computed checksum of 0 is sent as 65535).
def Udp.build(src: U32, dst: U32, u: Udp) -> +List<U32>:
  match u:
    case Udp{sport, dport, payload}:
      +payload = payload
      +len = (8 + U32.from_nat(Wire.len(payload)) : U32)
      +ports = Wire.cat(Wire.be16(sport), Wire.be16(dport))
      c = Udp.nonzero(Csum.of(Wire.cat(Wire.pseudo(src, dst, 17, len), Wire.cat(ports, Wire.cat(Wire.be16(len), Wire.cat([0, 0], payload))))))
      Wire.cat(ports, Wire.cat(Wire.be16(len), Wire.cat(Wire.be16(c), payload)))

# TCP flags: FIN 1, SYN 2, RST 4, PSH 8, ACK 16. mss is the MSS option: on
# parse, the value of an MSS option if present else 0; on build, an MSS option
# is emitted when mss != 0 (data offset 6), else none (data offset 5).
type Tcp is Data:
  Tcp{sport: U32, dport: U32, seq: U32, ack: U32, flags: U32, window: U32, mss: U32, payload: +List<U32>}

# The first option of an option list.
type TcpOpt is Data:
  OptEnd{}
  OptBad{}
  OptSkip{size: Nat}
  OptMss{value: U32}

# A kind with a length byte l: bad when l < 2 or past the options.
def Tcp.opt.sized(ok: Bool, mss: Bool, +l: U32, value: U32) -> TcpOpt:
  match ok:
    case False{}:
      OptBad{}
    case True{}:
      Bool.pick(TcpOpt, mss, OptMss{value}, OptSkip{U32.to_nat(l)})

def Tcp.opt(+opts: +List<U32>) -> TcpOpt:
  +k = Wire.u8(opts, 0n)
  +l = Wire.u8(opts, 1n)
  +n = Wire.len(opts)
  ok = Nat.is_le(2n, n) && U32.is_le(2, l) && Nat.is_le(U32.to_nat(l), n)
  sized = Tcp.opt.sized(ok, U32.is_eq(k, 2) && U32.is_eq(l, 4), l, Wire.u16(opts, 2n))
  Bool.pick(TcpOpt, Nat.is_eq(n, 0n) || U32.is_zero(k), OptEnd{}, Bool.pick(TcpOpt, U32.is_eq(k, 1), OptSkip{1n}, sized))

# Walks the options from o, the first of opts; mss is the last MSS seen.
# Each step consumes at least one byte, so the fuel is the options' length.
def Tcp.opts(fuel: Nat, o: TcpOpt, +opts: +List<U32>, mss: U32) -> Maybe<&2, U32>:
  match fuel:
    case 0n:
      Some{mss}
    case 1n+p:
      match o:
        case OptEnd{}:
          Some{mss}
        case OptBad{}:
          None{}
        case OptSkip{size}:
          +r = List.drop(&2, U32, opts, size)
          Tcp.opts(p, Tcp.opt(r), r, mss)
        case OptMss{value}:
          +r = List.drop(&2, U32, opts, 4n)
          Tcp.opts(p, Tcp.opt(r), r, value)

def Tcp.mss(+opts: +List<U32>) -> Maybe<&2, U32>:
  Tcp.opts(Wire.len(opts), Tcp.opt(opts), opts, 0)

def Tcp.make(+bs: +List<U32>, hl: Nat, mss: U32) -> Maybe<&2, Tcp>:
  Some{Tcp{Wire.u16(bs, 0n), Wire.u16(bs, 2n), Wire.u32(bs, 4n), Wire.u32(bs, 8n), Wire.u8(bs, 13n), Wire.u16(bs, 14n), mss, List.drop(&2, U32, bs, hl)}}

# Parse answers None for a bad data offset or a malformed option (a length
# byte below 2 or past the header).
def Tcp.parse(bs: +List<U32>) -> Maybe<&2, Tcp>:
  +bs = bs
  +hl = Nat.mul(4n, U32.to_nat((Wire.u8(bs, 12n) >> 4n : U32)))
  ok = Nat.is_le(20n, Wire.len(bs)) && Nat.is_le(20n, hl) && Nat.is_le(hl, Wire.len(bs))
  do Maybe<&2, Tcp>:
    hdr : Unit <- Wire.when(Unit, ok, Unit{})
    mss : U32 <- Tcp.mss(B.Bytes.slice(bs, 20n, Nat.sub(hl, 20n)))
    Tcp.make(bs, hl, mss)

# The MSS option, if any.
def Tcp.options(+mss: U32) -> +List<U32>:
  Bool.pick(+List<U32>, U32.is_zero(mss), [], Wire.cat([2, 4], Wire.be16(mss)))

# The header with the given checksum field.
def Tcp.header(+t: Tcp, csum: U32) -> +List<U32>:
  match t:
    case Tcp{sport, dport, seq, ack, flags, window, mss, payload}:
      +opts = Tcp.options(mss)
      +off = (U32.from_nat(Nat.add(5n, Nat.div(Wire.len(opts), 4n))) << 4n : U32)
      head = Wire.cat(Wire.be16(sport), Wire.cat(Wire.be16(dport), Wire.cat(B.Bytes.be32(seq), B.Bytes.be32(ack))))
      Wire.cat(head, Wire.cat([off, (flags .&. 255 : U32)], Wire.cat(Wire.be16(window), Wire.cat(Wire.be16(csum), Wire.cat([0, 0], opts)))))

def Tcp.payload(t: Tcp) -> +List<U32>:
  match t:
    case Tcp{sport, dport, seq, ack, flags, window, mss, payload}:
      payload

# The TCP segment with its checksum over the IPv4 pseudo-header of src, dst.
def Tcp.build(src: U32, dst: U32, t: Tcp) -> +List<U32>:
  +t = t
  +payload = Tcp.payload(t)
  +h0 = Tcp.header(t, 0)
  +len = U32.from_nat(Nat.add(Wire.len(h0), Wire.len(payload)))
  c = Csum.of(Wire.cat(Wire.pseudo(src, dst, 6, len), Wire.cat(h0, payload)))
  Wire.cat(Tcp.header(t, c), payload)

# A frame whose payload stays on the host: [256, conn, len] then its
# headers. 256 is no byte, so such a frame is never a plain one. The device
# writes the headers and has the host move the len bytes it holds for TCP
# connection conn right after them (V.VmNetToRam): the payload never passes
# through Bend.
def Wire.host_tag() -> U32:
  256

def Wire.host_frame(conn: U32, len: U32, head: +List<U32>) -> +List<U32>:
  Wire.host_tag() <> conn <> len <> head

def Wire.is_host_frame(f: +List<U32>) -> Bool:
  match f:
    case Nil{}:
      False{}
    case x <> t:
      U32.is_eq(x, Wire.host_tag())

# The 20-byte IPv4 header (IHL 5, flags DF, id 0, TTL 64) of a packet with
# len bytes after the header, with its checksum.
def Ipv4.head(+src: U32, +dst: U32, +proto: U32, +len: U32) -> +List<U32>:
  +ttl_proto = {[64, 0, 64, (proto .&. 255 : U32)] : +List<U32>}
  +pre = Wire.cat([69, 0], Wire.cat(Wire.be16((20 + len : U32)), Wire.cat([0, 0], ttl_proto)))
  +addrs = Wire.cat(B.Bytes.be32(src), B.Bytes.be32(dst))
  Wire.cat(pre, Wire.cat(Wire.be16(Csum.of(Wire.cat(pre, Wire.cat([0, 0], addrs)))), addrs))
