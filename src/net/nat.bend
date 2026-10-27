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
#   Other UDP: V.UdpSend{sport, dst, dport, payload} when Slirp.dst_ok, else
#     dropped.
#   TCP, by connection (guest port, remote address, remote port):
#     SYN without ACK, unknown connection: a new connection numbered next_id
#       (then next_id + 1), state SynSent, gseq = seq + 1, hseq = 1;
#       V.TcpConnect{id, dst, dport}. A SYN for a known connection: dropped.
#       With Slirp.max_conns connections open, or to an address that is not
#       Slirp.dst_ok: RST|ACK (seq 0, ack seq + 1) and no connection.
#     SynSent (the host is still connecting): everything but a RST is
#       dropped, unanswered.
#     RST, known: V.TcpClose{id}; the connection is forgotten.
#     Blocked (the host's socket holds too much unsent, V.TcpBlocked):
#       in-order data is dropped (seq hseq, ack gseq, window 0 answers it)
#       until V.TcpUnblocked.
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
#   TcpReady{id, len}: one PSH|ACK segment of len bytes as a host frame
#     (W.Wire.host_frame: the headers, the payload left on the host), seq
#     hseq (advancing by len) and ack gseq, TCP checksum 0 (the device tells
#     the guest the data is valid). Only for a guest that takes segments up
#     to 64 KiB (virtio-net GUEST_TSO4 and GUEST_CSUM).
#   TcpEof{id}: FIN|ACK (seq hseq, ack gseq); hseq + 1; state HostFin, or,
#     after GuestFin, V.TcpClose{id} and the connection is forgotten.
#   UdpData{ip, port, dport, bytes}: a UDP datagram from ip:port to the
#     guest's dport.
#   TcpBlocked{id}: the connection is blocked (no frame).
#   TcpUnblocked{id}: no longer blocked; an ACK (seq hseq, ack gseq) opens
#     the guest's window again.
#   TcpReset{id}: RST|ACK (seq hseq, ack gseq), V.TcpClose{id}; the
#     connection is forgotten.
#   Events for unknown connections: ignored.
#
# The host reads a connection on only while Slirp.may_read (its queue for
# the guest holds less than Slirp.queue_cap bytes).

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

# The blocked mark (V.TcpBlocked), a bit above the state's own values: Conn
# and Flow are pinned by the snapshot format, so it shares the state word.
def Conn.blocked() -> U32:
  256

# A state word's state, its blocked mark dropped.
def Conn.phase(+state: U32) -> U32:
  (state .&. 255 : U32)

# The state word with phase p, its blocked mark kept.
def Conn.with_phase(+state: U32, p: U32) -> U32:
  ((state .&. Conn.blocked() : U32) .|. p : U32)

# The most connections the NAT keeps open: a SYN past them gets a RST.
def Slirp.max_conns() -> Nat:
  256n

# The most bytes a connection queues for the guest (TcpData waiting for the
# guest's ACK): past them the host reads no more of its socket.
def Slirp.queue_cap() -> U32:
  262144

# The flow toward the guest, in sequence numbers: the guest acknowledged
# everything before una and takes what lies before wnd (its last ACK plus
# its window); the host's data so far ends at dend. Data stays until the
# guest acknowledges it, so it can be sent again: on the byte path (TcpData)
# as queue, the bytes from una on; on the held path (TcpReady) as the host's
# hold of hlen bytes from sequence number hbase, released (TcpRelease) once
# acknowledged. eof: the host finished, so a FIN follows its data. scale:
# the guest's window shift when its SYN offered window scaling (the NAT then
# answers with its own, Tcp.our_scale), else 4294967295 (no scaling either
# way). dack, dwin: the guest's last ACK and window field, to tell a
# duplicate ACK. back: una when data was last sent again (one go-back per
# acknowledged point, so the guest's ACKs of duplicates do not set off more).
type Flow is Data:
  Flow{wnd: U32, una: U32, dend: U32, hbase: U32, hlen: U32, queue: +List<U32>, eof: Bool, scale: U32, dack: U32, dwin: U32, back: U32}

# The NAT's window shift when the guest scales: its window field (always
# 65535) then offers 8 MiB. Guest data goes straight to the host's socket,
# so the NAT holds none of it.
def Tcp.our_scale() -> U32:
  7

def Tcp.no_scale() -> U32:
  4294967295

type Conn is Data:
  Conn{id: U32, gport: U32, rip: U32, rport: U32, state: U32, gseq: U32, hseq: U32, flow: Flow}

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
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      Slirp.tcp_frame(rip, rport, gport, seq, ack, flags, mss, data)

