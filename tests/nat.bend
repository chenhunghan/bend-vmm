import Base
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/net/wire.bend as W
import ../src/net/dhcp.bend as D
import ../src/net/nat.bend as N
import ./t.bend as T

# The guest 10.0.2.15 talks to 1.2.3.4 (16909060) port 80, from guest ports
# 40000 and 40001.

def g() -> U32:
  167772687

def gw() -> U32:
  167772674

def remote() -> U32:
  16909060

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def show_frames(fs: +List<+List<U32>>) -> String:
  List.show(~&2, ~+List<U32>, ~show, fs)

def show_cmd(c: V.NetCmd) -> String:
  match c:
    case V.TcpConnect{id, ip, port}:
      "connect " ++ U32.show(id) ++ " " ++ U32.show(ip) ++ ":" ++ U32.show(port)
    case V.TcpSend{id, bs}:
      "send " ++ U32.show(id) ++ " " ++ show(bs)
    case V.TcpShutdown{id}:
      "shutdown " ++ U32.show(id)
    case V.TcpClose{id}:
      "close " ++ U32.show(id)
    case V.UdpSend{sport, ip, port, bs}:
      "udp " ++ U32.show(sport) ++ " " ++ U32.show(ip) ++ ":" ++ U32.show(port) ++ " " ++ show(bs)

def show_cmds(cs: +List<V.NetCmd>) -> String:
  List.show(~&2, ~V.NetCmd, ~show_cmd, cs)

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

def conns(n: N.Slirp) -> U32:
  match n:
    case N.Slirp{cs, next}:
      U32.from_nat(List.length(&2, N.Conn, cs))

# Checks one step: the frames to the guest and the host commands.
def step(name: String, +o: N.SlirpOut, want_frames: +List<+List<U32>>, want_cmds: +List<V.NetCmd>) -> IO(Unit):
  +name = name
  do IO<Unit>:
    T.eq_str(name ++ " frames", show_frames(frames(o)), show_frames(want_frames))
    T.eq_str(name ++ " cmds", show_cmds(cmds(o)), show_cmds(want_cmds))

def to_host(+dst: U32, proto: U32, payload: +List<U32>) -> +List<U32>:
  W.Eth.build(W.Eth{N.Slirp.gateway_mac(), N.Slirp.guest_mac(), 2048, W.Ipv4.build(W.Ipv4{g(), dst, proto, 64, 0, payload})})

def to_guest(+src: U32, proto: U32, payload: +List<U32>) -> +List<U32>:
  W.Eth.build(W.Eth{N.Slirp.guest_mac(), N.Slirp.gateway_mac(), 2048, W.Ipv4.build(W.Ipv4{src, g(), proto, 64, 0, payload})})

# A segment from the guest's gport to 1.2.3.4:80, and one back.
def gtcp(gport: U32, flags: U32, seq: U32, ack: U32, data: +List<U32>) -> +List<U32>:
  to_host(remote(), 6, W.Tcp.build(g(), remote(), W.Tcp{gport, 80, seq, ack, flags, 65535, 0, data}))

def htcp(gport: U32, flags: U32, seq: U32, ack: U32, mss: U32, data: +List<U32>) -> +List<U32>:
  to_guest(remote(), 6, W.Tcp.build(remote(), g(), W.Tcp{80, gport, seq, ack, flags, 65535, mss, data}))

def gf(n: N.Slirp, frame: +List<U32>) -> N.SlirpOut:
  N.Slirp.guest_frame(n, frame)

def he(n: N.Slirp, ev: V.NetEvent) -> N.SlirpOut:
  N.Slirp.host_event(n, ev)

