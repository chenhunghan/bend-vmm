import Base
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/net/wire.bend as W
import ../src/net/nat.bend as N

# Frozen spec for src/net/nat.bend, stated with the wire builders. Guest
# 10.0.2.15:40000 talks to 1.2.3.4:80 (16909060).

def g() -> U32:
  167772687

def gw() -> U32:
  167772674

def remote() -> U32:
  16909060

def to_host(proto_payload: +List<U32>, dst: U32, proto: U32) -> +List<U32>:
  W.Eth.build(W.Eth{N.Slirp.gateway_mac(), N.Slirp.guest_mac(), 2048, W.Ipv4.build(W.Ipv4{g(), dst, proto, 64, 0, proto_payload})})

def to_guest(src: U32, proto: U32, proto_payload: +List<U32>) -> +List<U32>:
  W.Eth.build(W.Eth{N.Slirp.guest_mac(), N.Slirp.gateway_mac(), 2048, W.Ipv4.build(W.Ipv4{src, g(), proto, 64, 0, proto_payload})})

def guest_tcp(flags: U32, seq: U32, ack: U32, data: +List<U32>) -> +List<U32>:
  to_host(W.Tcp.build(g(), remote(), W.Tcp{40000, 80, seq, ack, flags, 65535, 0, data}), remote(), 6)

def host_tcp(flags: U32, seq: U32, ack: U32, mss: U32, data: +List<U32>) -> +List<U32>:
  to_guest(remote(), 6, W.Tcp.build(remote(), g(), W.Tcp{80, 40000, seq, ack, flags, 65535, mss, data}))

def frames(o: N.SlirpOut) -> +List<+List<U32>>:
  match o:
    case N.SlirpOut{n, fs, cs}:
      fs

def cmds(o: N.SlirpOut) -> +List<V.NetCmd>:
  match o:
    case N.SlirpOut{n, fs, cs}:
      cs

def net(o: N.SlirpOut) -> N.Slirp:
  match o:
    case N.SlirpOut{n, fs, cs}:
      n

# After the guest's SYN (seq 999).
def after_syn() -> N.Slirp:
  net(N.Slirp.guest_frame(N.Slirp.new(), guest_tcp(2, 999, 0, [])))

# After the host connected.
def established() -> N.Slirp:
  net(N.Slirp.host_event(after_syn(), V.TcpConnected{0}))

law nat.arp:
  {frames(N.Slirp.guest_frame(N.Slirp.new(), W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], N.Slirp.guest_mac(), 2054, W.Arp.build(W.Arp{1, N.Slirp.guest_mac(), g(), [0, 0, 0, 0, 0, 0], gw()})}))) == [W.Eth.build(W.Eth{N.Slirp.guest_mac(), N.Slirp.gateway_mac(), 2054, W.Arp.build(W.Arp{2, N.Slirp.gateway_mac(), gw(), N.Slirp.guest_mac(), g()})})] : +List<+List<U32>>}

law nat.ping_gateway:
  {frames(N.Slirp.guest_frame(N.Slirp.new(), to_host(W.Icmp.build(W.Icmp{8, 0, [0, 1, 0, 9, 120]}), gw(), 1))) == [to_guest(gw(), 1, W.Icmp.build(W.Icmp{0, 0, [0, 1, 0, 9, 120]}))] : +List<+List<U32>>}

law nat.udp_out:
  {cmds(N.Slirp.guest_frame(N.Slirp.new(), to_host(W.Udp.build(g(), 167772675, W.Udp{33000, 53, [7, 7]}), 167772675, 17))) == [V.UdpSend{33000, 167772675, 53, [7, 7]}] : +List<V.NetCmd>}

law nat.udp_in:
  {frames(N.Slirp.host_event(N.Slirp.new(), V.UdpData{167772675, 53, 33000, [8]})) == [to_guest(167772675, 17, W.Udp.build(167772675, g(), W.Udp{53, 33000, [8]}))] : +List<+List<U32>>}

law nat.syn_connects:
  {cmds(N.Slirp.guest_frame(N.Slirp.new(), guest_tcp(2, 999, 0, []))) == [V.TcpConnect{0, remote(), 80}] : +List<V.NetCmd>}

law nat.synack:
  {frames(N.Slirp.host_event(after_syn(), V.TcpConnected{0})) == [host_tcp(18, 1, 1000, 1460, [])] : +List<+List<U32>>}

law nat.refused:
  {frames(N.Slirp.host_event(after_syn(), V.TcpRefused{0})) == [host_tcp(20, 0, 1000, 0, [])] : +List<+List<U32>>}

law nat.guest_data:
  {cmds(N.Slirp.guest_frame(established(), guest_tcp(24, 1000, 2, [104, 105]))) == [V.TcpSend{0, [104, 105]}] : +List<V.NetCmd>}

law nat.guest_data_acked:
  {frames(N.Slirp.guest_frame(established(), guest_tcp(24, 1000, 2, [104, 105]))) == [host_tcp(16, 2, 1002, 0, [])] : +List<+List<U32>>}

law nat.out_of_order:
  {frames(N.Slirp.guest_frame(established(), guest_tcp(24, 1500, 2, [1]))) == [host_tcp(16, 2, 1000, 0, [])] : +List<+List<U32>>}

law nat.host_data:
  {frames(N.Slirp.host_event(established(), V.TcpData{0, [111, 107]})) == [host_tcp(24, 2, 1000, 0, [111, 107])] : +List<+List<U32>>}

law nat.host_eof:
  {frames(N.Slirp.host_event(established(), V.TcpEof{0})) == [host_tcp(17, 2, 1000, 0, [])] : +List<+List<U32>>}