# The ACK of everything the guest sent (seq hseq, ack gseq).
def Conn.ack(+c: Conn) -> +List<U32>:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      Slirp.tcp_frame(rip, rport, gport, hseq, gseq, 16, 0, [])

def Conn.id(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      id

def Conn.state(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      Conn.phase(state)

def Conn.is_blocked(+c: Conn) -> Bool:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      Bool.not(U32.is_zero((state .&. Conn.blocked() : U32)))

# The ACK of everything the guest sent, with a zero window (blocked).
def Conn.ack_zero(+c: Conn) -> +List<U32>:
  match c:
    case Conn{id, gport, +rip, rport, state, gseq, hseq, fl}:
      Slirp.ip_frame(rip, 6, W.Tcp.build(rip, Slirp.guest_ip(), W.Tcp{rport, gport, hseq, gseq, 16, 0, 0, []}))

# The connection table.

# A connection is found by its id (host events) or its addresses (guest
# segments: guest port, remote address, remote port).
type Key is Data:
  ById{id: U32}
  ByAddr{gport: U32, rip: U32, rport: U32}

def Conn.hit(+c: Conn, +k: Key) -> Bool:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
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

# A guest segment's data: its bytes, or len bytes staged on the host (a
# staged frame, W.Wire.staged_frame).
type Payload is Data:
  Bytes{bs: +List<U32>}
  Staged{slot: U32, len: U32}

def Payload.len(+p: Payload) -> U32:
  match p:
    case Bytes{bs}:
      U32.from_nat(List.length(&2, U32, bs))
    case Staged{slot, len}:
      len

# The command that sends the data on connection id (none for no bytes).
def Payload.send(id: U32, p: Payload) -> +List<V.NetCmd>:
  match p:
    case Bytes{+bs}:
      Bool.pick(+List<V.NetCmd>, List.is_empty(&2, U32, bs), [], [V.TcpSend{id, bs}])
    case Staged{slot, len}:
      [V.TcpSendStaged{id, slot}]

# The command that frees data the NAT does not send (none for bytes).
def Payload.drop(p: Payload) -> +List<V.NetCmd>:
  match p:
    case Bytes{bs}:
      []
    case Staged{slot, len}:
      [V.StageDrop{slot}]

# TCP flags.
def Tcp.flag(+flags: U32, f: U32) -> Bool:
  Bool.not(U32.is_zero((flags .&. f : U32)))

# A SYN without ACK opens a connection.
def Tcp.is_open(+flags: U32) -> Bool:
  Tcp.flag(flags, 2) && Bool.not(Tcp.flag(flags, 16))

# Where the guest may go (TCP and UDP): not 0.0.0.0/8, 127.0.0.0/8 (the
# host's loopback is 10.0.2.2), 169.254.0.0/16 (link-local: cloud metadata),
# 224.0.0.0/4 (multicast) or 255.255.255.255, and 10.0.2.3 (the host's
# resolver) on port 53 only.
def Slirp.dst_ok(+dst: U32, +port: U32) -> Bool:
  +a = (dst >> 24n : U32)
  +bad = U32.is_eq(a, 0) || U32.is_eq(a, 127) || U32.is_eq((dst >> 16n : U32), 43518) || U32.is_eq((dst >> 28n : U32), 14) || U32.is_eq(dst, 4294967295)
  Bool.not(bad || (U32.is_eq(dst, Slirp.dns_ip()) && U32.is_ne(port, 53)))

# A SYN opens a connection (the guest's window counts from 2, the first
# sequence number after the SYN|ACK) when ok: below Slirp.max_conns and to
# an address Slirp.dst_ok; else a RST|ACK refuses it.
def Tcp.open(ok: Bool, rest: +List<Conn>, +next_id: U32, +rip: U32, +gport: U32, +rport: U32, +seq: U32, win: U32, ws: U32, pl: Payload) -> SlirpOut:
  match ok:
    case True{}:
      c = {Conn{next_id, gport, rip, rport, Conn.syn_sent(), (seq + 1 : U32), 1, Flow{(2 + win : U32), 2, 2, 2, 0, [], False{}, ws, 0, 0, 1}} : Conn}
      SlirpOut{Slirp{c <> rest, (next_id + 1 : U32)}, [], V.TcpConnect{next_id, rip, rport} <> Payload.drop(pl)}
    case False{}:
      SlirpOut{Slirp{rest, next_id}, [Slirp.tcp_frame(rip, rport, gport, 0, (seq + 1 : U32), 20, 0, [])], Payload.drop(pl)}

# Guest segments for an unknown connection: a SYN may open it (Tcp.open),
# anything else gets a RST.
def Tcp.unknown(syn: Bool, +rest: +List<Conn>, +next_id: U32, +rip: U32, +gport: U32, +rport: U32, +seq: U32, ack: U32, win: U32, ws: U32, pl: Payload) -> SlirpOut:
  match syn:
    case True{}:
      +ok = Nat.is_lt(List.length(&2, Conn, rest), Slirp.max_conns()) && Slirp.dst_ok(rip, rport)
      Tcp.open(ok, rest, next_id, rip, gport, rport, seq, win, ws, pl)
    case False{}:
      SlirpOut{Slirp{rest, next_id}, [Slirp.tcp_frame(rip, rport, gport, ack, 0, 4, 0, [])], Payload.drop(pl)}

# The guest's FIN on c (gseq already past its data): c's new table and the
# commands it adds.
def Tcp.guest_fin(closing: Bool, c: Conn, rest: +List<Conn>, cmds: +List<V.NetCmd>) -> +List<Conn> & +List<V.NetCmd>:
  match closing:
    case True{}:
      +id = Conn.id(c)
      (rest, List.append(&2, V.NetCmd, cmds, [V.TcpShutdown{id}, V.TcpClose{id}]))
    case False{}:
      match c:
        case Conn{+id, gport, rip, rport, state, gseq, hseq, fl}:
          (Conn{id, gport, rip, rport, Conn.with_phase(state, Conn.guest_fin()), (gseq + 1 : U32), hseq, fl} <> rest, List.append(&2, V.NetCmd, cmds, [V.TcpShutdown{id}]))

# c with gseq advanced by one.
def Conn.fin_seq(c: Conn) -> Conn:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      Conn{id, gport, rip, rport, state, (gseq + 1 : U32), hseq, fl}

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

# An in-order segment on a known connection.
def Tcp.in_order(c: Conn, rest: +List<Conn>, next_id: U32, +pl: Payload, fin: Bool) -> SlirpOut:
  match c:
    case Conn{+id, gport, rip, rport, state, gseq, hseq, fl}:
      +len = Payload.len(pl)
      c2 = {Conn{id, gport, rip, rport, state, (gseq + len : U32), hseq, fl} : Conn}
      Tcp.after_data(fin, Bool.not(U32.is_zero(len)), c2, rest, next_id, Payload.send(id, pl))

# An in-order segment; held (data while blocked): dropped, answered with a
# zero window.
def Tcp.in_take(held: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, pl: Payload, fin: Bool) -> SlirpOut:
  match held:
    case True{}:
      SlirpOut{Slirp{c <> rest, next_id}, [Conn.ack_zero(c)], Payload.drop(pl)}
    case False{}:
      Tcp.in_order(c, rest, next_id, pl, fin)

# A segment on a known connection that is neither a SYN nor a RST.
def Tcp.in_seq(ok: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, +pl: Payload, fin: Bool) -> SlirpOut:
  match ok:
    case True{}:
      Tcp.in_take(Conn.is_blocked(c) && U32.is_ne(Payload.len(pl), 0), c, rest, next_id, pl, fin)
    case False{}:
      SlirpOut{Slirp{c <> rest, next_id}, [Conn.ack(c)], Payload.drop(pl)}

def Conn.gseq(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      gseq

# Flow toward the guest
# =====================

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

# The host frame of a PSH|ACK segment of len bytes at offset off of the hold
# for connection id: Ethernet, IPv4 and TCP headers (TCP checksum 0).
def Tcp.host_frame(+id: U32, +rip: U32, rport: U32, gport: U32, seq: U32, ack: U32, +off: U32, +len: U32) -> +List<U32>:
  +tcp = W.Tcp.header(W.Tcp{rport, gport, seq, ack, 24, 65535, 0, []}, 0)
  +ip = W.Ipv4.head(rip, Slirp.guest_ip(), 6, (20 + len : U32))
  +eth = List.append(&2, U32, Slirp.guest_mac(), List.append(&2, U32, Slirp.gateway_mac(), [8, 0]))
  W.Wire.host_frame(id, off, len, List.append(&2, U32, eth, List.append(&2, U32, ip, tcp)))

def Conn.hseq(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      hseq

# A window field from the guest, scaled by its shift (when it scales).
def Tcp.scaled(+sc: U32, +win: U32) -> U32:
  Bool.pick(U32, U32.is_eq(sc, Tcp.no_scale()), win, (win << U32.to_nat(sc) : U32))

# The room left before wnd from seq on (0 once seq is at or past it).
def Flow.room(+wnd: U32, +seq: U32) -> U32:
  +d = (wnd - seq : U32)
  Bool.pick(U32, U32.is_lt(d, 2147483648), d, 0)

# Whether a lies strictly after b (modulo 2^32).
def Seq.after(+a: U32, +b: U32) -> Bool:
  +d = (a - b : U32)
  U32.is_ne(d, 0) && U32.is_lt(d, 2147483648)

def Conn.with_seq(c: Conn, +hseq: U32) -> Conn:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, h, fl}:
      Conn{id, gport, rip, rport, state, gseq, hseq, fl}

# What an ACK did: the connection, and the commands it adds (a release).
type Acked is Data:
  Acked{conn: Conn, cmds: +List<V.NetCmd>}

def Acked.go(+id: U32, gport: U32, rip: U32, rport: U32, state: U32, gseq: U32, +hseq: U32, +wnd: U32, +una: U32, +dend: U32, +hbase: U32, +hlen: U32, +queue: +List<U32>, +eof: Bool, +sc: U32, +ack: U32, +win: U32, +pure: Bool, +dack: U32, +dwin: U32, +bk: U32) -> Acked:
  # the guest acknowledged new data
  +adv = Seq.after(ack, una) && Bool.not(Seq.after(ack, hseq))
  +una2 = Bool.pick(U32, adv, ack, una)
  +queue2 = List.drop(&2, U32, queue, U32.to_nat(Bool.pick(U32, adv, (ack - una : U32), 0)))
  # the hold is all acknowledged: the host may read on
  +release = U32.is_ne(hlen, 0) && U32.is_le(hlen, (una2 - hbase : U32)) && U32.is_lt((una2 - hbase : U32), 2147483648)
  +wnd2 = (ack + Tcp.scaled(sc, win) : U32)
  # data sent but not acknowledged may be gone: the window's right edge moved
  # back before what was sent, or a duplicate ACK
  +shrunk = Seq.after(hseq, wnd2) && Seq.after(hseq, una2)
  +dup = Bool.not(adv) && pure && U32.is_eq(ack, dack) && U32.is_eq(win, dwin) && U32.is_eq(ack, una2) && U32.is_ne(una2, hseq)
  +again = (shrunk || dup) && U32.is_ne(una2, bk)
  +hseq2 = Bool.pick(U32, again, una2, hseq)
  +c2 = {Conn{id, gport, rip, rport, state, gseq, hseq2, Flow{wnd2, una2, dend, hbase, Bool.pick(U32, release, 0, hlen), queue2, eof, sc, ack, win, Bool.pick(U32, again, una2, bk)}} : Conn}
  Acked{c2, Bool.pick(+List<V.NetCmd>, release, [V.TcpRelease{id}], [])}

# c after a guest segment: with ACK set, acknowledged data goes, the window
# ends at ack + window, and data that may have been dropped is sent again
# from una (go-back): when the window shrank before it, or on a duplicate
# ACK (pure: the segment carries no data and no SYN or FIN).
def Conn.acked(acked: Bool, c: Conn, +ack: U32, +win: U32, +pure: Bool) -> Acked:
  match acked:
    case False{}:
      Acked{c, []}
    case True{}:
      match c:
        case Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}:
          Acked.go(id, gport, rip, rport, state, gseq, hseq, wnd, una, dend, hbase, hlen, queue, eof, sc, ack, win, pure, dack, dwin, bk)

# What sending what the window has room for gave: the connection after it,
# and its segments for the guest in order.
type Sent is Data:
  Sent{conn: Conn, frames: +List<+List<U32>>}

def Sent.more(fs: +List<+List<U32>>, s: Sent) -> Sent:
  match s:
    case Sent{c, gs}:
      Sent{c, List.append(&2, +List<U32>, fs, gs)}

# How many bytes the next segment carries: what the window has room for, of
# the data not yet sent, at most 65495 (one IPv4 packet) from the hold, 1460
# per segment from the queue (Tcp.data_frames cuts them).
def Conn.next_n(+c: Conn, +cap: U32) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, +hseq, Flow{+wnd, una, +dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}:
      U32.min(Flow.room(dend, hseq), U32.min(Flow.room(wnd, hseq), cap))

def Conn.held_frame(+c: Conn, +n: U32) -> +List<U32>:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, +hseq, Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}:
      Tcp.host_frame(id, rip, rport, gport, hseq, gseq, (hseq - hbase : U32), n)

# Held bytes as host frames while the window has room (f bounds the
# segments: a hold is at most one host read, 65495 bytes).
def Tcp.send_held(f: Nat, +c: Conn) -> Sent:
  match f:
    case 0n:
      Sent{c, []}
    case 1n+p:
      +n = Conn.next_n(c, 65495)
      Bool.pick(Sent, U32.is_zero(n), Sent{c, []}, Sent.more([Conn.held_frame(c, n)], Tcp.send_held(p, Conn.with_seq(c, (Conn.hseq(c) + n : U32)))))

def Tcp.send_queue.go(+c: Conn, +n: U32) -> Sent:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, +hseq, Flow{wnd, +una, dend, hbase, hlen, +queue, eof, sc, dack, dwin, bk}}:
      +bytes = B.Bytes.slice(queue, U32.to_nat((hseq - una : U32)), U32.to_nat(n))
      +c1 = {Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}} : Conn}
      Sent{Conn.with_seq(c1, (hseq + n : U32)), Tcp.data_frames(c1, hseq, gseq, bytes)}

