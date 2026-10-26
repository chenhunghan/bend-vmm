import Base
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./wire.bend as W
import ./dhcp.bend as D

# A user-mode NAT ("slirp") between the guest's virtio-net and the host's
# sockets. The guest sees a /24 with:
#   guest   10.0.2.15 (167772687), MAC 52:54:00:12:34:56
#   gateway 10.0.2.2  (167772674), MAC 52:55:0a:00:02:02 (the host)
#   DNS     10.0.2.3  (167772675)
# The link to the guest never loses or reorders frames, so TCP needs no
# retransmission or reassembly: an out-of-order guest segment is answered
# with a duplicate ACK and dropped.
#
# Every frame to the guest is Ethernet (dst guest MAC, src gateway MAC) over
# IPv4 (src = the remote address, dst = guest, TTL 64, id 0), except the DHCP
# reply (IPv4 dst 255.255.255.255, Ethernet dst ff:ff:ff:ff:ff:ff, src
# 10.0.2.2). TCP segments to the guest have window 65535.
#
# From the guest (Slirp.guest_frame):
#   ARP request for any address but 10.0.2.15: ARP reply from the gateway MAC.
#   ICMP echo request to 10.0.2.2 or 10.0.2.3: echo reply. Other ICMP: dropped.
#   UDP to port 67: the D.Dhcp.reply, from 10.0.2.2:67 to port 68.
#   Other UDP: V.UdpSend{sport, dst, dport, payload}.
#   TCP, by connection (guest port, remote address, remote port):
#     SYN without ACK, unknown connection: a new connection numbered next_id
#       (then next_id + 1), state SynSent, gseq = seq + 1, hseq = 1;
#       V.TcpConnect{id, dst, dport}. A SYN for a known connection: dropped.
#     RST, known: V.TcpClose{id}; the connection is forgotten.
#     known, seq != gseq: an ACK (seq hseq, ack gseq); nothing else.
#     known, seq == gseq: data (if any) goes to V.TcpSend{id, data} and gseq
#       advances by its length; then a FIN advances gseq by 1 and sends
#       V.TcpShutdown{id} (state GuestFin, or, after HostFin, V.TcpClose and
#       the connection is forgotten). An ACK (seq hseq, ack gseq) answers any
#       data or FIN; a bare ACK gets no answer.
#     not SYN, unknown connection: RST (seq = the segment's ack, ack 0).
#   Anything else: dropped.
# From the host (Slirp.host_event):
#   TcpConnected{id}: SYN|ACK (seq hseq, ack gseq, MSS 1460); hseq + 1;
#     state Established.
#   TcpRefused{id}: RST|ACK (seq 0, ack gseq); the connection is forgotten.
#   TcpData{id, bytes}: PSH|ACK segments of at most 1460 bytes, in order,
#     each with seq hseq (advancing) and ack gseq.
#   TcpEof{id}: FIN|ACK (seq hseq, ack gseq); hseq + 1; state HostFin, or,
#     after GuestFin, V.TcpClose{id} and the connection is forgotten.
#   UdpData{ip, port, dport, bytes}: a UDP datagram from ip:port to the
#     guest's dport.
#   Events for unknown connections: ignored.

def Slirp.guest_ip() -> U32:
  167772687

def Slirp.gateway_ip() -> U32:
  167772674

def Slirp.dns_ip() -> U32:
  167772675

def Slirp.guest_mac() -> +List<U32>:
  [82, 84, 0, 18, 52, 86]

def Slirp.gateway_mac() -> +List<U32>:
  [82, 85, 10, 0, 2, 2]

# Connection states.
def Conn.syn_sent() -> U32:
  0
def Conn.established() -> U32:
  1
def Conn.guest_fin() -> U32:
  2
def Conn.host_fin() -> U32:
  3

type Conn is Data:
  Conn{id: U32, gport: U32, rip: U32, rport: U32, state: U32, gseq: U32, hseq: U32}

