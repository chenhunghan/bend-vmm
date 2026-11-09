import Base
import ../boot/dtb.bend as T
import ../net/addr.bend as Ad
import ../lib/u64.bend as U
import ./layout.bend as Ly

# The command line (laws/cli.bend): which arguments are valid, and the
# --display spec. host/main.bend fills its options from flag and value pairs
# once Cli.check finds nothing wrong.

def Cli.flags() -> +List<String>:
  ["--kernel", "--initrd", "--payload", "--cmdline", "--mem", "--cpus", "--disk", "--share", "--restore",
   "--control", "--vsock", "--display", "--firmware", "--vars", "--forward", "--lan", "--console-log"]

def Cli.known(+flag: String, fs: +List<String>) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case Con{f, rest}:
      String.eq(f, flag) || Cli.known(flag, rest)

# Whether a WxH display (4 bytes a pixel) fits the framebuffer
# (Layout.fb_size), without overflowing 32 bits.
def Cli.display.fits(+w: U32, +h: U32) -> Bool:
  +px = (Ly.Layout.fb_size() / 4 : U32)
  Bool.not(U32.is_zero(w) || U32.is_zero(h)) && U32.is_le(w, px) && U32.is_le(h, (px / w : U32))

# "WxH" as a display; None for anything malformed or too large.
def Cli.display.mk(w: Maybe<&2, U32>, h: Maybe<&2, U32>) -> Maybe<&2, T.Display>:
  match w h:
    case Some{+x} Some{+y}:
      Bool.pick(Maybe<&2, T.Display>, Cli.display.fits(x, y), Some{T.Display{x, y}}, None{})
    case _ _:
      None{}

def Cli.display.go(ws: List<&2, String>) -> Maybe<&2, T.Display>:
  match ws:
    case Con{w, Con{h, Nil{}}}:
      Cli.display.mk(U32.read(w), U32.read(h))
    case _:
      None{}

def Cli.display.size(parts: List<&2, String>) -> Maybe<&2, T.Display>:
  match parts:
    case Con{size, rest}:
      Cli.display.go(String.split(size, 'x'))
    case Nil{}:
      None{}

# "WxH" or "WxH,headless" as a display; None for "" or anything malformed.
def Cli.display(spec: String) -> Maybe<&2, T.Display>:
  Cli.display.size(String.split(spec, ','))