# Queued bytes not yet sent, as many as the window has room for, as segments
# of at most 1460 bytes.
def Tcp.send_queue(+c: Conn) -> Sent:
  Tcp.send_queue.go(c, Conn.next_n(c, 4294967295))

def Conn.flow(+c: Conn) -> Flow:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, fl}:
      fl

# c after its FIN: hseq one past the data, state HostFin.
def Conn.fin_sent(c: Conn) -> Conn:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, +dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}:
      Conn{id, gport, rip, rport, Conn.with_phase(state, Conn.host_fin()), gseq, (dend + 1 : U32), Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}

def Tcp.fin.done(closing: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, fs: +List<+List<U32>>) -> SlirpOut:
  match closing:
    case True{}:
      SlirpOut{Slirp{rest, next_id}, fs, [V.TcpClose{Conn.id(c)}]}
    case False{}:
      SlirpOut{Slirp{c <> rest, next_id}, fs, []}

# The FIN after the host's EOF, once its data is all sent: FIN|ACK (seq
# dend, ack gseq), state HostFin; after GuestFin the connection closes
# (V.TcpClose) and is forgotten. A FIN sent again (go-back) changes nothing
# else.
def Tcp.fin(go: Bool, closing: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, fs: +List<+List<U32>>) -> SlirpOut:
  match go:
    case False{}:
      SlirpOut{Slirp{c <> rest, next_id}, fs, []}
    case True{}:
      Tcp.fin.done(closing, Conn.fin_sent(c), rest, next_id, List.append(&2, +List<U32>, fs, [Conn.frame(c, 17, Conn.hseq(c), Conn.gseq(c), 0, [])]))

