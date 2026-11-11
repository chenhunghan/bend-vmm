import Base

# bend-vmm's commands (laws/cmds.bend): the subcommands a user types, and a
# VM folder's configuration. Pure: which command a command line is, which
# options it has, and the VM options a folder's vm.conf makes (its paths
# relative to the folder). The host runs them (host/api.bend); options
# given straight (bend-vmm --kernel ...) are no subcommand and run as
# before.
#
#   bend-vmm create DIR [VM options]      a VM folder: DIR/vm.conf
#   bend-vmm run [DIR]                    run the folder's VM (here: .)
#   bend-vmm snapshot [NAME] [--note TEXT] [--vm DIR]
#   bend-vmm snapshots [--vm DIR]
#   bend-vmm restore NAME [--vm DIR]
#   bend-vmm snapshot-rm NAME [--vm DIR]
#   bend-vmm prune --keep N [--vm DIR]
#   bend-vmm status|pause|resume|stop|powerdown [--vm DIR]
#   bend-vmm ctl SOCKET COMMAND...        a raw control line (--control)

type Sub is Data:
  SubNone{}
  SubBad{why: String}
  SubCreate{dir: String, flags: List<&2, String>}
  SubRun{dir: String}
  SubSnap{vm: String, name: String, note: String}
  SubSnaps{vm: String}
  SubRestore{vm: String, name: String}
  SubRm{vm: String, name: String}
  SubPrune{vm: String, keep: U32}
  SubCtl{vm: String, line: String}
  SubRaw{sock: String, line: String}

def Sub.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, rest}:
      Con{x, Sub.l2(rest)}

def Sub.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      []
    case Con{x, rest}:
      Con{x, Sub.l1(rest)}

# An option's value (the last given), or the default.
def Sub.opt(args: List<&2, String>, +name: String, +dflt: String) -> String:
  match args:
    case Nil{}:
      dflt
    case Con{+a, rest}:
      match rest:
        case Nil{}:
          dflt
        case Con{+v, more}:
          Sub.opt(Con{v, more}, name, Bool.pick(String, String.eq(a, name), v, dflt))

# The words that are not an option or an option's value.
def Sub.pos.go(args: List<&2, String>, +skip: Bool) -> List<&2, String>:
  match args:
    case Nil{}:
      []
    case Con{+a, rest}:
      +opt = Bool.not(skip) && String.starts_with(a, "--")
      +next = Sub.pos.go(rest, opt)
      Bool.pick(List<&2, String>, skip || opt, next, Con{a, next})

def Sub.pos(args: List<&2, String>) -> List<&2, String>:
  Sub.pos.go(args, False{})

def Sub.first(+xs: List<&2, String>, +dflt: String) -> String:
  Maybe.default(&2, String, List.head(&2, String, xs), dflt)

def Sub.count(+xs: List<&2, String>) -> U32:
  U32.from_nat(List.length(&2, String, xs))

# A command that takes one NAME.
def Sub.named(+rest: List<&2, String>, +usage: String, +mk: U32) -> Sub:
  +p = Sub.pos(rest)
  +vm = Sub.opt(rest, "--vm", ".")
  +name = Sub.first(p, "")
  Bool.pick(Sub, String.is_empty(name), SubBad{usage},
    Bool.pick(Sub, U32.is_eq(mk, 0), SubRestore{vm, name}, SubRm{vm, name}))

def Sub.ctl_verb(+v: String) -> Bool:
  String.eq(v, "status") || String.eq(v, "pause") || String.eq(v, "resume") || String.eq(v, "stop") || String.eq(v, "powerdown")

# The control line a VM command sends (stop is quit).
def Sub.ctl_line(+v: String) -> String:
  Bool.pick(String, String.eq(v, "stop"), "quit", Bool.pick(String, String.eq(v, "status"), "status json", v))

def Sub.go(+cmd: String, +rest: List<&2, String>) -> Sub:
  +p = Sub.pos(rest)
  +vm = Sub.opt(rest, "--vm", ".")
  Bool.pick(Sub, String.eq(cmd, "create"),
    Bool.pick(Sub, String.is_empty(Sub.first(rest, "")) || String.starts_with(Sub.first(rest, ""), "--"), SubBad{"usage: bend-vmm create DIR [VM options]"},
      SubCreate{Sub.first(rest, ""), List.drop(&2, String, rest, 1n)}),
  Bool.pick(Sub, String.eq(cmd, "run"), SubRun{Sub.first(p, ".")},
  Bool.pick(Sub, String.eq(cmd, "snapshot"), SubSnap{vm, Sub.first(p, ""), Sub.opt(rest, "--note", "")},
  Bool.pick(Sub, String.eq(cmd, "snapshots"), SubSnaps{vm},
  Bool.pick(Sub, String.eq(cmd, "restore"), Sub.named(rest, "usage: bend-vmm restore NAME [--vm DIR]", 0),
  Bool.pick(Sub, String.eq(cmd, "snapshot-rm"), Sub.named(rest, "usage: bend-vmm snapshot-rm NAME [--vm DIR]", 1),
  Bool.pick(Sub, String.eq(cmd, "prune"),
    Bool.pick(Sub, U32.is_eq(Maybe.default(&2, U32, U32.read(Sub.opt(rest, "--keep", "x")), 4294967295), 4294967295),
      SubBad{"usage: bend-vmm prune --keep N [--vm DIR]"},
      SubPrune{vm, Maybe.default(&2, U32, U32.read(Sub.opt(rest, "--keep", "0")), 0)}),
  Bool.pick(Sub, Sub.ctl_verb(cmd), SubCtl{vm, Sub.ctl_line(cmd)},
  Bool.pick(Sub, String.eq(cmd, "ctl"),
    Bool.pick(Sub, U32.is_lt(Sub.count(rest), 2), SubBad{"usage: bend-vmm ctl SOCKET COMMAND..."},
      SubRaw{Sub.first(rest, ""), String.join(List.drop(&2, String, rest, 1n), " ")}),
    SubBad{"unknown command " ++ cmd ++ " (bend-vmm --help)"})))))))))

