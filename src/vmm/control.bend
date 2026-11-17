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
  CStatusJson{}
  # balloon MiB: the balloon's target (--balloon free-page-reporting).
  CBalloon{mib: U32}
  # balloon auto: the automatic balloon takes over again (the default;
  # balloon MiB sets a target by hand and stops it).
  CBalloonAuto{}

def Ctl.usage() -> String:
  "unknown command (pause, resume, snapshot PATH, screendump PATH, type TEXT, pointer X Y, powerdown, net, status [json], balloon MiB|auto, quit)"

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

# balloon MiB: the memory the guest is asked to give to the balloon, 0 to
# 1048576 MiB (0: give it all back).
def Ctl.balloon_usage() -> String:
  "usage: balloon MiB (0 to 1048576)"

def Ctl.balloon(m: Maybe<&2, U32>) -> Cmd:
  match m:
    case Some{+n}:
      Bool.pick(Cmd, U32.is_le(n, 1048576), CBalloon{n}, CBad{Ctl.balloon_usage()})
    case None{}:
      CBad{Ctl.balloon_usage()}

# MiB as 4 KiB pages, and back (rounded down).
def Ctl.mib_pages(+mib: U32) -> U32:
  (mib * 256 : U32)

def Ctl.pages_mib(+pages: U32) -> U32:
  (pages / 256 : U32)

# The balloon's reply: its target and how much is in it now, in MiB.
def Ctl.balloon_reply(+target: U32, +actual: U32) -> String:
  "balloon " ++ U32.show(Ctl.pages_mib(target)) ++ " MiB (in it now: " ++ U32.show(Ctl.pages_mib(actual)) ++ " MiB)"

def Ctl.no_balloon() -> String:
  "error: no balloon (the VM was started with --balloon off)"

# status json with a balloon: the state, then the balloon's target and
# what is in it, in MiB (without one, Ctl.status_json).
def Ctl.status_json_balloon(paused: Bool, +target: U32, +actual: U32) -> String:
  "{\"state\":\"" ++ Bool.pick(String, paused, "paused", "running") ++ "\",\"balloon\":{\"target_mib\":" ++ U32.show(Ctl.pages_mib(target)) ++ ",\"actual_mib\":" ++ U32.show(Ctl.pages_mib(actual)) ++ "}}"

# status json with a balloon and what of it the host still holds: kept_mib
# is the memory in the balloon the host could not release (pages of 16 KiB
# blocks the balloon holds only part of).
def Ctl.status_json_kept(paused: Bool, +target: U32, +actual: U32, +kept: U32) -> String:
  "{\"state\":\"" ++ Bool.pick(String, paused, "paused", "running") ++ "\",\"balloon\":{\"target_mib\":" ++ U32.show(Ctl.pages_mib(target)) ++ ",\"actual_mib\":" ++ U32.show(Ctl.pages_mib(actual)) ++ ",\"kept_mib\":" ++ U32.show(Ctl.pages_mib(kept)) ++ "}}"

# status json's guest RAM: what of it the host holds, resident and (macOS)
# compressed, in MiB from KiB; spliced before the object's closing brace.
def Ctl.ram_json(+resident_kib: U32, +compressed_kib: U32) -> String:
  ",\"ram\":{\"resident_mib\":" ++ U32.show((resident_kib / 1024 : U32)) ++ ",\"compressed_mib\":" ++ U32.show((compressed_kib / 1024 : U32)) ++ "}}"

def Ctl.with_ram(+json: String, +resident_kib: U32, +compressed_kib: U32) -> String:
  String.take(json, Nat.sub(String.length(json), 1n)) ++ Ctl.ram_json(resident_kib, compressed_kib)