# Whether the FIN goes now: the host finished and its data is all sent.
def Flow.fin_due(f: Flow, +hseq: U32) -> Bool:
  match f:
    case Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}:
      eof && U32.is_eq(hseq, dend)

def Tcp.push.sent(s: Sent, rest: +List<Conn>, next_id: U32) -> SlirpOut:
  match s:
    case Sent{+c, fs}:
      Tcp.fin(Flow.fin_due(Conn.flow(c), Conn.hseq(c)), U32.is_eq(Conn.state(c), Conn.guest_fin()), c, rest, next_id, fs)

# Sends what the guest's window has room for: held bytes as host frames,
# else queued bytes; then the FIN, when the host finished and nothing is
# left to send.
def Tcp.push(c: Conn, rest: +List<Conn>, next_id: U32) -> SlirpOut:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, +hlen, queue, eof, sc, dack, dwin, bk}}:
      +c = {Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}} : Conn}
      Tcp.push.sent(Bool.pick(Sent, U32.is_zero(hlen), Tcp.send_queue(c), Tcp.send_held(4n, c)), rest, next_id)

# o's frames and commands after fs and cs.
def Tcp.after(fs: +List<+List<U32>>, cs: +List<V.NetCmd>, o: SlirpOut) -> SlirpOut:
  match o:
    case SlirpOut{n, fs2, cs2}:
      SlirpOut{n, List.append(&2, +List<U32>, fs, fs2), List.append(&2, V.NetCmd, cs, cs2)}

