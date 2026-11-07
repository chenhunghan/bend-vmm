import Base
import ../src/lib/bytes.bend as B
import ../src/net/wire.bend as W
import ../src/virtio/lan.bend as L

# Spec for src/virtio/lan.bend: where a guest's LAN frame goes, its DHCP
# answer, and what waits for the guest.

def me() -> +List<U32>:
  [82, 84, 1, 0, 3, 11]

def peer() -> +List<U32>:
  [82, 84, 1, 0, 3, 12]

# 10.0.3.11 (167772939) in a /24
def ip() -> U32:
  167772939

# An Ethernet header to dst, then an IPv4 header (proto) and a UDP header
# (dport): 42 bytes, what the device reads of a frame.
def head(dst: +List<U32>, ethertype: U32, proto: U32, dport: U32) -> +List<U32>:
  List.concat(&2, U32, [dst, me(), W.Wire.be16(ethertype), [69, 0, 0, 28, 0, 0, 0, 0, 64, proto, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255], W.Wire.be16(68), W.Wire.be16(dport), [0, 8, 0, 0]])

law lan.unicast:
  {L.Lan.route(head(peer(), 2048, 6, 80), 60, me(), ip()) == L.ToMac{peer()} : L.Route}

law lan.broadcast:
  {L.Lan.route(head([255, 255, 255, 255, 255, 255], 2054, 0, 0), 60, me(), ip()) == L.ToAll{} : L.Route}

law lan.multicast:
  {L.Lan.route(head([1, 0, 94, 0, 0, 251], 2048, 17, 5353), 60, me(), ip()) == L.ToAll{} : L.Route}

law lan.to_self:
  {L.Lan.route(head(me(), 2048, 6, 80), 60, me(), ip()) == L.Nowhere{} : L.Route}

law lan.too_short:
  {L.Lan.route(head(peer(), 2048, 6, 80), 13, me(), ip()) == L.Nowhere{} : L.Route}

law lan.dhcp_answered:
  {L.Lan.route(head([255, 255, 255, 255, 255, 255], 2048, 17, 67), 342, me(), ip()) == L.ToDhcp{} : L.Route}

# with no address, a DHCP request is just a broadcast
law lan.dhcp_no_address:
  {L.Lan.route(head([255, 255, 255, 255, 255, 255], 2048, 17, 67), 342, me(), 0) == L.ToAll{} : L.Route}

law lan.mask_24:
  {L.Lan.mask(24) == 4294967040 : U32}

law lan.mask_0:
  {L.Lan.mask(0) == 0 : U32}

law lan.mask_32:
  {L.Lan.mask(32) == 4294967295 : U32}

# 10.0.3.254
law lan.server_24:
  {L.Lan.server_ip(ip(), 24) == 167773182 : U32}

def discover() -> +List<U32>:
  List.concat(&2, U32, [[1, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0], B.Bytes.zeros(16n), me(), B.Bytes.zeros(10n), B.Bytes.zeros(192n), [99, 130, 83, 99, 53, 1, 1, 255]])

def request() -> +List<U32>:
  List.concat(&2, U32, [[1, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0], B.Bytes.zeros(16n), me(), B.Bytes.zeros(10n), B.Bytes.zeros(192n), [99, 130, 83, 99, 53, 1, 3, 255]])

# OFFER: xid and flags copied, yiaddr 10.0.3.11, siaddr 10.0.3.254, chaddr
# copied; options: OFFER, server 10.0.3.254, a lease that never ends,
# netmask 255.255.255.0, no router, no DNS.
law lan.offer:
  {L.Lan.dhcp_reply(discover(), ip(), 24) == Some{List.concat(&2, U32, [[2, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0, 0, 0, 0, 0, 10, 0, 3, 11, 10, 0, 3, 254, 0, 0, 0, 0], me(), B.Bytes.zeros(10n), B.Bytes.zeros(192n),
    [99, 130, 83, 99, 53, 1, 2, 54, 4, 10, 0, 3, 254, 51, 4, 255, 255, 255, 255, 1, 4, 255, 255, 255, 0, 255]])} : Maybe<&2, +List<U32>>}

law lan.ack_type:
  {List.take(&2, U32, List.drop(&2, U32, Maybe.default(&2, +List<U32>, L.Lan.dhcp_reply(request(), ip(), 24), []), 240n), 3n) == [53, 1, 5] : +List<U32>}

law lan.not_dhcp:
  {L.Lan.dhcp_reply([1, 2, 3], ip(), 24) == None{} : Maybe<&2, +List<U32>>}

# what waits for the guest: answers kept, a held frame appended, and
# forgotten after a restore (the host holds nothing then)
law lan.ready:
  {L.Lan.ready(L.Lan{me(), ip(), 24, [L.Local{[1]}]}, 60) == L.Lan{me(), ip(), 24, [L.Local{[1]}, L.Held{60}]} : L.Lan}

law lan.forget_held:
  {L.Lan.forget_held(L.Lan{me(), ip(), 24, [L.Held{60}, L.Local{[1]}]}) == L.Lan{me(), ip(), 24, [L.Local{[1]}]} : L.Lan}

law lan.keep_bounded:
  {List.length(&2, L.LanRx, L.Lan.rx_of(L.Lan.keep(L.Lan{me(), ip(), 24, List.replicate(L.LanRx, 8n, L.Local{[1]})}, Some{[2]}))) == 8n : Nat}