type Slirp is Data:
  Slirp{conns: +List<Conn>, next_id: U32}

# A step's result: the new state, frames for the guest in order, and host
# commands in order.
type SlirpOut is Data:
  SlirpOut{net: Slirp, frames: +List<+List<U32>>, cmds: +List<V.NetCmd>}

def Slirp.new() -> Slirp:
  Slirp{[], 0}

# Frames to the guest.

# An IPv4 packet from src to the guest, in an Ethernet frame.
def Slirp.ip_frame(src: U32, proto: U32, payload: +List<U32>) -> +List<U32>:
  W.Eth.build(W.Eth{Slirp.guest_mac(), Slirp.gateway_mac(), 2048, W.Ipv4.build(W.Ipv4{src, Slirp.guest_ip(), proto, 64, 0, payload})})

# A TCP segment from rip:rport to the guest's gport.
def Slirp.tcp_frame(+rip: U32, rport: U32, gport: U32, seq: U32, ack: U32, flags: U32, mss: U32, data: +List<U32>) -> +List<U32>:
  Slirp.ip_frame(rip, 6, W.Tcp.build(rip, Slirp.guest_ip(), W.Tcp{rport, gport, seq, ack, flags, 65535, mss, data}))

# A TCP segment on connection c.
def Conn.frame(+c: Conn, flags: U32, seq: U32, ack: U32, mss: U32, data: +List<U32>) -> +List<U32>:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      Slirp.tcp_frame(rip, rport, gport, seq, ack, flags, mss, data)

# The ACK of everything the guest sent (seq hseq, ack gseq).
def Conn.ack(+c: Conn) -> +List<U32>:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      Slirp.tcp_frame(rip, rport, gport, hseq, gseq, 16, 0, [])

