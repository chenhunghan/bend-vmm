import Base
import ../src/lib/bytes.bend as B
import ../src/net/wire.bend as W

# Frozen spec for src/net/wire.bend. Expected bytes come from an independent
# encoder; the checksum vectors are RFC 1071's example and the well-known IPv4
# header whose checksum is 0xb861. Addresses: guest 10.0.2.15 = 167772687,
# gateway 10.0.2.2 = 167772674, DNS 10.0.2.3 = 167772675.

def guest_mac() -> +List<U32>:
  [82, 84, 0, 18, 52, 86]

law wire.rfc1071_sum:
  # 00 01 f2 03 f4 f5 f6 f7 sums to 0xddf2
  {W.Csum.sum([0, 1, 242, 3, 244, 245, 246, 247]) == 56818 : U32}

law wire.rfc1071_checksum:
  {W.Csum.of([0, 1, 242, 3, 244, 245, 246, 247]) == 8717 : U32}

law wire.checksum_odd_length:
  {W.Csum.of([1, 2, 3]) == 64509 : U32}

law wire.fold:
  # 0x2_ffff folds to 0x2 + 0xffff = 0x1_0001, then to 2
  {W.Csum.fold(196607) == 2 : U32}

law wire.ipv4_header:
  # 192.168.0.1 -> 192.168.0.199, UDP, TTL 64, id 0, 95 payload bytes
  {B.Bytes.slice(W.Ipv4.build(W.Ipv4{3232235521, 3232235719, 17, 64, 0, B.Bytes.zeros(95n)}), 0n, 20n) == [69, 0, 0, 115, 0, 0, 64, 0, 64, 17, 184, 97, 192, 168, 0, 1, 192, 168, 0, 199] : +List<U32>}

law wire.ipv4_roundtrip:
  {W.Ipv4.parse(W.Ipv4.build(W.Ipv4{167772687, 167772674, 6, 64, 7, [1, 2, 3]})) == Some{W.Ipv4{167772687, 167772674, 6, 64, 7, [1, 2, 3]}} : Maybe<&2, W.Ipv4>}

law wire.ipv4_short:
  {W.Ipv4.parse([69, 0, 0]) == None{} : Maybe<&2, W.Ipv4>}

law wire.ipv4_not_v4:
  {W.Ipv4.parse(List.set(&2, U32, W.Ipv4.build(W.Ipv4{1, 2, 17, 64, 0, []}), 0n, 101)) == None{} : Maybe<&2, W.Ipv4>}

law wire.udp:
  # 10.0.2.15:33000 -> 10.0.2.3:53, payload "abc"
  {W.Udp.build(167772687, 167772675, W.Udp{33000, 53, [97, 98, 99]}) == [128, 232, 0, 53, 0, 11, 162, 70, 97, 98, 99] : +List<U32>}

law wire.udp_roundtrip:
  {W.Udp.parse([128, 232, 0, 53, 0, 11, 162, 70, 97, 98, 99]) == Some{W.Udp{33000, 53, [97, 98, 99]}} : Maybe<&2, W.Udp>}

law wire.tcp_syn:
  # 10.0.2.15:40000 -> 10.0.2.2:80, seq 1000, SYN, window 65535, MSS 1460
  {W.Tcp.build(167772687, 167772674, W.Tcp{40000, 80, 1000, 0, 2, 65535, 1460, []}) == [156, 64, 0, 80, 0, 0, 3, 232, 0, 0, 0, 0, 96, 2, 255, 255, 223, 157, 0, 0, 2, 4, 5, 180] : +List<U32>}

law wire.tcp_data:
  # 10.0.2.2:80 -> 10.0.2.15:40000, seq 5000, ack 1001, PSH|ACK, "hi"
  {W.Tcp.build(167772674, 167772687, W.Tcp{80, 40000, 5000, 1001, 24, 65535, 0, [104, 105]}) == [0, 80, 156, 64, 0, 0, 19, 136, 0, 0, 3, 233, 80, 24, 255, 255, 123, 79, 0, 0, 104, 105] : +List<U32>}

law wire.tcp_parse_syn:
  {W.Tcp.parse([156, 64, 0, 80, 0, 0, 3, 232, 0, 0, 0, 0, 96, 2, 255, 255, 223, 157, 0, 0, 2, 4, 5, 180]) == Some{W.Tcp{40000, 80, 1000, 0, 2, 65535, 1460, []}} : Maybe<&2, W.Tcp>}

law wire.icmp_echo_reply:
  # id 7, sequence 1, data "ab"
  {W.Icmp.build(W.Icmp{0, 0, [0, 7, 0, 1, 97, 98]}) == [0, 0, 158, 149, 0, 7, 0, 1, 97, 98] : +List<U32>}

law wire.arp_request:
  # who-has 10.0.2.2 tell 10.0.2.15
  {W.Arp.build(W.Arp{1, guest_mac(), 167772687, [0, 0, 0, 0, 0, 0], 167772674}) == [0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2] : +List<U32>}

law wire.arp_parse:
  {W.Arp.parse([0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2]) == Some{W.Arp{1, guest_mac(), 167772687, [0, 0, 0, 0, 0, 0], 167772674}} : Maybe<&2, W.Arp>}

law wire.eth:
  {W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], guest_mac(), 2054, [0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2]}) == [255, 255, 255, 255, 255, 255, 82, 84, 0, 18, 52, 86, 8, 6, 0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2] : +List<U32>}

law wire.eth_parse:
  {W.Eth.parse([255, 255, 255, 255, 255, 255, 82, 84, 0, 18, 52, 86, 8, 6, 0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2]) == Some{W.Eth{[255, 255, 255, 255, 255, 255], guest_mac(), 2054, [0, 1, 8, 0, 6, 4, 0, 1, 82, 84, 0, 18, 52, 86, 10, 0, 2, 15, 0, 0, 0, 0, 0, 0, 10, 0, 2, 2]}} : Maybe<&2, W.Eth>}

law wire.eth_short:
  {W.Eth.parse([1, 2, 3]) == None{} : Maybe<&2, W.Eth>}