# n pseudo-random bytes.
def noise(n: Nat, seed: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +s = (seed * 1103515245 + 12345 : U32)
      ((s >> 16n) .&. 255 : U32) <> noise(p, s)

# SYN (seq 999) and the host's connect: the guest at gseq 1000, hseq 2.
def opened(n: N.Slirp, gport: U32, id: U32) -> N.Slirp:
  net(he(net(gf(n, gtcp(gport, 2, 999, 0, []))), V.TcpConnected{id}))

# Guest FIN first, then host EOF; 2000 bytes from the host cut at 1460.
def lifetime() -> IO(Unit):
  +big = noise(2000n, 7)
  +o1 = gf(N.Slirp.new(), gtcp(40000, 2, 999, 0, []))
  +o2 = he(net(o1), V.TcpConnected{0})
  +o3 = gf(net(o2), gtcp(40000, 16, 1000, 2, []))
  +o4 = gf(net(o3), gtcp(40000, 24, 1000, 2, [104, 101, 108, 108, 111]))
  +o5 = he(net(o4), V.TcpData{0, big})
  +o6 = gf(net(o5), gtcp(40000, 16, 1005, 2002, []))
  +o7 = gf(net(o6), gtcp(40000, 17, 1005, 2002, []))
  +o8 = he(net(o7), V.TcpEof{0})
  +o9 = gf(net(o8), gtcp(40000, 16, 1006, 2003, []))
  +seg1 = List.take(&2, U32, big, 1460n)
  +seg2 = List.drop(&2, U32, big, 1460n)
  do IO<Unit>:
    step("life syn", o1, [], [V.TcpConnect{0, remote(), 80}])
    step("life synack", o2, [htcp(40000, 18, 1, 1000, 1460, [])], [])
    step("life ack of synack", o3, [], [])
    step("life guest data", o4, [htcp(40000, 16, 2, 1005, 0, [])], [V.TcpSend{0, [104, 101, 108, 108, 111]}])
    step("life host data 2000", o5, [htcp(40000, 24, 2, 1005, 0, seg1), htcp(40000, 24, 1462, 1005, 0, seg2)], [])
    step("life ack of data", o6, [], [])
    step("life guest fin", o7, [htcp(40000, 16, 2002, 1006, 0, [])], [V.TcpShutdown{0}])
    step("life host eof", o8, [htcp(40000, 17, 2002, 1006, 0, [])], [V.TcpClose{0}])
    T.eq_u32("life forgotten", conns(net(o8)), 0)
    step("life last ack after close", o9, [htcp(40000, 4, 2003, 0, 0, [])], [])

# Host EOF first, then guest FIN.
def lifetime_reverse() -> IO(Unit):
  +o1 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, [1, 2, 3]})
  +o2 = he(net(o1), V.TcpEof{0})
  +o3 = gf(net(o2), gtcp(40000, 16, 1000, 6, []))
  +o4 = gf(net(o3), gtcp(40000, 24, 1000, 6, [9]))
  +o5 = gf(net(o4), gtcp(40000, 17, 1001, 6, []))
  do IO<Unit>:
    step("reverse host data", o1, [htcp(40000, 24, 2, 1000, 0, [1, 2, 3])], [])
    step("reverse host eof", o2, [htcp(40000, 17, 5, 1000, 0, [])], [])
    T.eq_u32("reverse half open", conns(net(o2)), 1)
    step("reverse ack of fin", o3, [], [])
    step("reverse guest data after eof", o4, [htcp(40000, 16, 6, 1001, 0, [])], [V.TcpSend{0, [9]}])
    step("reverse guest fin", o5, [htcp(40000, 16, 6, 1002, 0, [])], [V.TcpShutdown{0}, V.TcpClose{0}])
    T.eq_u32("reverse forgotten", conns(net(o5)), 0)

# Data and FIN in one segment.
def data_fin() -> IO(Unit):
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcp(40000, 25, 1000, 2, [7, 8]))
  do IO<Unit>:
    step("data and fin", o1, [htcp(40000, 16, 2, 1003, 0, [])], [V.TcpSend{0, [7, 8]}, V.TcpShutdown{0}])

# The PSH|ACK segments a reference cuts from data, seq advancing from seq.
def ref_segs(fuel: Nat, +gport: U32, +seq: U32, +ack: U32, +data: +List<U32>) -> +List<+List<U32>>:
  match fuel:
    case 0n:
      []
    case 1n+p:
      +d = List.take(&2, U32, data, 1460n)
      +rest = List.drop(&2, U32, data, 1460n)
      htcp(gport, 24, seq, ack, 0, d) <> ref_segs(p, gport, (seq + U32.from_nat(List.length(&2, U32, d)) : U32), ack, rest)

