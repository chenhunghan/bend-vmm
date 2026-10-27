import Base
import ../src/net/addr.bend as A

# Spec for src/net/addr.bend.

law addr.parse:
  {A.Addr.parse("192.168.1.53") == Some{3232235829} : Maybe<&2, U32>}

law addr.parse_bad:
  {A.Addr.parse("192.168.1.256") == None{} : Maybe<&2, U32>}

law addr.nameserver:
  {A.Addr.nameserver("# generated\nsearch lan\nnameserver 10.1.2.3\nnameserver 8.8.8.8\n") == 167838211 : U32}

law addr.nameserver_skips_ipv6:
  {A.Addr.nameserver("nameserver fe80::1\nnameserver 9.9.9.9\n") == 151587081 : U32}

law addr.nameserver_none:
  {A.Addr.nameserver("") == 16843009 : U32}

law addr.gateway_is_host:
  {A.Addr.to_host(167772674, 151587081) == 2130706433 : U32}

law addr.dns_is_resolver:
  {A.Addr.to_host(167772675, 151587081) == 151587081 : U32}

law addr.others_pass:
  {A.Addr.to_host(16909060, 151587081) == 16909060 : U32}

law addr.reply_from_host:
  {A.Addr.to_guest(2130706433, 151587081) == 167772674 : U32}

law addr.reply_from_resolver:
  {A.Addr.to_guest(151587081, 151587081) == 167772675 : U32}