# Which command a command line is: options first (or none) is no
# subcommand.
def Sub.parse(+args: List<&2, String>) -> Sub:
  match args:
    case Nil{}:
      SubNone{}
    case Con{+cmd, rest}:
      Bool.pick(Sub, String.starts_with(cmd, "-"), SubNone{}, Sub.go(cmd, rest))

# A VM folder's configuration
# ===========================
#
# DIR/vm.conf: one option per line, as on the command line ("--mem 1024",
# "--disk disk.img,data.img:ro", "--cmdline console=ttyAMA0 quiet": the
# rest of the line is the value; surrounding double quotes are dropped).
# Empty lines and lines starting with # are skipped. A relative path is
# the folder's: kernel, initrd, payload, vsock, firmware, vars, each disk,
# and the first part of share, console-log and lan.

def Conf.path(+dir: String, +p: String) -> String:
  Bool.pick(String, String.is_empty(p) || String.starts_with(p, "/"), p, dir ++ "/" ++ p)

def Conf.disk1(+dir: String, +spec: String) -> String:
  Bool.pick(String, String.ends_with(spec, ":ro"),
    Conf.path(dir, String.take(spec, Nat.sub(String.length(spec), 3n))) ++ ":ro", Conf.path(dir, spec))

def Conf.disks(+dir: String, specs: List<&2, String>) -> List<&2, String>:
  match specs:
    case Nil{}:
      []
    case Con{s, rest}:
      Con{Conf.disk1(dir, s), Conf.disks(dir, rest)}

# The first comma-separated part is a path; the rest stays.
def Conf.head_path(+dir: String, +v: String) -> String:
  +parts = String.split(v, ',')
  String.join(Con{Conf.path(dir, Sub.first(parts, "")), List.drop(&2, String, parts, 1n)}, ",")

def Conf.value(+dir: String, +flag: String, +v: String) -> String:
  Bool.pick(String, String.eq(flag, "--kernel") || String.eq(flag, "--initrd") || String.eq(flag, "--payload")
      || String.eq(flag, "--vsock") || String.eq(flag, "--firmware") || String.eq(flag, "--vars") || String.eq(flag, "--control"),
    Conf.path(dir, v),
  Bool.pick(String, String.eq(flag, "--disk"), String.join(Conf.disks(dir, String.split(v, ',')), ","),
  Bool.pick(String, String.eq(flag, "--share") || String.eq(flag, "--console-log") || String.eq(flag, "--lan"),
    Conf.head_path(dir, v), v)))

def Conf.unquote(+v: String) -> String:
  +n = String.length(v)
  Bool.pick(String, Nat.is_le(2n, n) && String.starts_with(v, "\"") && String.ends_with(v, "\""),
    String.take(String.drop(v, 1n), Nat.sub(n, 2n)), v)

# One line's option and value, appended to the flags.
def Conf.line(+dir: String, +l: String, +acc: List<&2, String>) -> List<&2, String>:
  +t = String.trim(l)
  +ws = String.split(t, ' ')
  +flag = Sub.first(ws, "")
  +v = Conf.unquote(String.trim(String.join(List.drop(&2, String, ws, 1n), " ")))
  Bool.pick(List<&2, String>, String.is_empty(t) || String.starts_with(t, "#"), acc,
    List.append(&2, String, acc, [flag, Conf.value(dir, flag, v)]))

def Conf.lines(ls: List<&2, String>, +dir: String, +acc: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      acc
    case Con{l, rest}:
      Conf.lines(rest, dir, Conf.line(dir, l, acc))

# The VM options a folder's vm.conf makes.
def Conf.flags(+dir: String, +text: String) -> List<&2, String>:
  Conf.lines(String.split(text, '\n'), dir, [])

# vm.conf for bend-vmm create: one option per line, as given.
def Conf.text(flags: List<&2, String>) -> String:
  match flags:
    case Nil{}:
      ""
    case Con{f, rest}:
      match rest:
        case Nil{}:
          f ++ "\n"
        case Con{v, more}:
          f ++ " " ++ v ++ "\n" ++ Conf.text(more)

# The options a restore of a folder's VM takes from vm.conf: the host files
# and sockets it names (Restore.differs checks them against the snapshot's),
# and this run's forwards; the rest is the snapshot's.
def Conf.restore_flag(+f: String) -> Bool:
  String.eq(f, "--disk") || String.eq(f, "--share") || String.eq(f, "--vsock") || String.eq(f, "--firmware")
    || String.eq(f, "--vars") || String.eq(f, "--lan") || String.eq(f, "--forward") || String.eq(f, "--console-log")

def Conf.for_restore(flags: List<&2, String>) -> List<&2, String>:
  match flags:
    case Nil{}:
      []
    case Con{+f, rest}:
      match rest:
        case Nil{}:
          []
        case Con{v, more}:
          +next = Conf.for_restore(more)
          Bool.pick(List<&2, String>, Conf.restore_flag(f), Con{f, Con{v, next}}, next)