law nat.guest_fin:
  {cmds(N.Slirp.guest_frame(established(), guest_tcp(17, 1000, 2, []))) == [V.TcpShutdown{0}] : +List<V.NetCmd>}

law nat.unknown_rst:
  {frames(N.Slirp.guest_frame(N.Slirp.new(), guest_tcp(16, 5, 77, []))) == [host_tcp(4, 77, 0, 0, [])] : +List<+List<U32>>}

# Proposed: flow control. The guest's window (its ACK plus its window
# field) bounds the host data the NAT sends; the rest waits for an ACK, and
# the FIN waits for the data.
def guest_ack(ack: U32, win: U32) -> +List<U32>:
  to_host(W.Tcp.build(g(), remote(), W.Tcp{40000, 80, 1000, ack, 16, win, 0, []}), remote(), 6)

def narrow() -> N.Slirp:
  net(N.Slirp.guest_frame(established(), guest_ack(2, 2)))

law nat.window_bounds_data:
  {frames(N.Slirp.host_event(narrow(), V.TcpData{0, [1, 2, 3]})) == [host_tcp(24, 2, 1000, 0, [1, 2])] : +List<+List<U32>>}

law nat.ack_opens_window:
  {frames(N.Slirp.guest_frame(net(N.Slirp.host_event(narrow(), V.TcpData{0, [1, 2, 3]})), guest_ack(4, 2))) == [host_tcp(24, 4, 1000, 0, [3])] : +List<+List<U32>>}

law nat.fin_waits_for_data:
  {frames(N.Slirp.host_event(net(N.Slirp.host_event(narrow(), V.TcpData{0, [1, 2, 3]})), V.TcpEof{0})) == [] : +List<+List<U32>>}

# Proposed: hardening against a malicious guest.

# Before the host connected (SynSent), a data segment sends nothing and
# changes nothing.
law nat.no_data_before_connect:
  {(cmds(N.Slirp.guest_frame(after_syn(), guest_tcp(24, 1000, 2, [104, 105]))), net(N.Slirp.guest_frame(after_syn(), guest_tcp(24, 1000, 2, [104, 105])))) == ([], after_syn()) : +List<V.NetCmd> & N.Slirp}

# n connections from guest ports 1 to n (none is 40000).
def busy(n: Nat) -> +List<N.Conn>:
  match n:
    case 0n:
      []
    case 1n+(+p):
      +i = U32.from_nat(p)
      N.Conn{i, (i + 1 : U32), remote(), 80, 1, 7, 9, N.Flow{9, 9, 9, 9, 0, [], False{}, 4294967295, 9, 0, 1}} <> busy(p)

# A SYN past N.Slirp.max_conns connections gets a RST|ACK and no connect.
law nat.syn_limit:
  {(frames(N.Slirp.guest_frame(N.Slirp{busy(256n), 256}, guest_tcp(2, 999, 0, []))), cmds(N.Slirp.guest_frame(N.Slirp{busy(256n), 256}, guest_tcp(2, 999, 0, [])))) == ([host_tcp(20, 0, 1000, 0, [])], []) : +List<+List<U32>> & +List<V.NetCmd>}

# A SYN to 169.254.169.254 (cloud metadata, 2852039166) gets a RST|ACK and
# no connect; a datagram to 127.0.0.1 (2130706433) or to 10.0.2.3 port 80 is
# dropped.
def syn_to(+dst: U32, port: U32) -> +List<U32>:
  to_host(W.Tcp.build(g(), dst, W.Tcp{40000, port, 999, 0, 2, 65535, 0, []}), dst, 6)

law nat.no_special_dst:
  {(frames(N.Slirp.guest_frame(N.Slirp.new(), syn_to(2852039166, 80))), cmds(N.Slirp.guest_frame(N.Slirp.new(), syn_to(2852039166, 80))), cmds(N.Slirp.guest_frame(N.Slirp.new(), to_host(W.Udp.build(g(), 2130706433, W.Udp{33000, 53, [7]}), 2130706433, 17))), cmds(N.Slirp.guest_frame(N.Slirp.new(), to_host(W.Udp.build(g(), 167772675, W.Udp{33000, 80, [7]}), 167772675, 17)))) == ([to_guest(2852039166, 6, W.Tcp.build(2852039166, g(), W.Tcp{80, 40000, 0, 1000, 20, 65535, 0, []}))], [], [], []) : +List<+List<U32>> & +List<V.NetCmd> & +List<V.NetCmd> & +List<V.NetCmd>}

def zeros(n: Nat) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      0 <> zeros(p)

# The host reads a connection on only while its queue toward the guest
# holds less than N.Slirp.queue_cap (256 KiB) bytes.
law nat.queue_bounded:
  {(N.Slirp.may_read(net(N.Slirp.host_event(narrow(), V.TcpData{0, zeros(262143n)})), 0), N.Slirp.may_read(net(N.Slirp.host_event(narrow(), V.TcpData{0, zeros(262144n)})), 0)) == (True{}, False{}) : Bool & Bool}

# While the host's socket is over its pending cap (TcpBlocked), guest data
# is not taken: no send, and an ACK of what came before with a zero window.
law nat.blocked_holds_data:
  {(cmds(N.Slirp.guest_frame(net(N.Slirp.host_event(established(), V.TcpBlocked{0})), guest_tcp(24, 1000, 2, [104, 105]))), frames(N.Slirp.guest_frame(net(N.Slirp.host_event(established(), V.TcpBlocked{0})), guest_tcp(24, 1000, 2, [104, 105])))) == ([], [to_guest(remote(), 6, W.Tcp.build(remote(), g(), W.Tcp{80, 40000, 2, 1000, 16, 0, 0, []}))]) : +List<V.NetCmd> & +List<+List<U32>>}