def Tcp.push_found(f: Found, next_id: U32, fs: +List<+List<U32>>, cs: +List<V.NetCmd>) -> SlirpOut:
  match f:
    case Found{m, rest}:
      match m:
        case None{}:
          SlirpOut{Slirp{rest, next_id}, fs, cs}
        case Some{c}:
          Tcp.after(fs, cs, Tcp.push(c, rest, next_id))

# After a step that may have opened the window: sends what it now has room
# for on connection id, after the step's own frames and commands.
def Tcp.push_id(o: SlirpOut, +id: U32) -> SlirpOut:
  match o:
    case SlirpOut{Slirp{conns, next_id}, fs, cs}:
      Tcp.push_found(Conns.take(conns, ById{id}), next_id, fs, cs)

# Guest segments for a known connection: a SYN is dropped, a RST closes it.
def Tcp.known(syn: Bool, rst: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, +seq: U32, pl: Payload, fin: Bool) -> SlirpOut:
  match syn rst:
    case True{} _:
      SlirpOut{Slirp{c <> rest, next_id}, [], Payload.drop(pl)}
    case False{} True{}:
      SlirpOut{Slirp{rest, next_id}, [], V.TcpClose{Conn.id(c)} <> Payload.drop(pl)}
    case False{} False{}:
      Tcp.in_seq(U32.is_eq(seq, Conn.gseq(c)), c, rest, next_id, pl, fin)

