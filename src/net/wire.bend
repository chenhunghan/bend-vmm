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

# The 16-bit one's-complement sum of bs (an odd final byte is padded with a
# zero), folded, not complemented: Csum.fold(Csum.sum(bs)).
def Csum.sum(bs: +List<U32>) -> U32:
  ?TODO

# Folds a 32-bit sum of 16-bit words to 16 bits (end-around carry).
def Csum.fold(x: U32) -> U32:
  ?TODO

# The Internet checksum of bs: the complement of the folded sum, in 0..65535.
def Csum.of(bs: +List<U32>) -> U32:
  ?TODO

# Ethernet II: dst MAC, src MAC, ethertype (2048 IPv4, 2054 ARP), payload.
type Eth is Data:
  Eth{dst: +List<U32>, src: +List<U32>, ethertype: U32, payload: +List<U32>}

def Eth.parse(frame: +List<U32>) -> Maybe<&2, Eth>:
  ?TODO

def Eth.build(e: Eth) -> +List<U32>:
  ?TODO

# ARP for IPv4 over Ethernet (htype 1, ptype 2048, hlen 6, plen 4); op 1
# request, 2 reply.
type Arp is Data:
  Arp{op: U32, sha: +List<U32>, spa: U32, tha: +List<U32>, tpa: U32}

def Arp.parse(bs: +List<U32>) -> Maybe<&2, Arp>:
  ?TODO

def Arp.build(a: Arp) -> +List<U32>:
  ?TODO

# IPv4 without options on build (IHL 5, TOS 0, flags DF, fragment offset 0);
# parse skips any options and drops bytes past total length. proto: 1 ICMP,
# 6 TCP, 17 UDP.
type Ipv4 is Data:
  Ipv4{src: U32, dst: U32, proto: U32, ttl: U32, id: U32, payload: +List<U32>}

def Ipv4.parse(bs: +List<U32>) -> Maybe<&2, Ipv4>:
  ?TODO

def Ipv4.build(p: Ipv4) -> +List<U32>:
  ?TODO

# ICMP: kind is the ICMP type (0 echo reply, 8 echo request), code, and the rest of the
# message after the checksum (for echo: id, sequence, data).
type Icmp is Data:
  Icmp{kind: U32, code: U32, rest: +List<U32>}

def Icmp.parse(bs: +List<U32>) -> Maybe<&2, Icmp>:
  ?TODO

def Icmp.build(m: Icmp) -> +List<U32>:
  ?TODO

type Udp is Data:
  Udp{sport: U32, dport: U32, payload: +List<U32>}

def Udp.parse(bs: +List<U32>) -> Maybe<&2, Udp>:
  ?TODO

# The UDP datagram with its checksum over the IPv4 pseudo-header of src, dst
# (a computed checksum of 0 is sent as 65535).
def Udp.build(src: U32, dst: U32, u: Udp) -> +List<U32>:
  ?TODO

# TCP flags: FIN 1, SYN 2, RST 4, PSH 8, ACK 16. mss is the MSS option: on
# parse, the value of an MSS option if present else 0; on build, an MSS option
# is emitted when mss != 0 (data offset 6), else none (data offset 5).
type Tcp is Data:
  Tcp{sport: U32, dport: U32, seq: U32, ack: U32, flags: U32, window: U32, mss: U32, payload: +List<U32>}

def Tcp.parse(bs: +List<U32>) -> Maybe<&2, Tcp>:
  ?TODO

# The TCP segment with its checksum over the IPv4 pseudo-header of src, dst.
def Tcp.build(src: U32, dst: U32, t: Tcp) -> +List<U32>:
  ?TODO
