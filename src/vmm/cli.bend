import Base
import ../boot/dtb.bend as T

# The command line (laws/cli.bend): which arguments are valid, and the
# --display spec. host/main.bend fills its options from flag and value pairs
# once Cli.check finds nothing wrong.

def Cli.flags() -> +List<String>:
  ["--kernel", "--initrd", "--payload", "--cmdline", "--mem", "--cpus", "--disk", "--share", "--restore",
   "--control", "--vsock", "--display", "--firmware", "--vars", "--forward"]

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

# What is wrong with one flag and its value ("" when nothing): an unknown
# flag; --mem other than 1..1048576 MiB (1 TiB, what a snapshot holds);
# --cpus other than 1..64; a malformed --display.
def Cli.why(+flag: String, +v: String) -> String:
  Bool.pick(String, Bool.not(Cli.known(flag, Cli.flags())), "unknown option " ++ flag,
  Bool.pick(String, String.eq(flag, "--mem") && Bool.not(Cli.within(U32.read(v), 1, 1048576)), "--mem takes MiB, 1 to 1048576 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--cpus") && Bool.not(Cli.within(U32.read(v), 1, 64)), "--cpus takes 1 to 64 (not " ++ v ++ ")",
  Bool.pick(String, String.eq(flag, "--display") && Bool.not(Cli.is_some(Cli.display(v))), "--display takes WxH or WxH,headless (not " ++ v ++ ")",
  ""))))

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