def Tcp.segment.acked(a: Acked, +id: U32, rest: +List<Conn>, next_id: U32, +seq: U32, +flags: U32, pl: Payload) -> SlirpOut:
  match a:
    case Acked{c2, cs}:
      Tcp.after([], cs, Tcp.push_id(Tcp.known(Tcp.is_open(flags), Tcp.flag(flags, 4), c2, rest, next_id, seq, pl, Tcp.flag(flags, 1)), id))

# A guest segment on known connection c. In SynSent (early) only a RST
# counts: anything else is dropped and changes nothing.
def Tcp.segment.known(early: Bool, +c: Conn, rest: +List<Conn>, next_id: U32, +seq: U32, +ack: U32, +flags: U32, +window: U32, +pl: Payload) -> SlirpOut:
  match early:
    case True{}:
      SlirpOut{Slirp{c <> rest, next_id}, [], Payload.drop(pl)}
    case False{}:
      +pure = U32.is_zero(Payload.len(pl)) && Bool.not(Tcp.flag(flags, 1)) && Bool.not(Tcp.flag(flags, 2))
      Tcp.segment.acked(Conn.acked(Tcp.flag(flags, 16), c, ack, window, pure), Conn.id(c), rest, next_id, seq, flags, pl)

# A guest segment t, its data pl (t's own bytes, or staged on the host).
def Tcp.segment(f: Found, next_id: U32, rip: U32, t: W.Tcp, +pl: Payload, ws: U32) -> SlirpOut:
  match f:
    case Found{m, rest}:
      match m:
        case None{}:
          match t:
            case W.Tcp{sport, dport, seq, ack, +flags, window, mss, data}:
              Tcp.unknown(Tcp.is_open(flags), rest, next_id, rip, sport, dport, seq, ack, window, ws, pl)
        case Some{+c}:
          match t:
            case W.Tcp{sport, dport, seq, ack, +flags, window, mss, data}:
              Tcp.segment.known(U32.is_eq(Conn.state(c), Conn.syn_sent()) && Bool.not(Tcp.flag(flags, 4)), c, rest, next_id, seq, ack, flags, window, pl)

# A segment's own bytes, or the staged data when there is a slot.
def Payload.of(staged: Maybe<&2, Payload>, +t: W.Tcp) -> Payload:
  match staged:
    case Some{p}:
      p
    case None{}:
      Bytes{W.Tcp.payload(t)}

# ws: the window scale option of the segment's header (W.Tcp.wscale).
def Slirp.tcp(n: Slirp, +rip: U32, m: Maybe<&2, W.Tcp>, staged: Maybe<&2, Payload>, ws: U32) -> SlirpOut:
  match n:
    case Slirp{conns, next_id}:
      match m:
        case None{}:
          SlirpOut{Slirp{conns, next_id}, [], Payload.drop(Maybe.default(&2, Payload, staged, Bytes{[]}))}
        case Some{+t}:
          match t:
            case W.Tcp{+sport, +dport, seq, ack, flags, window, mss, data}:
              Tcp.segment(Conns.take(conns, ByAddr{sport, rip, dport}), next_id, rip, t, Payload.of(staged, t), ws)

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

def Slirp.udp_to(dhcp: Bool, n: Slirp, sport: U32, +dst: U32, +dport: U32, data: +List<U32>) -> SlirpOut:
  match dhcp:
    case True{}:
      Slirp.dhcp(n, D.Dhcp.reply(data))
    case False{}:
      SlirpOut{n, [], Bool.pick(+List<V.NetCmd>, Slirp.dst_ok(dst, dport), [V.UdpSend{sport, dst, dport, data}], [])}

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
      Slirp.tcp(n, dst, W.Tcp.parse(payload), None{}, W.Tcp.wscale(payload))
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

# A staged frame (W.Wire.staged_frame): a TCP segment whose payload waits on
# the host; anything else in one has its slot freed.
def Slirp.staged_tcp(tcp: Bool, n: Slirp, +dst: U32, +payload: +List<U32>, st: Payload) -> SlirpOut:
  match tcp:
    case True{}:
      Slirp.tcp(n, dst, W.Tcp.parse(payload), Some{st}, W.Tcp.wscale(payload))
    case False{}:
      SlirpOut{n, [], Payload.drop(st)}

