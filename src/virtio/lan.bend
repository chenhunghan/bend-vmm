import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q
import ../net/wire.bend as W
import ../net/dhcp.bend as D

# virtio-net on a host LAN (--lan): a second NIC whose frames go to the
# other VMs on the same LAN directory, never through a NAT
# (laws/lan.bend). Every VMM on the LAN binds a Unix datagram socket named
# by its MAC; a unicast frame goes to the socket of its destination MAC, a
# broadcast or multicast one to every socket (the host does the sending:
# V.LanSend). No frame byte passes through Bend but the headers it routes by.
#
# The device offers VIRTIO_F_VERSION_1 and VIRTIO_NET_F_MAC only (no
# checksum or segmentation offload: the guest sends whole 1514-byte frames
# with checksums), config space its MAC. Every chain starts with the 12-byte
# virtio_net_hdr.
#
# DHCP: when the device has an address (ip, prefix), it answers its own
# guest's DHCP DISCOVER and REQUEST with that address, its netmask, a lease
# that never ends, no router and no DNS (the NAT NIC keeps the default
# route): every VM keeps its address across restarts. The answers come from
# Lan.server_ip (the subnet's .254-style last address but one) and
# Lan.server_mac.
#
# Receive: the host holds at most one frame for the guest (V.LanReady via
# Lan.ready) until the device copies it into a receive chain
# (VmLanToRam) and releases it (V.LanRelease). The device's own DHCP
# answers go first. A frame larger than the chain is dropped (and
# released).

# What waits for the guest: a frame built here (a DHCP answer), or the
# frame the host holds (its length).
type LanRx is Data:
  Local{frame: +List<U32>}
  Held{len: U32}

type Lan is Data:
  Lan{mac: +List<U32>, ip: U32, prefix: U32, rx: +List<LanRx>}

def Lan.new(mac: +List<U32>, ip: U32, prefix: U32) -> Lan:
  Lan{mac, ip, prefix, []}

# VIRTIO_F_VERSION_1 and VIRTIO_NET_F_MAC (bit 5).
def Lan.features() -> U.U64:
  U.U64{1, 32}

def Lan.config(mac: +List<U32>) -> +List<U32>:
  mac

# The most answers kept for the guest (it asks again).
def Lan.max_local() -> Nat:
  8n

# Addresses
# =========

def Lan.mask(+prefix: U32) -> U32:
  Bool.pick(U32, U32.is_zero(prefix), 0, (4294967295 << U32.to_nat((32 - U32.min(prefix, 32) : U32)) : U32))

# The DHCP server's address: the subnet's last address but one (x.y.z.254
# in a /24).
def Lan.server_ip(+ip: U32, +prefix: U32) -> U32:
  +m = Lan.mask(prefix)
  ((ip .&. m : U32) .|. ((U32.not(m) - 1 : U32)) : U32)

def Lan.server_mac() -> +List<U32>:
  # 02:00:00:00:00:fe, locally administered
  [2, 0, 0, 0, 0, 254]

def Lan.bcast_mac() -> +List<U32>:
  [255, 255, 255, 255, 255, 255]

# DHCP
# ====

def Lan.be32(x: U32) -> +List<U32>:
  B.Bytes.be32(x)

# The options of an answer of type t: type, server id, lease (never ends),
# netmask, end.
def Lan.dhcp_options(t: U32, +server: U32, +mask: U32) -> +List<U32>:
  List.concat(&2, U32, [[99, 130, 83, 99, 53, 1, t, 54, 4], Lan.be32(server), [51, 4, 255, 255, 255, 255, 1, 4], Lan.be32(mask), [255]])

# The answer of type t (2 OFFER, 5 ACK) to msg: xid, flags and chaddr
# copied; yiaddr ip, siaddr the server.
def Lan.dhcp_build(t: U32, +msg: +List<U32>, +ip: U32, +server: U32, +mask: U32) -> +List<U32>:
  List.concat(&2, U32, [[2, 1, 6, 0], B.Bytes.slice(msg, 4n, 4n), [0, 0], B.Bytes.slice(msg, 10n, 2n), [0, 0, 0, 0],
    Lan.be32(ip), Lan.be32(server), [0, 0, 0, 0], B.Bytes.slice(msg, 28n, 16n), B.Bytes.zeros(192n), Lan.dhcp_options(t, server, mask)])