def Cli.is_some(m: Maybe<&2, T.Display>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{d}:
      True{}

def Cli.within(n: Maybe<&2, U32>, +lo: U32, +hi: U32) -> Bool:
  match n:
    case None{}:
      False{}
    case Some{+x}:
      U32.is_le(lo, x) && U32.is_le(x, hi)


# --lan DIR[,ip=A.B.C.D/N][,mac=xx:xx:xx:xx:xx:xx]
# ===============================================
# The LAN directory (every VM on the LAN names the same one), the NIC's MAC
# and the address its DHCP answers give. A MAC must be unicast (its first
# byte even); without one it is 52:54:01 and the address's last three bytes,
# so a VM keeps it. An address takes a prefix of 1 to 30. One of ip= and
# mac= is needed.
type LanSpec is Data:
  LanSpec{dir: String, mac: +List<U32>, ip: U32, prefix: U32}

def Cli.hex(+c: U32) -> Maybe<&2, U32>:
  Bool.pick(Maybe<&2, U32>, U32.is_le(48, c) && U32.is_le(c, 57), Some{(c - 48 : U32)},
  Bool.pick(Maybe<&2, U32>, U32.is_le(97, c) && U32.is_le(c, 102), Some{(c - 87 : U32)},
  Bool.pick(Maybe<&2, U32>, U32.is_le(65, c) && U32.is_le(c, 70), Some{(c - 55 : U32)}, None{})))

def Cli.byte.mk(a: Maybe<&2, U32>, b: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match a b:
    case Some{x} Some{y}:
      Some{((x * 16 : U32) + y : U32)}
    case _ _:
      None{}

def Cli.byte(s: String) -> Maybe<&2, U32>:
  match s:
    case SCon{a, SCon{b, SNil{}}}:
      Cli.byte.mk(Cli.hex(Char.to_u32(a)), Cli.hex(Char.to_u32(b)))
    case _:
      None{}

def Cli.bytes.cons(b: Maybe<&2, U32>, rest: Maybe<&2, +List<U32>>) -> Maybe<&2, +List<U32>>:
  match b rest:
    case Some{x} Some{xs}:
      Some{x <> xs}
    case _ _:
      None{}

def Cli.bytes(ps: List<&2, String>) -> Maybe<&2, +List<U32>>:
  match ps:
    case Nil{}:
      Some{[]}
    case Con{p, rest}:
      Cli.bytes.cons(Cli.byte(p), Cli.bytes(rest))

def Cli.mac.check(m: Maybe<&2, +List<U32>>) -> Maybe<&2, +List<U32>>:
  match m:
    case None{}:
      None{}
    case Some{+bs}:
      Bool.pick(Maybe<&2, +List<U32>>, Nat.is_eq(List.length(&2, U32, bs), 6n) && U32.is_zero((Maybe.default(&2, U32, List.head(&2, U32, bs), 1) .&. 1 : U32)), Some{bs}, None{})

# xx:xx:xx:xx:xx:xx, unicast.
def Cli.mac(s: String) -> Maybe<&2, +List<U32>>:
  Cli.mac.check(Cli.bytes(String.split(s, ':')))

def Cli.mac_of_ip(+ip: U32) -> +List<U32>:
  [82, 84, 1, ((ip >> 16n : U32) .&. 255 : U32), ((ip >> 8n : U32) .&. 255 : U32), (ip .&. 255 : U32)]

# Options so far: the MAC, the address and its prefix (0: none), and
# whether every option parsed.
type LanOpts is Data:
  LanOpts{mac: Maybe<&2, +List<U32>>, ip: U32, prefix: U32, ok: Bool}

def Cli.lan.ip.mk(a: Maybe<&2, U32>, p: Maybe<&2, U32>, o: LanOpts) -> LanOpts:
  match a p o:
    case Some{x} Some{+y} LanOpts{m, i, q, ok}:
      LanOpts{m, x, y, ok && U32.is_le(1, y) && U32.is_le(y, 30)}
    case _ _ LanOpts{m, i, q, ok}:
      LanOpts{m, i, q, False{}}

def Cli.lan.ip(parts: List<&2, String>, o: LanOpts) -> LanOpts:
  match parts:
    case Con{a, Con{p, Nil{}}}:
      Cli.lan.ip.mk(Ad.Addr.parse(a), U32.read(p), o)
    case _:
      match o:
        case LanOpts{m, i, q, ok}:
          LanOpts{m, i, q, False{}}

def Cli.lan.mac(m: Maybe<&2, +List<U32>>, o: LanOpts) -> LanOpts:
  match m o:
    case Some{bs} LanOpts{old, i, q, ok}:
      LanOpts{Some{bs}, i, q, ok}
    case None{} LanOpts{old, i, q, ok}:
      LanOpts{old, i, q, False{}}

def Cli.lan.fail(l: LanOpts) -> LanOpts:
  match l:
    case LanOpts{m, i, q, ok}:
      LanOpts{m, i, q, False{}}

def Cli.lan.opt(+o: String, +l: LanOpts) -> LanOpts:
  Bool.pick(LanOpts, String.starts_with(o, "ip="), Cli.lan.ip(String.split(String.drop(o, 3n), '/'), l),
  Bool.pick(LanOpts, String.starts_with(o, "mac="), Cli.lan.mac(Cli.mac(String.drop(o, 4n)), l),
  Cli.lan.fail(l)))

def Cli.lan.opts(os: List<&2, String>, l: LanOpts) -> LanOpts:
  match os:
    case Nil{}:
      l
    case Con{o, rest}:
      Cli.lan.opts(rest, Cli.lan.opt(o, l))

def Cli.lan.make(+dir: String, l: LanOpts) -> Maybe<&2, LanSpec>:
  match l:
    case LanOpts{None{}, +ip, p, ok}:
      Bool.pick(Maybe<&2, LanSpec>, ok && Bool.not(U32.is_zero(ip)) && Bool.not(String.is_empty(dir)), Some{LanSpec{dir, Cli.mac_of_ip(ip), ip, p}}, None{})
    case LanOpts{Some{mac}, ip, p, ok}:
      Bool.pick(Maybe<&2, LanSpec>, ok && Bool.not(String.is_empty(dir)), Some{LanSpec{dir, mac, ip, p}}, None{})

def Cli.lan.parts(ps: List<&2, String>) -> Maybe<&2, LanSpec>:
  match ps:
    case Nil{}:
      None{}
    case Con{dir, rest}:
      Cli.lan.make(dir, Cli.lan.opts(rest, LanOpts{None{}, 0, 0, True{}}))

def Cli.lan(spec: String) -> Maybe<&2, LanSpec>:
  Cli.lan.parts(String.split(spec, ','))

def Cli.lan_ok(m: Maybe<&2, LanSpec>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{l}:
      True{}


# Sizes: decimal bytes, or K, M or G (KiB, MiB, GiB) after the number.
def Cli.u64.times10(+x: U.U64) -> U.U64:
  U.U64.add(U.U64.shl(3n, x), U.U64.shl1(x))

def Cli.u64.digit(+c: U32, acc: Maybe<&2, U.U64>) -> Maybe<&2, U.U64>:
  match acc:
    case None{}:
      None{}
    case Some{+a}:
      Bool.pick(Maybe<&2, U.U64>, U32.is_le(48, c) && U32.is_le(c, 57) && U.U64.is_lt(a, U.U64{429496729, 0}), Some{U.U64.add_u32(Cli.u64.times10(a), (c - 48 : U32))}, None{})

def Cli.u64.digits(cs: String, acc: Maybe<&2, U.U64>) -> Maybe<&2, U.U64>:
  match cs:
    case SNil{}:
      acc
    case SCon{c, rest}:
      Cli.u64.digits(rest, Cli.u64.digit(Char.to_u32(c), acc))

def Cli.u64.scale(m: Maybe<&2, U.U64>, +k: Nat) -> Maybe<&2, U.U64>:
  match m:
    case None{}:
      None{}
    case Some{+x}:
      Bool.pick(Maybe<&2, U.U64>, U.U64.is_lt(x, U.U64.shl(Nat.sub(64n, k), U.U64{0, 1})), Some{U.U64.shl(k, x)}, None{})

def Cli.last(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, SNil{}}:
      Char.to_u32(c)
    case SCon{c, rest}:
      Cli.last(rest)

def Cli.size.by(+s: String, +last: U32) -> Maybe<&2, U.U64>:
  +body = String.take(s, Nat.sub(String.length(s), 1n))
  Bool.pick(Maybe<&2, U.U64>, String.is_empty(s), None{},
  Bool.pick(Maybe<&2, U.U64>, U32.is_eq(last, 75) || U32.is_eq(last, 107), Cli.u64.scale(Cli.u64.digits(body, Some{U.U64.zero()}), 10n),
  Bool.pick(Maybe<&2, U.U64>, U32.is_eq(last, 77) || U32.is_eq(last, 109), Cli.u64.scale(Cli.u64.digits(body, Some{U.U64.zero()}), 20n),
  Bool.pick(Maybe<&2, U.U64>, U32.is_eq(last, 71) || U32.is_eq(last, 103), Cli.u64.scale(Cli.u64.digits(body, Some{U.U64.zero()}), 30n),
  Cli.u64.digits(s, Some{U.U64.zero()})))))

def Cli.size(+s: String) -> Maybe<&2, U.U64>:
  Cli.size.by(s, Cli.last(s))

# --share DIR[,quota=SIZE]: the shared directory and its quota (0: none).
type ShareSpec is Data:
  ShareSpec{dir: String, quota: U.U64}

def Cli.share.opt(+dir: String, m: Maybe<&2, U.U64>) -> Maybe<&2, ShareSpec>:
  match m:
    case None{}:
      None{}
    case Some{q}:
      Bool.pick(Maybe<&2, ShareSpec>, String.is_empty(dir), None{}, Some{ShareSpec{dir, q}})

def Cli.share.parts(ps: List<&2, String>) -> Maybe<&2, ShareSpec>:
  match ps:
    case Con{dir, Nil{}}:
      Cli.share.opt(dir, Some{U.U64.zero()})
    case Con{dir, Con{+o, Nil{}}}:
      Bool.pick(Maybe<&2, ShareSpec>, String.starts_with(o, "quota="), Cli.share.opt(dir, Cli.size(String.drop(o, 6n))), None{})
    case _:
      None{}

def Cli.share(spec: String) -> Maybe<&2, ShareSpec>:
  Cli.share.parts(String.split(spec, ','))

def Cli.share_ok(m: Maybe<&2, ShareSpec>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{x}:
      True{}

# --console-log PATH,max=SIZE[,keep=N]: the console's file, the size it
# rotates at, and how many old ones it keeps (1 when not given; at most 99).
type ConLog is Data:
  ConLog{path: String, max: U.U64, keep: U32}

type ConOpts is Data:
  ConOpts{max: Maybe<&2, U.U64>, keep: U32, ok: Bool}

def Cli.con.keep(m: Maybe<&2, U32>, c: ConOpts) -> ConOpts:
  match m c:
    case Some{+k} ConOpts{x, old, ok}:
      ConOpts{x, k, ok && U32.is_le(k, 99)}
    case None{} ConOpts{x, old, ok}:
      ConOpts{x, old, False{}}

def Cli.con.max(m: Maybe<&2, U.U64>, c: ConOpts) -> ConOpts:
  match m c:
    case Some{+x} ConOpts{old, k, ok}:
      ConOpts{Some{x}, k, ok && Bool.not(U.U64.is_zero(x))}
    case None{} ConOpts{old, k, ok}:
      ConOpts{old, k, False{}}

def Cli.con.fail(c: ConOpts) -> ConOpts:
  match c:
    case ConOpts{x, k, ok}:
      ConOpts{x, k, False{}}

def Cli.con.opt(+o: String, +c: ConOpts) -> ConOpts:
  Bool.pick(ConOpts, String.starts_with(o, "max="), Cli.con.max(Cli.size(String.drop(o, 4n)), c),
  Bool.pick(ConOpts, String.starts_with(o, "keep="), Cli.con.keep(U32.read(String.drop(o, 5n)), c), Cli.con.fail(c)))

def Cli.con.opts(os: List<&2, String>, c: ConOpts) -> ConOpts:
  match os:
    case Nil{}:
      c
    case Con{o, rest}:
      Cli.con.opts(rest, Cli.con.opt(o, c))

def Cli.con.make(+path: String, c: ConOpts) -> Maybe<&2, ConLog>:
  match c:
    case ConOpts{Some{x}, k, ok}:
      Bool.pick(Maybe<&2, ConLog>, ok && Bool.not(String.is_empty(path)), Some{ConLog{path, x, k}}, None{})
    case ConOpts{None{}, k, ok}:
      None{}

def Cli.con.parts(ps: List<&2, String>) -> Maybe<&2, ConLog>:
  match ps:
    case Nil{}:
      None{}
    case Con{path, rest}:
      Cli.con.make(path, Cli.con.opts(rest, ConOpts{None{}, 1, True{}}))

def Cli.conlog(spec: String) -> Maybe<&2, ConLog>:
  Cli.con.parts(String.split(spec, ','))

def Cli.conlog_ok(m: Maybe<&2, ConLog>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{x}:
      True{}

# The last value given for flag in the arguments (flag and value pairs), or "".
def Cli.find(args: List<String>, +flag: String) -> String:
  match args:
    case Nil{}:
      ""
    case Con{+f, rest}:
      match rest:
        case Nil{}:
          ""
        case Con{+v, more}:
          +later = Cli.find(more, flag)
          Bool.pick(String, String.is_empty(later) && String.eq(f, flag), v, later)

# --forward [ADDR:]HOSTPORT:GUESTPORT[,...]: the host listens on ADDR
# (127.0.0.1 when not given) port HOSTPORT, and each client becomes a NAT
# connection to the guest's GUESTPORT.

type Fwd is Data:
  Fwd{addr: String, hport: U32, gport: U32}

def Fwd.port.ok(m: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case None{}:
      None{}
    case Some{+p}:
      Bool.pick(Maybe<&2, U32>, U32.is_ne(p, 0) && U32.is_le(p, 65535), Some{p}, None{})

# A port: 1 to 65535.
def Fwd.port(s: String) -> Maybe<&2, U32>:
  Fwd.port.ok(U32.read(s))

def Fwd.mk(addr: String, h: Maybe<&2, U32>, g: Maybe<&2, U32>) -> Maybe<&2, Fwd>:
  match h g:
    case Some{hp} Some{gp}:
      Some{Fwd{addr, hp, gp}}
    case _ _:
      None{}

def Fwd.parse.parts(parts: List<&2, String>) -> Maybe<&2, Fwd>:
  match parts:
    case Con{h, Con{g, Nil{}}}:
      Fwd.mk("127.0.0.1", Fwd.port(h), Fwd.port(g))
    case Con{a, Con{h, Con{g, Nil{}}}}:
      Fwd.mk(a, Fwd.port(h), Fwd.port(g))
    case _:
      None{}

# "[ADDR:]HOSTPORT:GUESTPORT" as a forward; None for anything malformed.
def Fwd.parse(spec: String) -> Maybe<&2, Fwd>:
  Fwd.parse.parts(String.split(spec, ':'))

def Fwd.specs(s: String) -> List<&2, String>:
  +s = s
  Bool.pick(List<&2, String>, String.is_empty(s), [], String.split(s, ','))

# The most forwards (the host keeps as many listeners).
def Fwd.max() -> U32:
  16

def Fwd.ok(m: Maybe<&2, Fwd>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{f}:
      True{}

# Every spec of one --forward value parses.
def Fwd.all_ok(ss: List<&2, String>) -> Bool:
  match ss:
    case Nil{}:
      True{}
    case Con{x, rest}:
      Fwd.ok(Fwd.parse(x)) && Fwd.all_ok(rest)

# What is wrong with one flag and its value ("" when nothing): an unknown
# flag; --mem other than 1..1048576 MiB (1 TiB, what a snapshot holds);
# --cpus other than 1..64; a malformed --display.
def Cli.why(+flag: String, +v: String) -> String:
  Bool.pick(String, Bool.not(Cli.known(flag, Cli.flags())), "unknown option " ++ flag,
  Bool.pick(String, String.eq(flag, "--mem") && Bool.not(Cli.within(U32.read(v), 1, 1048576)), "--mem takes MiB, 1 to 1048576 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--cpus") && Bool.not(Cli.within(U32.read(v), 1, 64)), "--cpus takes 1 to 64 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--display") && Bool.not(Cli.is_some(Cli.display(v))), "--display takes WxH or WxH,headless (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--lan") && Bool.not(Cli.lan_ok(Cli.lan(v))), "--lan takes DIR,ip=A.B.C.D/N and/or mac=xx:xx:xx:xx:xx:xx (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--share") && Bool.not(Cli.share_ok(Cli.share(v))), "--share takes DIR or DIR,quota=SIZE (bytes, or K, M, G) (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--console-log") && Bool.not(Cli.conlog_ok(Cli.conlog(v))), "--console-log takes PATH,max=SIZE[,keep=N] (N up to 99) (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--forward") && Bool.not(Fwd.all_ok(Fwd.specs(v))), "--forward takes [ADDR:]HOSTPORT:GUESTPORT[,...] (ports 1 to 65535) (not " ++ v ++ ")",
  ""))))))))

# The first thing wrong with the arguments (flag and value pairs), or "".
def Cli.check(args: List<String>) -> String:
  match args:
    case Nil{}:
      ""
    case Con{+flag, rest}:
      match rest:
        case Nil{}:
          Bool.pick(String, Cli.known(flag, Cli.flags()), flag ++ " needs a value", "unknown option " ++ flag)
        case Con{+v, more}:
          +why = Cli.why(flag, v)
          Bool.pick(String, String.is_empty(why), Cli.check(more), why)