def Slirp.staged_ip(n: Slirp, st: Payload, m: Maybe<&2, W.Ipv4>) -> SlirpOut:
  match m:
    case None{}:
      SlirpOut{n, [], Payload.drop(st)}
    case Some{W.Ipv4{src, dst, +proto, ttl, id, payload}}:
      Slirp.staged_tcp(U32.is_eq(proto, 6), n, dst, payload, st)

def Slirp.staged_eth(n: Slirp, st: Payload, m: Maybe<&2, W.Eth>) -> SlirpOut:
  match m:
    case None{}:
      SlirpOut{n, [], Payload.drop(st)}
    case Some{W.Eth{dst, src, ty, payload}}:
      Slirp.staged_ip(n, st, W.Ipv4.parse(payload))

# A staged frame's headers parse as a packet without its payload: the IPv4
# total length is set to the headers' own.
def Slirp.staged(n: Slirp, frame: +List<U32>) -> SlirpOut:
  match frame:
    case Con{tag, Con{slot, Con{len, +head}}}:
      +ip_len = U32.from_nat(Nat.sub(List.length(&2, U32, head), 14n))
      +fixed = List.set(&2, U32, List.set(&2, U32, head, 16n, (ip_len >> 8n : U32)), 17n, (ip_len .&. 255 : U32))
      Slirp.staged_eth(n, Staged{slot, len}, W.Eth.parse(fixed))
    case _:
      Slirp.none(n)

def Slirp.guest_frame.go(staged: Bool, n: Slirp, frame: +List<U32>) -> SlirpOut:
  match staged:
    case True{}:
      Slirp.staged(n, frame)
    case False{}:
      Slirp.eth(n, W.Eth.parse(frame))

def Slirp.guest_frame(n: Slirp, +frame: +List<U32>) -> SlirpOut:
  Slirp.guest_frame.go(W.Wire.is_staged(frame), n, frame)

# What the host reported on a TCP connection.
type HostTcp is Data:
  HConnected{}
  HRefused{}
  HData{bytes: +List<U32>}
  HEof{}
  HReady{len: U32}
  HBlocked{on: Bool}
  HReset{}

# The SYN|ACK (MSS 1460): with the window scale option (Tcp.our_scale) when
# the guest's SYN had one.
def Tcp.synack(plain: Bool, +c: Conn, seq: U32, ack: U32) -> +List<U32>:
  match plain:
    case True{}:
      Conn.frame(c, 18, seq, ack, 1460, [])
    case False{}:
      match c:
        case Conn{id, gport, +rip, rport, state, gseq, hseq, fl}:
          +opts = {[2, 4, 5, 180, 1, 3, 3, Tcp.our_scale()] : +List<U32>}
          Slirp.ip_frame(rip, 6, W.Tcp.build_opts(rip, Slirp.guest_ip(), W.Tcp{rport, gport, seq, ack, 18, 65535, 0, []}, opts))

# c blocked (on) or not; once unblocked, an ACK opens the guest's window.
def Tcp.blocked(+on: Bool, c: Conn, rest: +List<Conn>, next_id: U32) -> SlirpOut:
  match c:
    case Conn{id, gport, rip, rport, +state, gseq, hseq, fl}:
      +st = Bool.pick(U32, on, (state .|. Conn.blocked() : U32), Conn.phase(state))
      +c2 = {Conn{id, gport, rip, rport, st, gseq, hseq, fl} : Conn}
      +open = Bool.not(on) && U32.is_ne(Conn.phase(st), Conn.syn_sent())
      SlirpOut{Slirp{c2 <> rest, next_id}, Bool.pick(+List<+List<U32>>, open, [Conn.ack(c2)], []), []}

