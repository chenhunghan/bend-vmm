import Base

# The management protocol (--control): one line per client, a verb and an
# optional argument, answered with one line. The host reads the line and
# carries out the command; which command a line is lives here
# (laws/control.bend).

type Cmd is Data:
  CPause{}
  CResume{}
  CStatus{}
  CQuit{}
  CNet{}
  CPowerdown{}
  CSnapshot{path: String}
  CScreendump{path: String}
  CType{text: String}
  CPointer{x: U32, y: U32}
  CPointerUsage{}
  CUnknown{}
  CBad{why: String}

def Ctl.usage() -> String:
  "unknown command (pause, resume, snapshot PATH, screendump PATH, type TEXT, pointer X Y, powerdown, net, status, quit)"

def Ctl.pointer_usage() -> String:
  "usage: pointer X Y (0..32767)"

# pointer X Y: two numbers on the tablet's 0..32767 scale.
def Ctl.pointer.mk(x: Maybe<&2, U32>, y: Maybe<&2, U32>) -> Cmd:
  match x y:
    case Some{+a} Some{+b}:
      Bool.pick(Cmd, U32.is_le(a, 32767) && U32.is_le(b, 32767), CPointer{a, b}, CPointerUsage{})
    case _ _:
      CPointerUsage{}

def Ctl.pointer(ws: List<&2, String>) -> Cmd:
  match ws:
    case Con{x, Con{y, Nil{}}}:
      Ctl.pointer.mk(U32.read(x), U32.read(y))
    case _:
      CPointerUsage{}

# A command that takes an argument, given none: its usage.
def Ctl.needs(+arg: String, c: Cmd, why: String) -> Cmd:
  Bool.pick(Cmd, String.is_empty(arg), CBad{why}, c)

def Ctl.verb(+verb: String, +arg: String) -> Cmd:
  Bool.pick(Cmd, String.eq(verb, "pause"), CPause{},
  Bool.pick(Cmd, String.eq(verb, "resume"), CResume{},
  Bool.pick(Cmd, String.eq(verb, "status"), CStatus{},
  Bool.pick(Cmd, String.eq(verb, "quit"), CQuit{},
  Bool.pick(Cmd, String.eq(verb, "net"), CNet{},
  Bool.pick(Cmd, String.eq(verb, "powerdown"), CPowerdown{},
  Bool.pick(Cmd, String.eq(verb, "snapshot"), Ctl.needs(arg, CSnapshot{arg}, "usage: snapshot PATH"),
  Bool.pick(Cmd, String.eq(verb, "screendump"), Ctl.needs(arg, CScreendump{arg}, "usage: screendump PATH"),
  Bool.pick(Cmd, String.eq(verb, "type"), Ctl.needs(arg, CType{arg}, "usage: type TEXT"),
  Bool.pick(Cmd, String.eq(verb, "pointer"), Ctl.pointer(String.split(arg, ' ')),
  CUnknown{}))))))))))

# One command line: its first word is the verb, the rest (one space between
# words) its argument.
def Ctl.parse(line: String) -> Cmd:
  +parts = String.split(String.trim(line), ' ')
  Ctl.verb(Maybe.default(&2, String, List.head(&2, String, parts), ""), String.join(List.drop(&2, String, parts, 1n), " "))

# Bytes as characters, one per byte (as host/fs.bend's Fs.chars).
def Ctl.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, rest}:
      SCon{Char.from_u32(b), Ctl.chars(rest)}

def Ctl.frame.got(+status: U32, +line: +List<U32>) -> Maybe<&2, Cmd>:
  Bool.pick(Maybe<&2, Cmd>, U32.is_eq(status, 0), Some{Ctl.parse(Ctl.chars(line))},
    Bool.pick(Maybe<&2, Cmd>, U32.is_eq(status, 1), Some{CBad{"line too long (at most 1024 bytes)"}}, None{}))

# What the host read from a control client (Hvf.ctl_next): [0, a line's
# bytes...] is a command (an empty line too: it gets the usage), [1, ...] a
# line cut short, anything else (no control socket) ends the service.
def Ctl.frame(bs: +List<U32>) -> Maybe<&2, Cmd>:
  match bs:
    case Nil{}:
      None{}
    case Con{status, line}:
      Ctl.frame.got(status, line)
