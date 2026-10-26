import Base
import ../src/lib/bytes.bend as B
import ../src/net/wire.bend as W
import ./t.bend as T

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def none(-A: Data, m: Maybe<&2, A>) -> Bool:
  Bool.not(Maybe.is_some(&2, A, m))

# Each parse result rebuilt to bytes; None shows as [999].
def eth_bytes(m: Maybe<&2, W.Eth>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{e}:
      W.Eth.build(e)

def arp_bytes(m: Maybe<&2, W.Arp>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{a}:
      W.Arp.build(a)

def ip_bytes(m: Maybe<&2, W.Ipv4>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{p}:
      W.Ipv4.build(p)

def ip_payload(m: Maybe<&2, W.Ipv4>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{W.Ipv4{s, d, pr, ttl, id, pl}}:
      pl

def ip_fields(m: Maybe<&2, W.Ipv4>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{W.Ipv4{s, d, pr, ttl, id, pl}}:
      [s, d, pr, ttl, id]

def icmp_bytes(m: Maybe<&2, W.Icmp>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{c}:
      W.Icmp.build(c)

def udp_bytes(src: U32, dst: U32, m: Maybe<&2, W.Udp>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{u}:
      W.Udp.build(src, dst, u)

def tcp_bytes(src: U32, dst: U32, m: Maybe<&2, W.Tcp>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{t}:
      W.Tcp.build(src, dst, t)

def tcp_fields(m: Maybe<&2, W.Tcp>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{W.Tcp{sp, dp, seq, ack, fl, win, mss, pl}}:
      List.append(&2, U32, [sp, dp, seq, ack, fl, win, mss], pl)

# The checksum by the textbook loop: sum all 16-bit words in 32 bits, fold.
def ref_sum(bs: +List<U32>) -> U32:
  match bs:
    case Nil{}:
      0
    case Con{a, Nil{}}:
      (a << 8n : U32)
    case Con{a, Con{b, t}}:
      ((a << 8n) + b + ref_sum(t) : U32)

def ref_of(+bs: +List<U32>) -> U32:
  (65535 .^. W.Csum.fold(ref_sum(bs)) : U32)

# n pseudo-random bytes.
def noise(n: Nat, seed: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +s = (seed * 1103515245 + 12345 : U32)
      ((s >> 16n) .&. 255 : U32) <> noise(p, s)

def ip_hdr() -> +List<U32>:
  [69, 0, 0, 23, 0, 7, 64, 0, 64, 6, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 1, 2, 3]

# IPv4 with 4 bytes of options (IHL 6, two NOPs and an EOL pad), total 27, and
# two trailing bytes of Ethernet padding past the total length.
def ip_opts() -> +List<U32>:
  [70, 0, 0, 27, 0, 9, 64, 0, 32, 17, 0, 0, 10, 0, 2, 15, 10, 0, 2, 3, 1, 1, 0, 0, 7, 8, 9, 0, 0]

def syn() -> +List<U32>:
  [156, 64, 0, 80, 0, 0, 3, 232, 0, 0, 0, 0, 96, 2, 255, 255, 223, 157, 0, 0, 2, 4, 5, 180]

# A SYN with options NOP, SACK-permitted, window scale 7, MSS 1400 and
# timestamps: data offset 10 (40 bytes), then 2 data bytes.
def syn_opts() -> +List<U32>:
  [156, 64, 0, 80, 0, 0, 3, 232, 0, 0, 0, 0, 160, 2, 255, 255, 0, 0, 0, 0,
   1, 4, 2, 3, 3, 7, 2, 4, 5, 120, 8, 10, 0, 0, 0, 1, 0, 0, 0, 0,
   88, 89]

def tcp_hdr(off: U32, opts: +List<U32>) -> +List<U32>:
  List.append(&2, U32, [0, 1, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, off, 16, 1, 0, 0, 0, 0, 0], opts)

def eth_checks() -> IO(Unit):
  +arp = W.Arp.build(W.Arp{2, [1, 2, 3, 4, 5, 6], 167772674, [82, 84, 0, 18, 52, 86], 167772687})
  +f = W.Eth.build(W.Eth{[82, 84, 0, 18, 52, 86], [1, 2, 3, 4, 5, 6], 2054, arp})
  do IO<Unit>:
    T.ok("eth empty", none(W.Eth, W.Eth.parse([])))
    T.ok("eth 13 bytes", none(W.Eth, W.Eth.parse(B.Bytes.zeros(13n))))
    T.eq_str("eth header only", show(eth_bytes(W.Eth.parse(B.Bytes.zeros(14n)))), show(B.Bytes.zeros(14n)))
    T.eq_str("eth roundtrip", show(eth_bytes(W.Eth.parse(f))), show(f))
    T.eq_str("arp reply bytes", show(arp), "[0, 1, 8, 0, 6, 4, 0, 2, 1, 2, 3, 4, 5, 6, 10, 0, 2, 2, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15]")
    T.eq_str("arp roundtrip", show(arp_bytes(W.Arp.parse(arp))), show(arp))
    T.eq_str("arp trailing pad", show(arp_bytes(W.Arp.parse(List.append(&2, U32, arp, B.Bytes.zeros(18n))))), show(arp))
    T.ok("arp empty", none(W.Arp, W.Arp.parse([])))
    T.ok("arp 27 bytes", none(W.Arp, W.Arp.parse(List.take(&2, U32, arp, 27n))))
    T.ok("arp htype 6", none(W.Arp, W.Arp.parse(List.set(&2, U32, arp, 1n, 6))))
    T.ok("arp ptype ipv6", none(W.Arp, W.Arp.parse(List.set(&2, U32, arp, 2n, 134))))
    T.ok("arp hlen 8", none(W.Arp, W.Arp.parse(List.set(&2, U32, arp, 4n, 8))))
    T.ok("arp plen 16", none(W.Arp, W.Arp.parse(List.set(&2, U32, arp, 5n, 16))))

def csum_checks() -> IO(Unit):
  +big = noise(1500n, 7)
  +odd = noise(1001n, 3)
  do IO<Unit>:
    T.eq_u32("csum empty", W.Csum.of([]), 65535)
    T.eq_u32("csum one byte", W.Csum.of([171]), 21759)
    T.eq_u32("csum odd 5", W.Csum.of([1, 2, 3, 4, 5]), 63225)
    T.eq_u32("csum sum odd", W.Csum.sum([255, 255, 255]), 65280)
    T.eq_u32("csum all ones", W.Csum.of([255, 255, 255, 255]), 0)
    T.eq_u32("fold small", W.Csum.fold(1234), 1234)
    T.eq_u32("fold 0xffffffff", W.Csum.fold(4294967295), 65535)
    T.eq_u32("csum 1500 parallel", W.Csum.of(big), ref_of(big))
    T.eq_u32("csum 1001 odd parallel", W.Csum.of(odd), ref_of(odd))
    T.eq_u32("csum verifies to 0", W.Csum.of(List.append(&2, U32, List.append(&2, U32, odd, [0]), B.Bytes.be(2n, W.Csum.of(odd)))), 0)

def ip_checks() -> IO(Unit):
  +p = W.Ipv4.build(W.Ipv4{167772674, 167772687, 1, 255, 65535, noise(300n, 5)})
  do IO<Unit>:
    T.eq_str("ipv4 roundtrip 300", show(ip_bytes(W.Ipv4.parse(p))), show(p))
    T.eq_u32("ipv4 header checks", W.Csum.of(List.take(&2, U32, p, 20n)), 0)
    T.eq_str("ipv4 empty payload", show(ip_bytes(W.Ipv4.parse(W.Ipv4.build(W.Ipv4{1, 2, 17, 64, 0, []})))), show(W.Ipv4.build(W.Ipv4{1, 2, 17, 64, 0, []})))
    T.eq_str("ipv4 fields", show(ip_fields(W.Ipv4.parse(ip_hdr()))), "[167772687, 167772674, 6, 64, 7]")
    T.eq_str("ipv4 options skipped", show(ip_payload(W.Ipv4.parse(ip_opts()))), "[7, 8, 9]")
    T.eq_str("ipv4 options fields", show(ip_fields(W.Ipv4.parse(ip_opts()))), "[167772687, 167772675, 17, 32, 9]")
    T.eq_str("ipv4 drops bytes past total", show(ip_payload(W.Ipv4.parse(List.append(&2, U32, ip_hdr(), [4, 5])))), "[1, 2, 3]")
    T.ok("ipv4 empty", none(W.Ipv4, W.Ipv4.parse([])))
    T.ok("ipv4 19 bytes", none(W.Ipv4, W.Ipv4.parse(List.take(&2, U32, ip_hdr(), 19n))))
    T.ok("ipv4 total past data", none(W.Ipv4, W.Ipv4.parse(List.take(&2, U32, ip_hdr(), 22n))))
    T.ok("ipv4 ihl 4", none(W.Ipv4, W.Ipv4.parse(List.set(&2, U32, ip_hdr(), 0n, 68))))
    T.ok("ipv4 ihl 0", none(W.Ipv4, W.Ipv4.parse(List.set(&2, U32, ip_hdr(), 0n, 64))))
    T.ok("ipv4 version 6", none(W.Ipv4, W.Ipv4.parse(List.set(&2, U32, ip_hdr(), 0n, 96))))
    T.ok("ipv4 ihl past total", none(W.Ipv4, W.Ipv4.parse(List.set(&2, U32, ip_hdr(), 0n, 79))))
    T.ok("ipv4 total < 20", none(W.Ipv4, W.Ipv4.parse(List.set(&2, U32, ip_hdr(), 3n, 19))))
    T.ok("ipv4 options truncated", none(W.Ipv4, W.Ipv4.parse(List.take(&2, U32, ip_opts(), 22n))))

def l4_checks() -> IO(Unit):
  +u = W.Udp.build(167772687, 167772675, W.Udp{68, 67, noise(333n, 9)})
  +t = W.Tcp.build(167772674, 167772687, W.Tcp{80, 40000, 4294967295, 7, 17, 512, 0, noise(77n, 11)})
  do IO<Unit>:
    T.eq_str("icmp roundtrip", show(icmp_bytes(W.Icmp.parse([8, 0, 0, 0, 1, 2, 3]))), show(W.Icmp.build(W.Icmp{8, 0, [1, 2, 3]})))
    T.eq_u32("icmp odd checks", W.Csum.of(W.Icmp.build(W.Icmp{8, 0, [0, 7, 0, 1, 97]})), 0)
    T.eq_str("icmp header only", show(icmp_bytes(W.Icmp.parse([3, 3, 0, 0]))), show(W.Icmp.build(W.Icmp{3, 3, []})))
    T.ok("icmp empty", none(W.Icmp, W.Icmp.parse([])))
    T.ok("icmp 3 bytes", none(W.Icmp, W.Icmp.parse([8, 0, 0])))
    T.eq_str("udp roundtrip odd", show(udp_bytes(167772687, 167772675, W.Udp.parse(u))), show(u))
    T.eq_str("udp drops trailing", show(udp_bytes(167772687, 167772675, W.Udp.parse([128, 232, 0, 53, 0, 11, 162, 70, 97, 98, 99, 0, 0]))), "[128, 232, 0, 53, 0, 11, 162, 70, 97, 98, 99]")
    T.eq_str("udp zero csum sent as ffff", show(W.Udp.build(0, 0, W.Udp{0, 0, [255, 218]})), "[0, 0, 0, 0, 0, 10, 255, 255, 255, 218]")
    T.ok("udp empty", none(W.Udp, W.Udp.parse([])))
    T.ok("udp 7 bytes", none(W.Udp, W.Udp.parse([0, 1, 0, 2, 0, 8, 0])))
    T.ok("udp length past data", none(W.Udp, W.Udp.parse([0, 1, 0, 2, 0, 12, 0, 0, 1, 2, 3])))
    T.ok("udp length < 8", none(W.Udp, W.Udp.parse([0, 1, 0, 2, 0, 7, 0, 0, 1])))
    T.eq_str("tcp roundtrip syn", show(tcp_bytes(167772687, 167772674, W.Tcp.parse(syn()))), show(syn()))
    T.eq_str("tcp roundtrip data", show(tcp_bytes(167772674, 167772687, W.Tcp.parse(t))), show(t))
    T.eq_str("tcp other options", show(tcp_fields(W.Tcp.parse(syn_opts()))), "[40000, 80, 1000, 0, 2, 65535, 1400, 88, 89]")
    T.eq_str("tcp no mss", show(tcp_fields(W.Tcp.parse(tcp_hdr(96, [1, 3, 3, 7])))), "[1, 2, 3, 4, 16, 256, 0]")
    T.eq_str("tcp eol stops options", show(tcp_fields(W.Tcp.parse(tcp_hdr(96, [0, 2, 4, 5])))), "[1, 2, 3, 4, 16, 256, 0]")
    T.ok("tcp empty", none(W.Tcp, W.Tcp.parse([])))
    T.ok("tcp 19 bytes", none(W.Tcp, W.Tcp.parse(List.take(&2, U32, syn(), 19n))))
    T.ok("tcp offset 4", none(W.Tcp, W.Tcp.parse(tcp_hdr(64, []))))
    T.ok("tcp offset past data", none(W.Tcp, W.Tcp.parse(List.take(&2, U32, syn(), 22n))))
    T.ok("tcp option length 0", none(W.Tcp, W.Tcp.parse(tcp_hdr(96, [8, 0, 0, 0]))))
    T.ok("tcp option length 1", none(W.Tcp, W.Tcp.parse(tcp_hdr(96, [1, 8, 1, 0]))))
    T.ok("tcp option past header", none(W.Tcp, W.Tcp.parse(tcp_hdr(96, [1, 1, 3, 3]))))
    T.ok("tcp option kind without length", none(W.Tcp, W.Tcp.parse(tcp_hdr(96, [1, 1, 1, 3]))))

def main() -> IO(Unit):
  do IO<Unit>:
    csum_checks()
    eth_checks()
    ip_checks()
    l4_checks()