def host_sizes() -> IO(Unit):
  +big = noise(5000n, 11)
  +huge = noise(14600n, 13)
  +o1 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, big})
  +o2 = he(net(o1), V.TcpData{0, [1]})
  +o3 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, noise(1460n, 5)})
  +o4 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, noise(1461n, 5)})
  +o5 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, []})
  +o6 = he(opened(N.Slirp.new(), 40000, 0), V.TcpData{0, huge})
  do IO<Unit>:
    step("host data 5000", o1, ref_segs(4n, 40000, 2, 1000, big), [])
    T.eq_u32("host data 5000 segments", U32.from_nat(List.length(&2, +List<U32>, frames(o1))), 4)
    step("host data after 5000", o2, [htcp(40000, 24, 5002, 1000, 0, [1])], [])
    step("host data 1460", o3, [htcp(40000, 24, 2, 1000, 0, noise(1460n, 5))], [])
    step("host data 1461", o4, [htcp(40000, 24, 2, 1000, 0, noise(1460n, 5)), htcp(40000, 24, 1462, 1000, 0, List.drop(&2, U32, noise(1461n, 5), 1460n))], [])
    step("host data empty", o5, [], [])
    step("host data 14600", o6, ref_segs(10n, 40000, 2, 1000, huge), [])

def refused() -> IO(Unit):
  +o1 = he(net(gf(N.Slirp.new(), gtcp(40000, 2, 999, 0, []))), V.TcpRefused{0})
  +o2 = he(net(o1), V.TcpData{0, [1]})
  +o3 = gf(net(o1), gtcp(40000, 2, 999, 0, []))
  do IO<Unit>:
    step("refused", o1, [htcp(40000, 20, 0, 1000, 0, [])], [])
    T.eq_u32("refused forgotten", conns(net(o1)), 0)
    step("refused then data ignored", o2, [], [])
    step("refused then new syn", o3, [], [V.TcpConnect{1, remote(), 80}])

# Two connections at once, from guest ports 40000 (id 0) and 40001 (id 1).
def two() -> IO(Unit):
  +o1 = gf(N.Slirp.new(), gtcp(40000, 2, 999, 0, []))
  +o2 = gf(net(o1), gtcp(40001, 2, 4999, 0, []))
  +o3 = he(net(o2), V.TcpConnected{1})
  +o4 = he(net(o3), V.TcpConnected{0})
  +o5 = he(net(o4), V.TcpData{1, [5]})
  +o6 = gf(net(o5), gtcp(40000, 24, 1000, 2, [6]))
  +o7 = gf(net(o6), gtcp(40001, 24, 5000, 3, [7, 7]))
  +o8 = gf(net(o7), gtcp(40000, 4, 1001, 0, []))
  +o9 = he(net(o8), V.TcpData{1, [8]})
  do IO<Unit>:
    step("two syn 0", o1, [], [V.TcpConnect{0, remote(), 80}])
    step("two syn 1", o2, [], [V.TcpConnect{1, remote(), 80}])
    step("two connected 1", o3, [htcp(40001, 18, 1, 5000, 1460, [])], [])
    step("two connected 0", o4, [htcp(40000, 18, 1, 1000, 1460, [])], [])
    step("two host data 1", o5, [htcp(40001, 24, 2, 5000, 0, [5])], [])
    step("two guest data 0", o6, [htcp(40000, 16, 2, 1001, 0, [])], [V.TcpSend{0, [6]}])
    step("two guest data 1", o7, [htcp(40001, 16, 3, 5002, 0, [])], [V.TcpSend{1, [7, 7]}])
    step("two rst 0", o8, [], [V.TcpClose{0}])
    step("two 1 still open", o9, [htcp(40001, 24, 3, 5002, 0, [8])], [])

def duplicate_syn() -> IO(Unit):
  +o1 = gf(N.Slirp.new(), gtcp(40000, 2, 999, 0, []))
  +o2 = gf(net(o1), gtcp(40000, 2, 999, 0, []))
  +o3 = gf(opened(net(o2), 40000, 0), gtcp(40000, 2, 999, 0, []))
  +o4 = gf(net(o3), gtcp(40001, 2, 0, 0, []))
  do IO<Unit>:
    step("duplicate syn", o2, [], [])
    T.eq_u32("duplicate syn one conn", conns(net(o2)), 1)
    step("duplicate syn established", o3, [], [])
    step("duplicate syn next id", o4, [], [V.TcpConnect{1, remote(), 80}])

def guest_rst() -> IO(Unit):
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcp(40000, 20, 1000, 2, []))
  +o2 = he(net(o1), V.TcpData{0, [1]})
  +o3 = gf(net(o1), gtcp(40000, 16, 1000, 2, []))
  do IO<Unit>:
    step("guest rst", o1, [], [V.TcpClose{0}])
    T.eq_u32("guest rst forgotten", conns(net(o1)), 0)
    step("guest rst then data ignored", o2, [], [])
    step("guest rst then ack gets rst", o3, [htcp(40000, 4, 2, 0, 0, [])], [])