def Conn.id(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      id

def Conn.state(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      state

# The connection table.

# A connection is found by its id (host events) or its addresses (guest
# segments: guest port, remote address, remote port).
type Key is Data:
  ById{id: U32}
  ByAddr{gport: U32, rip: U32, rport: U32}

def Conn.hit(+c: Conn, +k: Key) -> Bool:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      match k:
        case ById{i}:
          U32.is_eq(id, i)
        case ByAddr{gp, ip, rp}:
          U32.is_eq(gport, gp) && U32.is_eq(rip, ip) && U32.is_eq(rport, rp)

# The connection for a key (if any), and the table without it.
type Found is Data:
  Found{conn: Maybe<&2, Conn>, rest: +List<Conn>}

def Found.cons(hit: Bool, c: Conn, f: Found) -> Found:
  match hit:
    case True{}:
      match f:
        case Found{m, rest}:
          Found{Some{c}, rest}
    case False{}:
      match f:
        case Found{m, rest}:
          Found{m, c <> rest}

def Conns.take(cs: +List<Conn>, +k: Key) -> Found:
  match cs:
    case Nil{}:
      Found{None{}, []}
    case Con{+c, t}:
      Found.cons(Conn.hit(c, k), c, Conns.take(t, k))

def Slirp.none(n: Slirp) -> SlirpOut:
  SlirpOut{n, [], []}

# TCP flags.
def Tcp.flag(+flags: U32, f: U32) -> Bool:
  Bool.not(U32.is_zero((flags .&. f : U32)))

# A SYN without ACK opens a connection.
def Tcp.is_open(+flags: U32) -> Bool:
  Tcp.flag(flags, 2) && Bool.not(Tcp.flag(flags, 16))

# Guest segments for an unknown connection: a SYN opens it, anything else
# gets a RST.
def Tcp.unknown(syn: Bool, rest: +List<Conn>, +next_id: U32, +rip: U32, +gport: U32, +rport: U32, +seq: U32, ack: U32) -> SlirpOut:
  match syn:
    case True{}:
      c = {Conn{next_id, gport, rip, rport, Conn.syn_sent(), (seq + 1 : U32), 1} : Conn}
      SlirpOut{Slirp{c <> rest, (next_id + 1 : U32)}, [], [V.TcpConnect{next_id, rip, rport}]}
    case False{}:
      SlirpOut{Slirp{rest, next_id}, [Slirp.tcp_frame(rip, rport, gport, ack, 0, 4, 0, [])], []}

# The guest's FIN on c (gseq already past its data): c's new table and the
# commands it adds.
def Tcp.guest_fin(closing: Bool, c: Conn, rest: +List<Conn>, cmds: +List<V.NetCmd>) -> +List<Conn> & +List<V.NetCmd>:
  match closing:
    case True{}:
      +id = Conn.id(c)
      (rest, List.append(&2, V.NetCmd, cmds, [V.TcpShutdown{id}, V.TcpClose{id}]))
    case False{}:
      match c:
        case Conn{+id, gport, rip, rport, state, gseq, hseq}:
          (Conn{id, gport, rip, rport, Conn.guest_fin(), (gseq + 1 : U32), hseq} <> rest, List.append(&2, V.NetCmd, cmds, [V.TcpShutdown{id}]))

# c with gseq advanced by one.
def Conn.fin_seq(c: Conn) -> Conn:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      Conn{id, gport, rip, rport, state, (gseq + 1 : U32), hseq}

def Tcp.result(answer: Bool, +c: Conn, next_id: U32, t: +List<Conn> & +List<V.NetCmd>) -> SlirpOut:
  match answer:
    case True{}:
      match t:
        case (conns, cmds):
          SlirpOut{Slirp{conns, next_id}, [Conn.ack(c)], cmds}
    case False{}:
      match t:
        case (conns, cmds):
          SlirpOut{Slirp{conns, next_id}, [], cmds}

# After in-order data (already in c's gseq), a FIN or not.
def Tcp.after_data(fin: Bool, sent: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, cmds: +List<V.NetCmd>) -> SlirpOut:
  match fin:
    case True{}:
      +c2 = Conn.fin_seq(c)
      Tcp.result(True{}, c2, next_id, Tcp.guest_fin(U32.is_eq(Conn.state(c), Conn.host_fin()), c, rest, cmds))
    case False{}:
      Tcp.result(sent, c, next_id, (c <> rest, cmds))

def Tcp.send_cmd(empty: Bool, id: U32, data: +List<U32>) -> +List<V.NetCmd>:
  match empty:
    case True{}:
      []
    case False{}:
      [V.TcpSend{id, data}]

# An in-order segment on a known connection.
def Tcp.in_order(c: Conn, rest: +List<Conn>, next_id: U32, +data: +List<U32>, fin: Bool) -> SlirpOut:
  match c:
    case Conn{+id, gport, rip, rport, state, gseq, hseq}:
      +len = U32.from_nat(List.length(&2, U32, data))
      +empty = U32.is_zero(len)
      c2 = {Conn{id, gport, rip, rport, state, (gseq + len : U32), hseq} : Conn}
      Tcp.after_data(fin, Bool.not(empty), c2, rest, next_id, Tcp.send_cmd(empty, id, data))

# A segment on a known connection that is neither a SYN nor a RST.
def Tcp.in_seq(ok: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, data: +List<U32>, fin: Bool) -> SlirpOut:
  match ok:
    case True{}:
      Tcp.in_order(c, rest, next_id, data, fin)
    case False{}:
      SlirpOut{Slirp{c <> rest, next_id}, [Conn.ack(c)], []}

def Conn.gseq(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq}:
      gseq

# Guest segments for a known connection: a SYN is dropped, a RST closes it.
def Tcp.known(syn: Bool, rst: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, +seq: U32, data: +List<U32>, fin: Bool) -> SlirpOut:
  match syn rst:
    case True{} _:
      SlirpOut{Slirp{c <> rest, next_id}, [], []}
    case False{} True{}:
      SlirpOut{Slirp{rest, next_id}, [], [V.TcpClose{Conn.id(c)}]}
    case False{} False{}:
      Tcp.in_seq(U32.is_eq(seq, Conn.gseq(c)), c, rest, next_id, data, fin)

def Tcp.segment(f: Found, next_id: U32, rip: U32, t: W.Tcp) -> SlirpOut:
  match f:
    case Found{m, rest}:
      match m:
        case None{}:
          match t:
            case W.Tcp{sport, dport, seq, ack, +flags, window, mss, data}:
              Tcp.unknown(Tcp.is_open(flags), rest, next_id, rip, sport, dport, seq, ack)
        case Some{c}:
          match t:
            case W.Tcp{sport, dport, seq, ack, +flags, window, mss, data}:
              Tcp.known(Tcp.is_open(flags), Tcp.flag(flags, 4), c, rest, next_id, seq, data, Tcp.flag(flags, 1))

def Slirp.tcp(n: Slirp, +rip: U32, m: Maybe<&2, W.Tcp>) -> SlirpOut:
  match n:
    case Slirp{conns, next_id}:
      match m:
        case None{}:
          SlirpOut{Slirp{conns, next_id}, [], []}
        case Some{+t}:
          match t:
            case W.Tcp{+sport, +dport, seq, ack, flags, window, mss, data}:
              Tcp.segment(Conns.take(conns, ByAddr{sport, rip, dport}), next_id, rip, t)

# The DHCP reply, broadcast from 10.0.2.2:67 to port 68.
def Slirp.dhcp(n: Slirp, m: Maybe<&2, +List<U32>>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{r}:
      +gw = Slirp.gateway_ip()
      +bcast = {4294967295 : U32} # 255.255.255.255
      udp = W.Udp.build(gw, bcast, W.Udp{67, 68, r})
      SlirpOut{n, [W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], Slirp.gateway_mac(), 2048, W.Ipv4.build(W.Ipv4{gw, bcast, 17, 64, 0, udp})})], []}