# A host event on c. Data joins the flow (queued bytes, or a new hold that
# starts where the data so far ends) and goes out as the guest's window
# allows; the EOF marks the flow finished.
def Tcp.host(+c: Conn, rest: +List<Conn>, next_id: U32, h: HostTcp) -> SlirpOut:
  match c:
    case Conn{id, gport, rip, rport, state, +gseq, +hseq, Flow{wnd, una, +dend, hbase, hlen, queue, eof, +sc, dack, dwin, bk}}:
      match h:
        case HConnected{}:
          +synack = Tcp.synack(U32.is_eq(sc, Tcp.no_scale()), c, hseq, gseq)
          c2 = {Conn{id, gport, rip, rport, Conn.with_phase(state, Conn.established()), gseq, (hseq + 1 : U32), Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}} : Conn}
          SlirpOut{Slirp{c2 <> rest, next_id}, [synack], []}
        case HRefused{}:
          SlirpOut{Slirp{rest, next_id}, [Conn.frame(c, 20, 0, gseq, 0, [])], []}
        case HData{+bytes}:
          +n = U32.from_nat(List.length(&2, U32, bytes))
          Tcp.push(Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, (dend + n : U32), hbase, hlen, List.append(&2, U32, queue, bytes), eof, sc, dack, dwin, bk}}, rest, next_id)
        case HEof{}:
          Tcp.push(Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, hlen, queue, True{}, sc, dack, dwin, bk}}, rest, next_id)
        case HReady{+len}:
          Tcp.push(Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, (dend + len : U32), dend, len, queue, eof, sc, dack, dwin, bk}}, rest, next_id)
        case HBlocked{on}:
          Tcp.blocked(on, Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}, rest, next_id)
        case HReset{}:
          SlirpOut{Slirp{rest, next_id}, [Conn.frame(c, 20, hseq, gseq, 0, [])], [V.TcpClose{id}]}

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
        case V.TcpReady{id, len}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HReady{len})
        case V.TcpBlocked{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HBlocked{True{}})
        case V.TcpUnblocked{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HBlocked{False{}})
        case V.TcpReset{id}:
          Tcp.host_event(Conns.take(conns, ById{id}), next_id, HReset{})
        case V.UdpData{+ip, port, dport, bytes}:
          frame = Slirp.ip_frame(ip, 17, W.Udp.build(ip, Slirp.guest_ip(), W.Udp{port, dport, bytes}))
          SlirpOut{Slirp{conns, next_id}, [frame], []}

# On the byte path (no hold) the queue holds the bytes from una to dend, so
# its counts come from the sequence numbers, in O(1).

# The bytes queued for the guest on every connection (TcpData waiting for
# room in the guest's window).
def Conns.queued(cs: +List<Conn>) -> U32:
  match cs:
    case Nil{}:
      0
    case Conn{id, gport, rip, rport, state, gseq, +hseq, Flow{wnd, una, +dend, +hbase, +hlen, queue, eof, sc, dack, dwin, bk}} <> t:
      # the queued bytes not yet sent
      (Bool.pick(U32, U32.is_zero(hlen), Flow.room(dend, hseq), 0) + Conns.queued(t) : U32)

def Slirp.queued(n: Slirp) -> U32:
  match n:
    case Slirp{conns, next_id}:
      Conns.queued(conns)

# The bytes connection c queues for the guest, sent or not.
def Conn.queue_len(+c: Conn) -> U32:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, hseq, Flow{wnd, +una, +dend, hbase, +hlen, queue, eof, sc, dack, dwin, bk}}:
      Bool.pick(U32, U32.is_zero(hlen), Flow.room(dend, una), 0)

def Conns.queue_len(cs: +List<Conn>, +id: U32) -> U32:
  match cs:
    case Nil{}:
      0
    case +c <> t:
      Bool.pick(U32, U32.is_eq(Conn.id(c), id), Conn.queue_len(c), Conns.queue_len(t, id))

# Whether the host may read connection id on: its queue for the guest holds
# less than Slirp.queue_cap bytes (an unknown connection: yes).
def Slirp.may_read(n: Slirp, +id: U32) -> Bool:
  match n:
    case Slirp{conns, next_id}:
      U32.is_lt(Conns.queue_len(conns, id), Slirp.queue_cap())

# A connection, for the control socket's net command: its addresses, state,
# sequence numbers and flow toward the guest.
def Conn.show(c: Conn) -> String:
  match c:
    case Conn{id, gport, rip, rport, state, gseq, +hseq, Flow{+wnd, una, dend, hbase, hlen, queue, eof, sc, dack, dwin, bk}}:
      "tcp " ++ U32.show(id) ++ " " ++ U32.show(gport) ++ " -> " ++ U32.show(rip) ++ ":" ++ U32.show(rport) ++ " state " ++ U32.show(state) ++ " gseq " ++ U32.show(gseq) ++ " una " ++ U32.show(una) ++ " hseq " ++ U32.show(hseq) ++ " dend " ++ U32.show(dend) ++ " wnd " ++ U32.show(wnd) ++ " room " ++ U32.show(Flow.room(wnd, hseq)) ++ " hold " ++ U32.show(hbase) ++ "+" ++ U32.show(hlen) ++ " queued " ++ U32.show(U32.from_nat(List.length(&2, U32, queue))) ++ " eof " ++ U32.show(Bool.to_u32(eof)) ++ " scale " ++ U32.show(sc) ++ " last ack " ++ U32.show(dack) ++ "/" ++ U32.show(dwin)

def Conns.show(cs: +List<Conn>) -> String:
  match cs:
    case Nil{}:
      ""
    case c <> t:
      Conn.show(c) ++ "\n" ++ Conns.show(t)

def Slirp.show(n: Slirp) -> String:
  match n:
    case Slirp{conns, next_id}:
      Conns.show(conns) ++ "next " ++ U32.show(next_id)