def out_of_order() -> IO(Unit):
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcp(40000, 24, 1500, 2, [1]))
  +o2 = gf(net(o1), gtcp(40000, 24, 999, 2, [1]))
  +o3 = gf(net(o2), gtcp(40000, 24, 1000, 2, [1]))
  +o4 = gf(net(o3), gtcp(40000, 17, 1003, 2, []))
  do IO<Unit>:
    step("ooo ahead", o1, [htcp(40000, 16, 2, 1000, 0, [])], [])
    step("ooo behind", o2, [htcp(40000, 16, 2, 1000, 0, [])], [])
    step("ooo in order", o3, [htcp(40000, 16, 2, 1001, 0, [])], [V.TcpSend{0, [1]}])
    step("ooo fin ahead", o4, [htcp(40000, 16, 2, 1001, 0, [])], [])

def unknown() -> IO(Unit):
  +o1 = gf(N.Slirp.new(), gtcp(40000, 16, 5, 77, []))
  +o2 = gf(N.Slirp.new(), gtcp(40000, 18, 5, 77, []))
  +o3 = he(N.Slirp.new(), V.TcpConnected{3})
  +o4 = he(N.Slirp.new(), V.TcpEof{3})
  +o5 = gf(opened(N.Slirp.new(), 40000, 0), to_host(remote(), 6, W.Tcp.build(g(), remote(), W.Tcp{40000, 81, 1000, 2, 24, 65535, 0, [1]})))
  do IO<Unit>:
    step("unknown ack", o1, [htcp(40000, 4, 77, 0, 0, [])], [])
    step("unknown synack", o2, [htcp(40000, 4, 77, 0, 0, [])], [])
    step("unknown connected", o3, [], [])
    step("unknown eof", o4, [], [])
    step("unknown other port", o5, [to_guest(remote(), 6, W.Tcp.build(remote(), g(), W.Tcp{81, 40000, 2, 0, 4, 65535, 0, []}))], [])

# A DHCP message from the guest's MAC: op 1, xid 0x01020304, flags 0x8000.
def dhcp_msg(kind: U32) -> +List<U32>:
  +head = {[1, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0] : +List<U32>}
  +addrs = B.Bytes.zeros(16n)
  +chaddr = List.append(&2, U32, N.Slirp.guest_mac(), B.Bytes.zeros(10n))
  +fixed = List.append(&2, U32, head, List.append(&2, U32, addrs, List.append(&2, U32, chaddr, B.Bytes.zeros(192n))))
  List.append(&2, U32, fixed, [99, 130, 83, 99, 53, 1, kind, 255])

def dhcp_frame(kind: U32) -> +List<U32>:
  udp = W.Udp.build(0, 4294967295, W.Udp{68, 67, dhcp_msg(kind)})
  W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], N.Slirp.guest_mac(), 2048, W.Ipv4.build(W.Ipv4{0, 4294967295, 17, 64, 0, udp})})

def dhcp_reply(m: Maybe<&2, +List<U32>>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{r}:
      r

def bcast_reply(r: +List<U32>) -> +List<U32>:
  udp = W.Udp.build(gw(), 4294967295, W.Udp{67, 68, r})
  W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], N.Slirp.gateway_mac(), 2048, W.Ipv4.build(W.Ipv4{gw(), 4294967295, 17, 64, 0, udp})})

# The first frame's byte at off (999 when there is none).
def frame_byte(fs: +List<+List<U32>>, off: Nat) -> U32:
  match fs:
    case Nil{}:
      999
    case Con{f, t}:
      Maybe.default(&2, U32, List.get(&2, U32, f, off), 999)