# An exit bucket's name (host/hvf.c's hvf_exit_bucket): 0..63 an
# exception's class on Hypervisor.framework, 64 a vtimer, 65 canceled (a
# kick), 66 + a KVM exit reason, 127 anything else.
def Ctl.exit_name(+b: U32) -> String:
  Bool.pick(String, U32.is_eq(b, 1), "wfi",
  Bool.pick(String, U32.is_eq(b, 22), "hvc",
  Bool.pick(String, U32.is_eq(b, 23), "smc",
  Bool.pick(String, U32.is_eq(b, 24), "sysreg",
  Bool.pick(String, U32.is_eq(b, 36), "mmio",
  Bool.pick(String, U32.is_eq(b, 64), "vtimer",
  Bool.pick(String, U32.is_eq(b, 65), "canceled",
  Bool.pick(String, U32.is_eq(b, 68), "io",
  Bool.pick(String, U32.is_eq(b, 69), "hypercall",
  Bool.pick(String, U32.is_eq(b, 71), "hlt",
  Bool.pick(String, U32.is_eq(b, 72), "mmio",
  Bool.pick(String, U32.is_eq(b, 74), "shutdown",
  Bool.pick(String, U32.is_eq(b, 90), "system_event",
  Bool.pick(String, U32.is_lt(b, 64), "ec_" ++ U32.show(b),
  Bool.pick(String, U32.is_lt(b, 127), "kvm_" ++ U32.show((b - 66 : U32)), "other")))))))))))))))

# Hvf.exit_counts' words ([cpu, n, n pairs of (bucket, count)] per vCPU)
# as JSON: each vCPU opens with "},{" (Ctl.exits_json trims the first).
def Ctl.exits_go(ws: +List<U32>, left: Nat) -> String:
  match ws left:
    case Con{cpu, Con{n, rest}} 0n:
      "},{\"cpu\":" ++ U32.show(cpu) ++ Ctl.exits_go(rest, U32.to_nat(n))
    case Con{b, Con{k, rest}} 1n+p:
      ",\"" ++ Ctl.exit_name(b) ++ "\":" ++ U32.show(k) ++ Ctl.exits_go(rest, p)
    case _ _:
      ""

def Ctl.exits_json(ws: +List<U32>) -> String:
  +body : String = Ctl.exits_go(ws, 0n)
  Bool.pick(String, String.is_empty(body), "[]", "[" ++ String.drop(body, 2n) ++ "}]")

# status json's exits by vCPU, spliced before the object's closing brace.
def Ctl.with_exits(+json: String, ws: +List<U32>) -> String:
  String.take(json, Nat.sub(String.length(json), 1n)) ++ ",\"exits\":" ++ Ctl.exits_json(ws) ++ "}"

# A command that takes an argument, given none: its usage.
def Ctl.needs(+arg: String, c: Cmd, why: String) -> Cmd:
  Bool.pick(Cmd, String.is_empty(arg), CBad{why}, c)

# status json: the VM's state as one JSON object, for programs.
def Ctl.status_json(paused: Bool) -> String:
  "{\"state\":\"" ++ Bool.pick(String, paused, "paused", "running") ++ "\"}"

def Ctl.verb(+verb: String, +arg: String) -> Cmd:
  Bool.pick(Cmd, String.eq(verb, "pause"), CPause{},
  Bool.pick(Cmd, String.eq(verb, "resume"), CResume{},
  Bool.pick(Cmd, String.eq(verb, "status"), Bool.pick(Cmd, String.eq(arg, "json"), CStatusJson{}, CStatus{}),
  Bool.pick(Cmd, String.eq(verb, "quit"), CQuit{},
  Bool.pick(Cmd, String.eq(verb, "net"), CNet{},
  Bool.pick(Cmd, String.eq(verb, "powerdown"), CPowerdown{},
  Bool.pick(Cmd, String.eq(verb, "snapshot"), Ctl.needs(arg, CSnapshot{arg}, "usage: snapshot PATH"),
  Bool.pick(Cmd, String.eq(verb, "screendump"), Ctl.needs(arg, CScreendump{arg}, "usage: screendump PATH"),
  Bool.pick(Cmd, String.eq(verb, "type"), Ctl.needs(arg, CType{arg}, "usage: type TEXT"),
  Bool.pick(Cmd, String.eq(verb, "pointer"), Ctl.pointer(String.split(arg, ' ')),
  Bool.pick(Cmd, String.eq(verb, "balloon"), Bool.pick(Cmd, String.eq(arg, "auto"), CBalloonAuto{}, Ctl.balloon(U32.read(arg))),
  CUnknown{})))))))))))

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
