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

def Ctl.verb(+verb: String, +arg: String) -> Cmd:
  Bool.pick(Cmd, String.eq(verb, "pause"), CPause{},
  Bool.pick(Cmd, String.eq(verb, "resume"), CResume{},
  Bool.pick(Cmd, String.eq(verb, "status"), CStatus{},
  Bool.pick(Cmd, String.eq(verb, "quit"), CQuit{},
  Bool.pick(Cmd, String.eq(verb, "net"), CNet{},
  Bool.pick(Cmd, String.eq(verb, "powerdown"), CPowerdown{},
  Bool.pick(Cmd, String.eq(verb, "snapshot"), CSnapshot{arg},
  Bool.pick(Cmd, String.eq(verb, "screendump"), CScreendump{arg},
  Bool.pick(Cmd, String.eq(verb, "type"), CType{arg},
  Bool.pick(Cmd, String.eq(verb, "pointer"), Ctl.pointer(String.split(arg, ' ')),
  CUnknown{}))))))))))

# One command line: its first word is the verb, the rest (one space between
# words) its argument.
def Ctl.parse(line: String) -> Cmd:
  +parts = String.split(String.trim(line), ' ')
  Ctl.verb(Maybe.default(&2, String, List.head(&2, String, parts), ""), String.join(List.drop(&2, String, parts, 1n), " "))