def dhcp() -> IO(Unit):
  +o1 = gf(N.Slirp.new(), dhcp_frame(1))
  +o2 = gf(N.Slirp.new(), dhcp_frame(3))
  +o3 = gf(N.Slirp.new(), dhcp_frame(7))
  do IO<Unit>:
    step("dhcp discover", o1, [bcast_reply(dhcp_reply(D.Dhcp.reply(dhcp_msg(1))))], [])
    # Ethernet 14 + IPv4 20 + UDP 8: yiaddr at 16, option 53's value at 242.
    T.eq_u32("dhcp offer type", frame_byte(frames(o1), 284n), 2)
    T.eq_u32("dhcp offer yiaddr", frame_byte(frames(o1), 61n), 15)
    step("dhcp request", o2, [bcast_reply(dhcp_reply(D.Dhcp.reply(dhcp_msg(3))))], [])
    T.eq_u32("dhcp ack type", frame_byte(frames(o2), 284n), 5)
    step("dhcp release dropped", o3, [], [])

def udp() -> IO(Unit):
  +o1 = gf(N.Slirp.new(), to_host(134744072, 17, W.Udp.build(g(), 134744072, W.Udp{5000, 53, [1, 2, 3]})))
  +o2 = he(net(o1), V.UdpData{134744072, 53, 5000, [4, 5]})
  +o3 = he(N.Slirp.new(), V.UdpData{134744072, 53, 5000, noise(1400n, 3)})
  do IO<Unit>:
    step("udp out", o1, [], [V.UdpSend{5000, 134744072, 53, [1, 2, 3]}])
    step("udp in", o2, [to_guest(134744072, 17, W.Udp.build(134744072, g(), W.Udp{53, 5000, [4, 5]}))], [])
    step("udp in 1400", o3, [to_guest(134744072, 17, W.Udp.build(134744072, g(), W.Udp{53, 5000, noise(1400n, 3)}))], [])

def arp_req(tpa: U32) -> +List<U32>:
  W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], N.Slirp.guest_mac(), 2054, W.Arp.build(W.Arp{1, N.Slirp.guest_mac(), g(), [0, 0, 0, 0, 0, 0], tpa})})

def arp_rep(spa: U32) -> +List<U32>:
  W.Eth.build(W.Eth{N.Slirp.guest_mac(), N.Slirp.gateway_mac(), 2054, W.Arp.build(W.Arp{2, N.Slirp.gateway_mac(), spa, N.Slirp.guest_mac(), g()})})

def arp() -> IO(Unit):
  do IO<Unit>:
    step("arp own address", gf(N.Slirp.new(), arp_req(g())), [], [])
    step("arp gateway", gf(N.Slirp.new(), arp_req(gw())), [arp_rep(gw())], [])
    step("arp dns", gf(N.Slirp.new(), arp_req(167772675)), [arp_rep(167772675)], [])
    step("arp other", gf(N.Slirp.new(), arp_req(167772677)), [arp_rep(167772677)], [])
    step("arp reply dropped", gf(N.Slirp.new(), arp_rep(gw())), [], [])

def icmp() -> IO(Unit):
  do IO<Unit>:
    step("ping dns", gf(N.Slirp.new(), to_host(167772675, 1, W.Icmp.build(W.Icmp{8, 0, [0, 1, 0, 2, 9, 9]}))), [to_guest(167772675, 1, W.Icmp.build(W.Icmp{0, 0, [0, 1, 0, 2, 9, 9]}))], [])
    step("ping remote dropped", gf(N.Slirp.new(), to_host(remote(), 1, W.Icmp.build(W.Icmp{8, 0, [0, 1, 0, 2]}))), [], [])
    step("echo reply dropped", gf(N.Slirp.new(), to_host(gw(), 1, W.Icmp.build(W.Icmp{0, 0, [0, 1, 0, 2]}))), [], [])

def junk() -> IO(Unit):
  do IO<Unit>:
    step("empty frame", gf(N.Slirp.new(), []), [], [])
    step("short frame", gf(N.Slirp.new(), [1, 2, 3]), [], [])
    step("ipv6 dropped", gf(N.Slirp.new(), W.Eth.build(W.Eth{N.Slirp.gateway_mac(), N.Slirp.guest_mac(), 34525, [96, 0, 0, 0]})), [], [])
    step("bad ipv4 dropped", gf(N.Slirp.new(), W.Eth.build(W.Eth{N.Slirp.gateway_mac(), N.Slirp.guest_mac(), 2048, [69, 0, 0]})), [], [])
    step("other protocol dropped", gf(N.Slirp.new(), to_host(remote(), 47, [1, 2, 3, 4])), [], [])
    step("short tcp dropped", gf(N.Slirp.new(), to_host(remote(), 6, [1, 2, 3, 4])), [], [])

