import Base
import ../lib/bytes.bend as B

# A DHCP server (RFC 2131) for the NAT's single guest. Every lease is the same:
#   address 10.0.2.15 (167772687), netmask 255.255.255.0, router 10.0.2.2
#   (167772674), DNS 10.0.2.3 (167772675), lease 86400 s, server 10.0.2.2.
# A reply copies xid, flags and chaddr from the request; op 2, htype 1,
# hlen 6, hops 0, secs 0, ciaddr 0, yiaddr 10.0.2.15, siaddr 10.0.2.2,
# giaddr 0, sname and file zero, the magic cookie 99 130 83 99, then the
# options in this order: 53 (message type), 54 (server id), 51 (lease time),
# 1 (subnet mask), 3 (router), 6 (DNS), and 255 (end); no padding after.
# DISCOVER (53 = 1) gets OFFER (2); REQUEST (53 = 3) gets ACK (5); anything
# else (or a message shorter than 240 bytes, or op != 1, or no cookie) gets
# nothing.

def Dhcp.reply(msg: +List<U32>) -> Maybe<&2, +List<U32>>:
  ?TODO
