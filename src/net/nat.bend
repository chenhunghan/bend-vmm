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

def Slirp.guest_frame(n: Slirp, frame: +List<U32>) -> SlirpOut:
  ?TODO

def Slirp.host_event(n: Slirp, ev: V.NetEvent) -> SlirpOut:
  ?TODO