# A guest segment with its own window.
def gtcpw(gport: U32, flags: U32, seq: U32, ack: U32, win: U32, data: +List<U32>) -> +List<U32>:
  to_host(remote(), 6, W.Tcp.build(g(), remote(), W.Tcp{gport, 80, seq, ack, flags, win, 0, data}))

def first(fs: +List<+List<U32>>) -> +List<U32>:
  match fs:
    case Nil{}:
      []
    case f <> t:
      f

# A host frame's tag, connection, length and TCP sequence number.
def host_meta(+f: +List<U32>) -> +List<U32>:
  List.append(&2, U32, List.take(&2, U32, f, 3n), [B.Bytes.read_be32(List.drop(&2, U32, f, 41n))])

def host_metas(fs: +List<+List<U32>>) -> +List<+List<U32>>:
  match fs:
    case Nil{}:
      []
    case f <> t:
      host_meta(f) <> host_metas(t)

def show_metas(fs: +List<+List<U32>>) -> String:
  List.show(~&2, ~+List<U32>, ~show, host_metas(fs))

# The guest's window bounds what the NAT sends: 3000 bytes from the host
# against a window of 1000 go out 1000 at a time, as the guest ACKs.
def flow_window() -> IO(Unit):
  +big = noise(3000n, 11)
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcpw(40000, 16, 1000, 2, 1000, []))
  +o2 = he(net(o1), V.TcpData{0, big})
  +o3 = gf(net(o2), gtcpw(40000, 16, 1000, 1002, 1000, []))
  +o4 = gf(net(o3), gtcpw(40000, 16, 1000, 2002, 65535, []))
  +o5 = he(net(o4), V.TcpEof{0})
  do IO<Unit>:
    step("flow bare ack", o1, [], [])
    step("flow first 1000", o2, [htcp(40000, 24, 2, 1000, 0, List.take(&2, U32, big, 1000n))], [])
    T.eq_u32("flow queued", N.Slirp.queued(net(o2)), 2000)
    step("flow next 1000 on ack", o3, [htcp(40000, 24, 1002, 1000, 0, B.Bytes.slice(big, 1000n, 1000n))], [])
    step("flow rest on a wide window", o4, [htcp(40000, 24, 2002, 1000, 0, List.drop(&2, U32, big, 2000n))], [])
    step("flow fin after the data", o5, [htcp(40000, 17, 3002, 1000, 0, [])], [])

# A FIN waits for the queued data; a zero window holds everything back.
def flow_eof_waits() -> IO(Unit):
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcpw(40000, 16, 1000, 2, 0, []))
  +o2 = he(net(o1), V.TcpData{0, [1, 2, 3]})
  +o3 = he(net(o2), V.TcpEof{0})
  +o4 = gf(net(o3), gtcpw(40000, 16, 1000, 2, 100, []))
  do IO<Unit>:
    step("zero window holds data", o2, [], [])
    step("eof waits for data", o3, [], [])
    step("window update sends data then fin", o4, [htcp(40000, 24, 2, 1000, 0, [1, 2, 3]), htcp(40000, 17, 5, 1000, 0, [])], [])

# Bytes held on the host (TcpReady) go out as host frames within the window.
def flow_held() -> IO(Unit):
  +o1 = gf(opened(N.Slirp.new(), 40000, 0), gtcpw(40000, 16, 1000, 2, 3000, []))
  +o2 = he(net(o1), V.TcpReady{0, 5000})
  +o3 = gf(net(o2), gtcpw(40000, 16, 1000, 3002, 65535, []))
  do IO<Unit>:
    T.eq_str("held first 3000", show_metas(frames(o2)), "[[256, 0, 3000, 2]]")
    T.eq_str("held rest on ack", show_metas(frames(o3)), "[[256, 0, 2000, 3002]]")
    T.eq_str("held frame headers", show(List.take(&2, U32, List.drop(&2, U32, first(frames(o2)), 3n), 14n)), show(List.append(&2, U32, N.Slirp.guest_mac(), List.append(&2, U32, N.Slirp.gateway_mac(), [8, 0]))))

def main() -> IO(Unit):
  do IO<Unit>:
    lifetime()
    lifetime_reverse()
    data_fin()
    host_sizes()
    refused()
    two()
    duplicate_syn()
    guest_rst()
    out_of_order()
    unknown()
    dhcp()
    udp()
    arp()
    icmp()
    junk()
    flow_window()
    flow_eof_waits()
    flow_held()