def Lan.dhcp_pick(t: Maybe<&2, U32>, +msg: +List<U32>, +ip: U32, +server: U32, +mask: U32) -> Maybe<&2, +List<U32>>:
  match t:
    case None{}:
      None{}
    case Some{+v}:
      Bool.pick(Maybe<&2, +List<U32>>, U32.is_eq(v, 1), Some{Lan.dhcp_build(2, msg, ip, server, mask)},
        Bool.pick(Maybe<&2, +List<U32>>, U32.is_eq(v, 3), Some{Lan.dhcp_build(5, msg, ip, server, mask)}, None{}))

# The DHCP payload's answer for a device with address ip/prefix: DISCOVER
# gets OFFER, REQUEST gets ACK, anything else nothing.
def Lan.dhcp_reply(+msg: +List<U32>, +ip: U32, +prefix: U32) -> Maybe<&2, +List<U32>>:
  Lan.dhcp_pick(D.Dhcp.msg_type(D.Dhcp.is_request(msg), msg), msg, ip, Lan.server_ip(ip, prefix), Lan.mask(prefix))

# The answer's frame: from the server, port 67, to 255.255.255.255 port 68.
def Lan.dhcp_frame(r: Maybe<&2, +List<U32>>, +ip: U32, +prefix: U32) -> Maybe<&2, +List<U32>>:
  match r:
    case None{}:
      None{}
    case Some{body}:
      +srv = Lan.server_ip(ip, prefix)
      +bc = {4294967295 : U32}
      +udp = W.Udp.build(srv, bc, W.Udp{67, 68, body})
      Some{W.Eth.build(W.Eth{Lan.bcast_mac(), Lan.server_mac(), 2048, W.Ipv4.build(W.Ipv4{srv, bc, 17, 64, 0, udp})})}

# Routing
# =======

# Where a frame the guest sends goes, from its first bytes (after the
# virtio_net_hdr): its DHCP request answered here (when the device has an
# address), to the socket of a unicast destination MAC, to every socket
# (broadcast, multicast), or nowhere (too short, or to its own MAC).
type Route is Data:
  ToDhcp{}
  ToMac{mac: +List<U32>}
  ToAll{}
  Nowhere{}

def Lan.is_dhcp(+head: +List<U32>) -> Bool:
  U32.is_eq(W.Wire.u16(head, 12n), 2048) && U32.is_eq(W.Wire.u8(head, 23n), 17)
    && U32.is_eq(W.Wire.u16(head, 36n), 67)

def Lan.same(a: +List<U32>, b: +List<U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Con{x, xs} Con{y, ys}:
      U32.is_eq(x, y) && Lan.same(xs, ys)
    case _ _:
      False{}

def Lan.route(+head: +List<U32>, +len: U32, +mac: +List<U32>, +ip: U32) -> Route:
  +dst = List.take(&2, U32, head, 6n)
  Bool.pick(Route, U32.is_lt(len, 14), Nowhere{},
  Bool.pick(Route, Bool.not(U32.is_zero(ip)) && Lan.is_dhcp(head), ToDhcp{},
  Bool.pick(Route, Lan.same(dst, mac), Nowhere{},
  Bool.pick(Route, U32.is_eq((W.Wire.u8(head, 0n) .&. 1 : U32), 1), ToAll{}, ToMac{dst}))))

# Transmit
# ========

type LanTx is Data:
  LanTx{q: Q.Vq, lan: Lan, used: Bool}

def Lan.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Lan.room(t) : U32)

def Lan.keep.add(+rx: +List<LanRx>, f: Maybe<&2, +List<U32>>) -> +List<LanRx>:
  match f:
    case None{}:
      rx
    case Some{fr}:
      List.drop(&2, LanRx, List.append(&2, LanRx, rx, [Local{fr}]), Nat.sub(Nat.add(List.length(&2, LanRx, rx), 1n), Lan.max_local()))

# A DHCP answer, if any, queued for the guest (at most Lan.max_local()).
def Lan.keep(l: Lan, f: Maybe<&2, +List<U32>>) -> Lan:
  match l:
    case Lan{m, ip, p, rx}:
      Lan{m, ip, p, Lan.keep.add(rx, f)}

def Lan.ip_of(l: Lan) -> U32:
  match l:
    case Lan{m, ip, p, rx}:
      ip