def Slirp.udp_to(dhcp: Bool, n: Slirp, sport: U32, dst: U32, dport: U32, data: +List<U32>) -> SlirpOut:
  match dhcp:
    case True{}:
      Slirp.dhcp(n, D.Dhcp.reply(data))
    case False{}:
      SlirpOut{n, [], [V.UdpSend{sport, dst, dport, data}]}

def Slirp.udp(n: Slirp, dst: U32, m: Maybe<&2, W.Udp>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{W.Udp{sport, +dport, data}}:
      Slirp.udp_to(U32.is_eq(dport, 67), n, sport, dst, dport, data)

# An echo request to the gateway or the DNS address gets an echo reply.
def Slirp.echo(ok: Bool, n: Slirp, dst: U32, rest: +List<U32>) -> SlirpOut:
  match ok:
    case True{}:
      SlirpOut{n, [Slirp.ip_frame(dst, 1, W.Icmp.build(W.Icmp{0, 0, rest}))], []}
    case False{}:
      Slirp.none(n)

def Slirp.icmp(n: Slirp, +dst: U32, m: Maybe<&2, W.Icmp>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{W.Icmp{kind, code, rest}}:
      ok = U32.is_eq(kind, 8) && (U32.is_eq(dst, Slirp.gateway_ip()) || U32.is_eq(dst, Slirp.dns_ip()))
      Slirp.echo(ok, n, dst, rest)

def Slirp.proto(icmp: Bool, tcp: Bool, udp: Bool, n: Slirp, +dst: U32, +payload: +List<U32>) -> SlirpOut:
  match icmp tcp udp:
    case True{} _ _:
      Slirp.icmp(n, dst, W.Icmp.parse(payload))
    case False{} True{} _:
      Slirp.tcp(n, dst, W.Tcp.parse(payload))
    case False{} False{} True{}:
      Slirp.udp(n, dst, W.Udp.parse(payload))
    case False{} False{} False{}:
      Slirp.none(n)

def Slirp.ip(n: Slirp, m: Maybe<&2, W.Ipv4>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{W.Ipv4{src, dst, +proto, ttl, id, payload}}:
      Slirp.proto(U32.is_eq(proto, 1), U32.is_eq(proto, 6), U32.is_eq(proto, 17), n, dst, payload)

# An ARP request for any address but the guest's gets the gateway MAC.
def Slirp.arp_reply(ok: Bool, n: Slirp, sha: +List<U32>, spa: U32, tpa: U32) -> SlirpOut:
  match ok:
    case True{}:
      arp = {W.Arp.build(W.Arp{2, Slirp.gateway_mac(), tpa, sha, spa}) : +List<U32>}
      SlirpOut{n, [W.Eth.build(W.Eth{Slirp.guest_mac(), Slirp.gateway_mac(), 2054, arp})], []}
    case False{}:
      Slirp.none(n)

def Slirp.arp(n: Slirp, m: Maybe<&2, W.Arp>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{W.Arp{op, sha, spa, tha, +tpa}}:
      ok = U32.is_eq(op, 1) && Bool.not(U32.is_eq(tpa, Slirp.guest_ip()))
      Slirp.arp_reply(ok, n, sha, spa, tpa)

def Slirp.ethertype(arp: Bool, ip: Bool, n: Slirp, +payload: +List<U32>) -> SlirpOut:
  match arp ip:
    case True{} _:
      Slirp.arp(n, W.Arp.parse(payload))
    case False{} True{}:
      Slirp.ip(n, W.Ipv4.parse(payload))
    case False{} False{}:
      Slirp.none(n)

def Slirp.eth(n: Slirp, m: Maybe<&2, W.Eth>) -> SlirpOut:
  match m:
    case None{}:
      Slirp.none(n)
    case Some{W.Eth{dst, src, +ty, payload}}:
      Slirp.ethertype(U32.is_eq(ty, 2054), U32.is_eq(ty, 2048), n, payload)

def Slirp.guest_frame(n: Slirp, frame: +List<U32>) -> SlirpOut:
  Slirp.eth(n, W.Eth.parse(frame))

# Host data, cut into segments of at most 1460 bytes (fuel: the byte count).
def Tcp.mss() -> Nat:
  1460n

def Tcp.chunks(fuel: Nat, bs: +List<U32>) -> +List<+List<U32>>:
  match fuel bs:
    case 0n _:
      []
    case 1n+p Nil{}:
      []
    case 1n+p h <> t:
      +bs = {h <> t : +List<U32>}
      List.take(&2, U32, bs, Tcp.mss()) <> Tcp.chunks(p, List.drop(&2, U32, bs, Tcp.mss()))

# The PSH|ACK segments of chunks on c, the first with sequence seq.
def Tcp.segs(chunks: +List<+List<U32>>, +c: Conn, +seq: U32, +ack: U32) -> +List<+List<U32>>:
  match chunks:
    case Nil{}:
      []
    case Con{+d, t}:
      Conn.frame(c, 24, seq, ack, 0, d) <> Tcp.segs(t, c, (seq + U32.from_nat(List.length(&2, U32, d)) : U32), ack)

# At most two chunks are built sequentially.
def Tcp.small(+n: Nat) -> Bool:
  Nat.is_le(n, 2n)

# The segments of n chunks as a balanced parallel build: every chunk but the
# last is full, so the right half starts 1460 bytes per left chunk later.
# d bounds the depth.
def Tcp.par(d: Nat, small: Bool, +c: Conn, +seq: U32, +ack: U32, +n: Nat, +chunks: +List<+List<U32>>) -> +List<+List<U32>>:
  match d small:
    case 0n _:
      Tcp.segs(chunks, c, seq, ack)
    case 1n+p True{}:
      Tcp.segs(chunks, c, seq, ack)
    case 1n+(+p) False{}:
      +h = Nat.div(n, 2n)
      +m = Nat.sub(n, h)
      +l = List.take(&2, +List<U32>, chunks, h)
      +r = List.drop(&2, +List<U32>, chunks, h)
      +sl = Tcp.small(h)
      +sr = Tcp.small(m)
      +sq = (seq + (1460 * U32.from_nat(h) : U32) : U32)
      a b = Tcp.par(p, sl, c, seq, ack, h, l) Tcp.par(p, sr, c, sq, ack, m, r)
      List.append(&2, +List<U32>, a, b)

def Tcp.data_frames(+c: Conn, +seq: U32, +ack: U32, +bytes: +List<U32>) -> +List<+List<U32>>:
  +chunks = Tcp.chunks(List.length(&2, U32, bytes), bytes)
  +n = List.length(&2, +List<U32>, chunks)
  Tcp.par(24n, Tcp.small(n), c, seq, ack, n, chunks)

# What the host reported on a TCP connection.
type HostTcp is Data:
  HConnected{}
  HRefused{}
  HData{bytes: +List<U32>}
  HEof{}

# The host's EOF: state HostFin, or, after GuestFin, the connection closes.
def Tcp.host_eof(closing: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, frame: +List<U32>) -> SlirpOut:
  match closing:
    case True{}:
      SlirpOut{Slirp{rest, next_id}, [frame], [V.TcpClose{Conn.id(c)}]}
    case False{}:
      match c:
        case Conn{id, gport, rip, rport, state, gseq, hseq}:
          c2 = {Conn{id, gport, rip, rport, Conn.host_fin(), gseq, (hseq + 1 : U32)} : Conn}
          SlirpOut{Slirp{c2 <> rest, next_id}, [frame], []}

def Tcp.host(+c: Conn, rest: +List<Conn>, next_id: U32, h: HostTcp) -> SlirpOut:
  match c:
    case Conn{id, gport, rip, rport, +state, +gseq, +hseq}:
      match h:
        case HConnected{}:
          c2 = {Conn{id, gport, rip, rport, Conn.established(), gseq, (hseq + 1 : U32)} : Conn}
          SlirpOut{Slirp{c2 <> rest, next_id}, [Conn.frame(c, 18, hseq, gseq, 1460, [])], []}
        case HRefused{}:
          SlirpOut{Slirp{rest, next_id}, [Conn.frame(c, 20, 0, gseq, 0, [])], []}
        case HData{+bytes}:
          c2 = {Conn{id, gport, rip, rport, state, gseq, (hseq + U32.from_nat(List.length(&2, U32, bytes)) : U32)} : Conn}
          SlirpOut{Slirp{c2 <> rest, next_id}, Tcp.data_frames(c, hseq, gseq, bytes), []}
        case HEof{}:
          Tcp.host_eof(U32.is_eq(state, Conn.guest_fin()), c, rest, next_id, Conn.frame(c, 17, hseq, gseq, 0, []))

def Tcp.host_event(f: Found, next_id: U32, h: HostTcp) -> SlirpOut:
  match f:
    case Found{m, rest}:
      match m:
        case None{}:
          SlirpOut{Slirp{rest, next_id}, [], []}
        case Some{c}:
          Tcp.host(c, rest, next_id, h)

def Slirp.host_event(n: Slirp, ev: V.NetEvent) -> SlirpOut:
  match n:
    case Slirp{conns, next_id}:
      match ev:
        case V.TcpConnected{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HConnected{})
        case V.TcpRefused{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HRefused{})
        case V.TcpData{id, bytes}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HData{bytes})
        case V.TcpEof{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HEof{})
        case V.UdpData{+ip, port, dport, bytes}:
          frame = Slirp.ip_frame(ip, 17, W.Udp.build(ip, Slirp.guest_ip(), W.Udp{port, dport, bytes}))
          SlirpOut{Slirp{conns, next_id}, [frame], []}
