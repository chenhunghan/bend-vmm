import Base
import ../boot/dtb.bend as T
import ../net/addr.bend as Ad

# The command line (laws/cli.bend): which arguments are valid, and the
# --display spec. host/main.bend fills its options from flag and value pairs
# once Cli.check finds nothing wrong.

def Cli.flags() -> +List<String>:
  ["--kernel", "--initrd", "--payload", "--cmdline", "--mem", "--cpus", "--disk", "--share", "--restore",
   "--control", "--vsock", "--display", "--firmware", "--vars", "--forward", "--lan"]

def Cli.known(+flag: String, fs: +List<String>) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case Con{f, rest}:
      String.eq(f, flag) || Cli.known(flag, rest)

# "WxH" as a display; None for anything malformed.
def Cli.display.mk(w: Maybe<&2, U32>, h: Maybe<&2, U32>) -> Maybe<&2, T.Display>:
  match w h:
    case Some{+x} Some{+y}:
      Bool.pick(Maybe<&2, T.Display>, U32.is_zero(x) || U32.is_zero(y), None{}, Some{T.Display{x, y}})
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

# What is wrong with one flag and its value ("" when nothing): an unknown
# flag; --mem other than 1..1048576 MiB (1 TiB, what a snapshot holds);
# --cpus other than 1..64; a malformed --display.
def Cli.why(+flag: String, +v: String) -> String:
  Bool.pick(String, Bool.not(Cli.known(flag, Cli.flags())), "unknown option " ++ flag,
  Bool.pick(String, String.eq(flag, "--mem") && Bool.not(Cli.within(U32.read(v), 1, 1048576)), "--mem takes MiB, 1 to 1048576 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--cpus") && Bool.not(Cli.within(U32.read(v), 1, 64)), "--cpus takes 1 to 64 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--display") && Bool.not(Cli.is_some(Cli.display(v))), "--display takes WxH or WxH,headless (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--lan") && Bool.not(Cli.lan_ok(Cli.lan(v))), "--lan takes DIR,ip=A.B.C.D/N and/or mac=xx:xx:xx:xx:xx:xx (not " ++ v ++ ")",
  "")))))

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