def Lan.mac_of(l: Lan) -> +List<U32>:
  match l:
    case Lan{m, ip, p, rx}:
      m

def Lan.prefix_of(l: Lan) -> U32:
  match l:
    case Lan{m, ip, p, rx}:
      p

# One frame of len bytes in the readable descriptors r, by its route.
def Lan.tx.send(-R: Type, rt: Route, +l: Lan, +r: +List<Q.Desc>, +len: U32) -> V.Op<R, Lan>:
  match rt:
    case Nowhere{}:
      V.Op.pure(R, Lan, l)
    case ToMac{dst}:
      do V.Op<R, Lan>:
        V.Op.net(R, V.LanSend{dst, Q.Vq.segs(r, 12, len)})
        return l
    case ToAll{}:
      do V.Op<R, Lan>:
        V.Op.net(R, V.LanSend{[], Q.Vq.segs(r, 12, len)})
        return l
    case ToDhcp{}:
      do V.Op<R, Lan>:
        +fr : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 12, U32.min(len, 1514)))
        +ipv4 : +List<U32> = List.drop(&2, U32, fr, 14n)
        +udp : +List<U32> = List.drop(&2, U32, ipv4, U32.to_nat(((W.Wire.u8(ipv4, 0n) .&. 15 : U32) * 4 : U32)))
        return Lan.keep(l, Lan.dhcp_frame(Lan.dhcp_reply(List.drop(&2, U32, udp, 8n), Lan.ip_of(l), Lan.prefix_of(l)), Lan.ip_of(l), Lan.prefix_of(l)))

def Lan.tx.serve(-R: Type, q: Q.Vq, c: Q.Chain, +l: Lan) -> V.Op<R, Q.Vq & Lan>:
  match c:
    case Q.Chain{+h, +r, w}:
      +len = (Lan.room(r) - U32.min(12, Lan.room(r)) : U32)
      do V.Op<R, Q.Vq & Lan>:
        +hb : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 12, 42))
        l2 : Lan <- Lan.tx.send(R, Lan.route(hb, len, Lan.mac_of(l), Lan.ip_of(l)), l, r, len)
        q2 : Q.Vq <- Q.Vq.push(R, q, h, 0)
        return (q2, l2)

def Lan.tx.done(-R: Type, st: Q.Vq & Lan, used: Bool) -> V.Op<R, LanTx>:
  match st:
    case (q, l):
      V.Op.pure(R, LanTx, LanTx{q, l, used})

def Lan.tx.step(-R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, l: Lan, used: Bool, k: Q.Vq & Lan -> V.Op<R, LanTx>) -> V.Op<R, LanTx>:
  match r:
    case (q, None{}):
      V.Op.pure(R, LanTx, LanTx{q, l, used})
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq & Lan, LanTx, Lan.tx.serve(R, q, c, l), k)

def Lan.tx.go(fuel: Nat, -R: Type, st: Q.Vq & Lan, used: Bool) -> V.Op<R, LanTx>:
  match fuel:
    case 0n:
      Lan.tx.done(R, st, used)
    case 1n+f:
      match st:
        case (q, l):
          do V.Op<R, LanTx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Lan.tx.step(R, r, l, used, st2 => Lan.tx.go(f, R, st2, True{}))

# Takes every available chain of the transmit queue (at most num): each is
# one frame after its 12-byte header, sent by its route (Lan.route), pushed
# used with length 0.
def Lan.tx(-R: Type, l: Lan, q: Q.Vq) -> V.Op<R, LanTx>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Lan.tx.go(U32.to_nat(num), R, (Q.Vq{num, d, dr, dv, na, nu}, l), False{})

# Receive
# =======

type LanRxOut is Data:
  LanRxOut{q: Q.Vq, left: +List<LanRx>, used: Bool}

# The virtio_net_hdr: zeros but num_buffers = 1.
def Lan.hdr() -> +List<U32>:
  List.append(&2, U32, B.Bytes.zeros(10n), B.Bytes.le16(1))

def Lan.size(x: LanRx) -> U32:
  match x:
    case Local{f}:
      U32.from_nat(List.length(&2, U32, f))
    case Held{n}:
      n

# One item into a chain that fits it: the header and the frame, pushed used.
def Lan.rx.deliver(-R: Type, x: LanRx, q: Q.Vq, +h: U32, +w: +List<Q.Desc>) -> V.Op<R, Q.Vq>:
  match x:
    case Local{+f}:
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, List.append(&2, U32, Lan.hdr(), f))
        Q.Vq.push(R, q, h, (12 + U32.from_nat(List.length(&2, U32, f)) : U32))
    case Held{+n}:
      do V.Op<R, Q.Vq>:
        k : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, Lan.hdr())
        V.Op.lan_to_ram(R, Q.Vq.segs(w, 12, n))
        V.Op.net(R, V.LanRelease{})
        Q.Vq.push(R, q, h, (12 + n : U32))

# An item too large for the chain: dropped (a held frame released); the
# chain is pushed used with length 0.
def Lan.rx.drop(-R: Type, x: LanRx, q: Q.Vq, +h: U32) -> V.Op<R, Q.Vq>:
  match x:
    case Local{f}:
      Q.Vq.push(R, q, h, 0)
    case Held{n}:
      do V.Op<R, Q.Vq>:
        V.Op.net(R, V.LanRelease{})
        Q.Vq.push(R, q, h, 0)

def Lan.rx.fit(-R: Type, fits: Bool, x: LanRx, q: Q.Vq, +h: U32, +w: +List<Q.Desc>) -> V.Op<R, Q.Vq>:
  match fits:
    case True{}:
      Lan.rx.deliver(R, x, q, h, w)
    case False{}:
      Lan.rx.drop(R, x, q, h)

def Lan.rx.serve(-R: Type, +x: LanRx, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, +w}:
      Lan.rx.fit(R, U32.is_le((12 + Lan.size(x) : U32), Lan.room(w)), x, q, h, w)

def Lan.rx.step(-R: Type, r: Q.Vq & Maybe<&2, Q.Chain>, +x: LanRx, rest: +List<LanRx>, used: Bool, k: Q.Vq & Bool -> V.Op<R, LanRxOut>) -> V.Op<R, LanRxOut>:
  match r:
    case (q, None{}):
      V.Op.pure(R, LanRxOut, LanRxOut{q, x <> rest, used})
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, LanRxOut, Lan.rx.serve(R, x, q, c), q2 => k((q2, True{})))

def Lan.rx.go(items: +List<LanRx>, -R: Type, st: Q.Vq & Bool) -> V.Op<R, LanRxOut>:
  match items:
    case Nil{}:
      match st:
        case (q, used):
          V.Op.pure(R, LanRxOut, LanRxOut{q, [], used})
    case Con{x, +rest}:
      match st:
        case (q, used):
          do V.Op<R, LanRxOut>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Lan.rx.step(R, r, x, rest, used, st2 => Lan.rx.go(rest, R, st2))

# Delivers what waits, in order, one item per available chain.
def Lan.rx(-R: Type, l: Lan, q: Q.Vq) -> V.Op<R, LanRxOut>:
  match l:
    case Lan{m, ip, p, rx}:
      Lan.rx.go(rx, R, (q, False{}))

def Lan.with_rx(l: Lan, rx: +List<LanRx>) -> Lan:
  match l:
    case Lan{m, ip, p, old}:
      Lan{m, ip, p, rx}

# The host holds a frame of len bytes for the guest.
def Lan.ready(l: Lan, +len: U32) -> Lan:
  match l:
    case Lan{m, ip, p, rx}:
      Lan{m, ip, p, List.append(&2, LanRx, rx, [Held{len}])}

# Whether anything waits for the guest.
def Lan.pending(l: Lan) -> Bool:
  match l:
    case Lan{m, ip, p, rx}:
      Bool.not(List.is_empty(&2, LanRx, rx))

# After a restore the host holds nothing: the held frame is forgotten.
def Lan.forget_held.go(rx: +List<LanRx>) -> +List<LanRx>:
  match rx:
    case Nil{}:
      []
    case Con{Local{f}, rest}:
      Local{f} <> Lan.forget_held.go(rest)
    case Con{Held{n}, rest}:
      Lan.forget_held.go(rest)

def Lan.forget_held(l: Lan) -> Lan:
  match l:
    case Lan{m, ip, p, rx}:
      Lan{m, ip, p, Lan.forget_held.go(rx)}

def Lan.rx_of(l: Lan) -> +List<LanRx>:
  match l:
    case Lan{m, ip, p, rx}:
      rx
