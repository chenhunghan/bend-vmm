import Base
import ./hvf.bend as H
import ../src/vmm/snapdir.bend as Sd
import ../src/vmm/cmds.bend as Cm
import ../src/vmm/disksnap.bend as Ds
import ../src/vmm/opts.bend as Op
import ../src/vmm/hostfiles.bend as Hf
import ../src/vmm/cli.bend as Cli
import ../src/lib/u64.bend as U

# bend-vmm as a library: typed calls on a VM from another process (this
# one runs no VM). A VM is named by its folder (bend-vmm create; its
# control socket is DIR/control.sock) or by its --control socket path. The
# decisions are src/vmm/{snapdir,cmds,disksnap}.bend's; here they are
# carried out. Nothing here prints or ends the process: every call answers
# a Result. Vmm.run_dir and Vmm.restore (host/main.bend) run a VM.

# Why a call failed. ENoSocket: no socket there (a folder: no VM ever ran);
# ENotRunning: a socket nobody answers on (the VM stopped); ETimeout: no
# reply in time; EBadName, EExists, ENoSnapshot: snapshot names; ENoVm: not
# a VM folder; EFailed: the VM answered an error, or the host failed.
type Err is Data:
  ENoSocket{}
  ENotRunning{}
  ETimeout{}
  EBadName{name: String}
  EExists{name: String}
  ENoSnapshot{name: String}
  ENoVm{path: String}
  EFailed{why: String}

def Err.text(e: Err) -> String:
  match e:
    case ENoSocket{}:
      "no control socket there (is the VM running?)"
    case ENotRunning{}:
      "the VM is not running"
    case ETimeout{}:
      "the VM did not answer in time"
    case EBadName{n}:
      "bad snapshot name " ++ n ++ " (1-64 of A-Z a-z 0-9 . _ -, not starting with .)"
    case EExists{n}:
      "a snapshot " ++ n ++ " exists already"
    case ENoSnapshot{n}:
      "no snapshot " ++ n
    case ENoVm{p}:
      p ++ " is not a VM folder (no vm.conf; bend-vmm create makes one)"
    case EFailed{w}:
      w

# A VM's state: running, paused or stopped, and its forwards (vm.conf's
# --forward; "" for a socket).
type Status is Data:
  Status{state: String, forwards: String}

# A VM as a call reaches it: its control socket, and its folder ("" when
# named by its socket).
type Vm is Data:
  Vm{sock: String, dir: String}

def Api.fail(-A: Type, e: Err) -> IO(Result<&1, &1, Err, A>):
  IO.pure(Result<&1, &1, Err, A>, Fail{e})

def Api.done(-A: Type, x: A) -> IO(Result<&1, &1, Err, A>):
  IO.pure(Result<&1, &1, Err, A>, Done{x})

def Api.vm.of(+path: String, +ws: +List<U32>) -> Vm:
  Bool.pick(Vm, U32.is_eq(H.Host.first(ws), 1), Vm{path, ""}, Vm{path ++ "/control.sock", path})

# A socket path is the VM's socket; anything else its folder.
def Api.vm(+path: String) -> IO(Vm):
  do IO<Vm>:
    +ws : +List<U32> <- H.Hvf.sock_facts(path)
    return Api.vm.of(path, ws)

def Api.sock(v: Vm) -> String:
  match v:
    case Vm{s, d}:
      s

def Api.dir(v: Vm) -> String:
  match v:
    case Vm{s, d}:
      d

# Text files (vm.conf, a snapshot's info): "" when missing.
def Api.read.got(got: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  match got:
    case (f, Done{s}):
      do IO<String>:
        File.close(f)
        return s
    case (f, Fail{e}):
      do IO<String>:
        File.close(f)
        return ""

def Api.read.opened(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, "")
    case Done{f}:
      do IO<String>:
        got : File & Result<&1, &1, U32 & String, String> <- File.read(f, 1048576)
        Api.read.got(got)

def Api.read(path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    Api.read.opened(r)

def Api.write.got(got: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  match got:
    case (f, Done{u}):
      do IO<Bool>:
        File.close(f)
        return True{}
    case (f, Fail{e}):
      do IO<Bool>:
        File.close(f)
        return False{}

def Api.write.opened(r: Result<&1, &1, U32 & String, File>, +text: String) -> IO(Bool):
  match r:
    case Fail{e}:
      IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        got : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, text)
        Api.write.got(got)

def Api.write(path: String, +text: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    Api.write.opened(r, text)

def Api.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, rest}:
      SCon{Char.from_u32(b), Api.chars(rest)}

# The VM's answer to one control line. ENOENT (2): no socket; any other
# connect error (ECONNREFUSED): a socket nobody answers on.
def Api.reply(+ws: +List<U32>) -> Result<&1, &1, Err, String>:
  +tag = H.Host.first(ws)
  +rest = List.drop(&2, U32, ws, 1n)
  +text = Api.chars(rest)
  Bool.pick(Result<&1, &1, Err, String>, U32.is_eq(tag, 2), Fail{ETimeout{}},
    Bool.pick(Result<&1, &1, Err, String>, U32.is_eq(tag, 1),
      Fail{Bool.pick(Err, U32.is_eq(H.Host.first(rest), 2), ENoSocket{}, ENotRunning{})},
      Bool.pick(Result<&1, &1, Err, String>, String.starts_with(text, "error"), Fail{EFailed{"the VM answered: " ++ text}}, Done{text})))

def Api.call.at(+sock: String, +line: String, +ms: U32) -> IO(Result<&1, &1, Err, String>):
  do IO<Result<&1, &1, Err, String>>:
    +ws : +List<U32> <- H.Hvf.ctl_call(sock, line, ms)
    return Api.reply(ws)

# One control line to a VM (its folder or socket), its reply.
def Vmm.ctl(+vm: String, +line: String) -> IO(Result<&1, &1, Err, String>):
  do IO<Result<&1, &1, Err, String>>:
    +v : Vm <- Api.vm(vm)
    Api.call.at(Api.sock(v), line, 30000)

def Vmm.pause(+vm: String) -> IO(Result<&1, &1, Err, String>):
  Vmm.ctl(vm, "pause")

def Vmm.resume(+vm: String) -> IO(Result<&1, &1, Err, String>):
  Vmm.ctl(vm, "resume")

# stop ends the VM at once (quit); powerdown asks the guest to shut down.
def Vmm.stop(+vm: String) -> IO(Result<&1, &1, Err, String>):
  Vmm.ctl(vm, "quit")

def Vmm.powerdown(+vm: String) -> IO(Result<&1, &1, Err, String>):
  Vmm.ctl(vm, "powerdown")

# The folder's VM options (vm.conf, paths made the folder's).
def Api.conf(+dir: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +text : String <- Api.read(dir ++ "/vm.conf")
    return Cm.Conf.flags(dir, text)

def Api.status.of(r: Result<&1, &1, Err, String>, +fw: String) -> Result<&1, &1, Err, Status>:
  match r:
    case Done{+t}:
      Done{Status{Bool.pick(String, String.ends_with(t, "\"paused\"}"), "paused", "running"), fw}}
    case Fail{e}:
      match e:
        case ENoSocket{}:
          Done{Status{"stopped", fw}}
        case ENotRunning{}:
          Done{Status{"stopped", fw}}
        case ETimeout{}:
          Fail{ETimeout{}}
        case EBadName{n}:
          Fail{EBadName{n}}
        case EExists{n}:
          Fail{EExists{n}}
        case ENoSnapshot{n}:
          Fail{ENoSnapshot{n}}
        case ENoVm{p}:
          Fail{ENoVm{p}}
        case EFailed{w}:
          Fail{EFailed{w}}

# running, paused or stopped (a VM that is not running is stopped, not an
# error), with its forwards.
def Vmm.status(+vm: String) -> IO(Result<&1, &1, Err, Status>):
  do IO<Result<&1, &1, Err, Status>>:
    +v : Vm <- Api.vm(vm)
    +d : String = Api.dir(v)
    +flags : List<&2, String> <- Bool.pick(IO(List<&2, String>), String.is_empty(d), IO.pure(List<&2, String>, []), Api.conf(d))
    r : Result<&1, &1, Err, String> <- Api.call.at(Api.sock(v), "status json", 30000)
    return Api.status.of(r, Cm.Sub.opt(flags, "--forward", ""))

# Snapshots
# =========

def Api.names(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{+x, rest}:
      +more : List<&2, String> = Api.names(rest)
      Bool.pick(List<&2, String>, String.starts_with(x, "."), more, Con{x, more})

def Api.has(xs: List<&2, String>, +n: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      String.eq(x, n) || Api.has(rest, n)

# A folder and everything in it (snapshot folders hold only files).
def Api.rm_files(xs: List<String>, +dir: String) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{x, rest}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.remove(dir ++ "/" ++ x)
        Api.rm_files(rest, dir)

def Api.rm_dir(+dir: String) -> IO(U32):
  do IO<U32>:
    xs : List<String> <- H.Hvf.ls(dir)
    Api.rm_files(xs, dir)
    H.Hvf.rmdir(dir)

def Api.infos(ns: List<&2, String>, +dir: String) -> IO(List<&2, Sd.Info>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, Sd.Info>, [])
    case Con{n, rest}:
      do IO<List<&2, Sd.Info>>:
        +text : String <- Api.read(Sd.Sdir.info(Sd.Sdir.dir(dir, n)))
        more : List<&2, Sd.Info> <- Api.infos(rest, dir)
        return Con{Sd.Sdir.info.parse(text), more}

def Api.no_dir() -> Err:
  EFailed{"snapshots need a VM folder (for a socket: bend-vmm ctl SOCKET snapshot PATH)"}

# The VM's snapshots, oldest first.
def Api.snapshots.in(none: Bool, +d: String) -> IO(Result<&1, &1, Err, List<&2, Sd.Info>>):
  match none:
    case True{}:
      Api.fail(List<&2, Sd.Info>, Api.no_dir())
    case False{}:
      do IO<Result<&1, &1, Err, List<&2, Sd.Info>>>:
        xs : List<String> <- H.Hvf.ls(Sd.Sdir.root(d))
        infos : List<&2, Sd.Info> <- Api.infos(Api.names(xs), d)
        return Done{Sd.Sdir.sorted(infos, [])}

def Vmm.snapshots(+vm: String) -> IO(Result<&1, &1, Err, List<&2, Sd.Info>>):
  do IO<Result<&1, &1, Err, List<&2, Sd.Info>>>:
    +v : Vm <- Api.vm(vm)
    Api.snapshots.in(String.is_empty(Api.dir(v)), Api.dir(v))

def Api.rm.go(ok: Bool, +d: String, +name: String) -> IO(Result<&1, &1, Err, String>):
  match ok:
    case False{}:
      Api.fail(String, ENoSnapshot{name})
    case True{}:
      do IO<Result<&1, &1, Err, String>>:
        +rc : U32 <- Api.rm_dir(Sd.Sdir.dir(d, name))
        return Bool.pick(Result<&1, &1, Err, String>, U32.is_eq(rc, 0), Done{name}, Fail{EFailed{"cannot remove " ++ Sd.Sdir.dir(d, name) ++ " (" ++ U32.show(rc) ++ ")"}})

def Api.rm.in(none: Bool, +d: String, +name: String) -> IO(Result<&1, &1, Err, String>):
  match none:
    case True{}:
      Api.fail(String, Api.no_dir())
    case False{}:
      do IO<Result<&1, &1, Err, String>>:
        xs : List<String> <- H.Hvf.ls(Sd.Sdir.root(d))
        Api.rm.go(Sd.Sname.valid(name) && Api.has(Api.names(xs), name), d, name)

def Vmm.snapshot_rm(+vm: String, +name: String) -> IO(Result<&1, &1, Err, String>):
  do IO<Result<&1, &1, Err, String>>:
    +v : Vm <- Api.vm(vm)
    Api.rm.in(String.is_empty(Api.dir(v)), Api.dir(v), name)

def Api.prune.go(ns: List<&2, String>, +d: String) -> IO(List<&2, String>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, String>, [])
    case Con{+n, rest}:
      do IO<List<&2, String>>:
        _ : U32 <- Api.rm_dir(Sd.Sdir.dir(d, n))
        more : List<&2, String> <- Api.prune.go(rest, d)
        return Con{n, more}

# prune --keep N: removes the oldest past the newest N; their names.
def Api.prune.in(none: Bool, +d: String, +keep: U32) -> IO(Result<&1, &1, Err, List<&2, String>>):
  match none:
    case True{}:
      Api.fail(List<&2, String>, Api.no_dir())
    case False{}:
      do IO<Result<&1, &1, Err, List<&2, String>>>:
        xs : List<String> <- H.Hvf.ls(Sd.Sdir.root(d))
        infos : List<&2, Sd.Info> <- Api.infos(Api.names(xs), d)
        gone : List<&2, String> <- Api.prune.go(Sd.Sdir.prune(infos, keep), d)
        return Done{gone}

def Vmm.prune(+vm: String, +keep: U32) -> IO(Result<&1, &1, Err, List<&2, String>>):
  do IO<Result<&1, &1, Err, List<&2, String>>>:
    +v : Vm <- Api.vm(vm)
    Api.prune.in(String.is_empty(Api.dir(v)), Api.dir(v), keep)

# disksnap's steps, in order, until one fails (0, or its errno).
def Api.step(s: Ds.Step) -> IO(U32):
  match s:
    case Ds.DClone{from, to}:
      H.Hvf.clone(from, to, Bool.to_u32(Ds.Dsnap.copy_fallback()))
    case Ds.DRename{from, to}:
      H.Hvf.rename(from, to)
    case Ds.DRemove{p}:
      do IO<U32>:
        _ : U32 <- H.Hvf.remove(p)
        return 0

def Api.steps(ss: List<Ds.Step>, +rc: U32) -> IO(U32):
  match ss:
    case Nil{}:
      IO.pure(U32, rc)
    case Con{s, rest}:
      do IO<U32>:
        +r : U32 <- Bool.pick(IO(U32), U32.is_eq(rc, 0), Api.step(s), IO.pure(U32, rc))
        Api.steps(rest, r)

# The disks of a stopped VM copied into a snapshot folder (its memory is not
# running anywhere: a snapshot of a stopped VM is its disks).
def Api.copy_disks(+tmp: String, +d: String) -> IO(U32):
  do IO<U32>:
    +flags : List<&2, String> <- Api.conf(d)
    +rc : U32 <- Api.steps(Ds.Dsnap.save(tmp ++ "/memory", Ds.Dsnap.folder_gen(), Ds.Dsnap.writable(Cm.Sub.opt(flags, "--disk", ""))), 0)
    Api.steps(Ds.Dsnap.place(tmp ++ "/memory", Ds.Dsnap.folder_gen(), Ds.Dsnap.writable(Cm.Sub.opt(flags, "--disk", ""))), rc)

def Api.stopped(e: Err) -> Bool:
  match e:
    case ENoSocket{}:
      True{}
    case ENotRunning{}:
      True{}
    case _:
      False{}

def Api.disk_kib(xs: List<String>, +dir: String) -> IO(U32):
  match xs:
    case Nil{}:
      IO.pure(U32, 0)
    case Con{+x, rest}:
      do IO<U32>:
        +k : U32 <- Bool.pick(IO(U32), String.starts_with(x, "disk"), H.Hvf.size_kib(dir ++ "/" ++ x), IO.pure(U32, 0))
        +more : U32 <- Api.disk_kib(rest, dir)
        return (k + more : U32)

def Api.snap.renamed(+rc: U32, +info: Sd.Info, +dst: String) -> Result<&1, &1, Err, Sd.Info>:
  Bool.pick(Result<&1, &1, Err, Sd.Info>, U32.is_eq(rc, 0), Done{info}, Fail{EFailed{"cannot place " ++ dst ++ " (" ++ U32.show(rc) ++ ")"}})

# A snapshot folder written whole: its info, then renamed into place; the
# VM's current snapshot (the next one's parent) is now this one.
def Api.snap.place(ok: Bool, +rc: U32, +d: String, +name: String, +note: String, +t: U32, +tmp: String) -> IO(Result<&1, &1, Err, Sd.Info>):
  match ok:
    case False{}:
      do IO<Result<&1, &1, Err, Sd.Info>>:
        _ : U32 <- Api.rm_dir(tmp)
        return Fail{EFailed{"cannot copy the disks (" ++ U32.show(rc) ++ ")"}}
    case True{}:
      do IO<Result<&1, &1, Err, Sd.Info>>:
        +parent : String <- Api.read(Sd.Sdir.root(d) ++ "/.current")
        +mem : U32 <- H.Hvf.size_kib(tmp ++ "/memory")
        xs : List<String> <- H.Hvf.ls(tmp)
        +dk : U32 <- Api.disk_kib(xs, tmp)
        +info : Sd.Info = Sd.Info{name, t, String.trim(parent), mem, dk, note}
        _ : Bool <- Api.write(Sd.Sdir.info(tmp), Sd.Sdir.info.text(info))
        +dst : String = Sd.Sdir.dir(d, name)
        +r : U32 <- H.Hvf.rename(tmp, dst)
        _ : Bool <- Bool.pick(IO(Bool), U32.is_eq(r, 0), Api.write(Sd.Sdir.root(d) ++ "/.current", name), IO.pure(Bool, False{}))
        return Api.snap.renamed(r, info, dst)

# The VM's answer to `snapshot TMP/`; a VM that is not running has its
# disks copied instead.
def Api.snap.failed(stopped: Bool, +e: Err, +d: String, +name: String, +note: String, +t: U32, +tmp: String) -> IO(Result<&1, &1, Err, Sd.Info>):
  match stopped:
    case True{}:
      do IO<Result<&1, &1, Err, Sd.Info>>:
        +rc : U32 <- Api.copy_disks(tmp, d)
        Api.snap.place(U32.is_eq(rc, 0), rc, d, name, note, t, tmp)
    case False{}:
      do IO<Result<&1, &1, Err, Sd.Info>>:
        _ : U32 <- Api.rm_dir(tmp)
        return Fail{e}

def Api.snap.after(r: Result<&1, &1, Err, String>, +d: String, +name: String, +note: String, +t: U32, +tmp: String) -> IO(Result<&1, &1, Err, Sd.Info>):
  match r:
    case Done{x}:
      Api.snap.place(True{}, 0, d, name, note, t, tmp)
    case Fail{+e}:
      Api.snap.failed(Api.stopped(e), e, d, name, note, t, tmp)

def Api.snap.take(+d: String, +name: String, +note: String, +t: U32) -> IO(Result<&1, &1, Err, Sd.Info>):
  do IO<Result<&1, &1, Err, Sd.Info>>:
    _ : U32 <- H.Hvf.mkdir(Sd.Sdir.root(d), Hf.Files.private_dir())
    +tmp : String = Sd.Sdir.tmp(d, name)
    _ : U32 <- Api.rm_dir(tmp)
    _ : U32 <- H.Hvf.mkdir(tmp, Hf.Files.private_dir())
    r : Result<&1, &1, Err, String> <- Api.call.at(d ++ "/control.sock", "snapshot " ++ tmp ++ "/", 3600000)
    Api.snap.after(r, d, name, note, t, tmp)

def Api.snap.check(valid: Bool, exists: Bool, +d: String, +name: String, +note: String, +t: U32) -> IO(Result<&1, &1, Err, Sd.Info>):
  match valid exists:
    case False{} _:
      Api.fail(Sd.Info, EBadName{name})
    case True{} True{}:
      Api.fail(Sd.Info, EExists{name})
    case True{} False{}:
      Api.snap.take(d, name, note, t)

# A snapshot of the VM in its folder: name "" takes the time's
# (Sname.of_time). A running VM keeps its memory and disks; a stopped one
# its disks. Answers what was saved.
def Api.snap.in(none: Bool, +d: String, +base: String, +gen: Bool, +note: String, +t: U32) -> IO(Result<&1, &1, Err, Sd.Info>):
  match none:
    case True{}:
      Api.fail(Sd.Info, Api.no_dir())
    case False{}:
      do IO<Result<&1, &1, Err, Sd.Info>>:
        xs : List<String> <- H.Hvf.ls(Sd.Sdir.root(d))
        +names : List<&2, String> = Api.names(xs)
        +name : String = Bool.pick(String, gen, Sd.Sname.unique(base, names), base)
        Api.snap.check(Sd.Sname.valid(name), Api.has(names, name), d, name, note, t)

# A snapshot of the VM in its folder: name "" takes the time's
# (Sname.of_time; with -2, -3 ... when taken). A running VM keeps its
# memory and disks; a stopped one its disks. Answers what was saved.
def Vmm.snapshot(+vm: String, +name0: String, +note: String) -> IO(Result<&1, &1, Err, Sd.Info>):
  do IO<Result<&1, &1, Err, Sd.Info>>:
    +v : Vm <- Api.vm(vm)
    +now : U.U64 <- H.Host.now()
    +t : U32 = U.U64.lo(now)
    +gen : Bool = String.is_empty(name0)
    Api.snap.in(String.is_empty(Api.dir(v)), Api.dir(v), Bool.pick(String, gen, Sd.Sname.of_time(t), name0), gen, note, t)

# The snapshot a restore takes first (Sname.undo, unique).
def Vmm.snapshot_undo(+vm: String, +note: String) -> IO(Result<&1, &1, Err, Sd.Info>):
  do IO<Result<&1, &1, Err, Sd.Info>>:
    +v : Vm <- Api.vm(vm)
    +now : U.U64 <- H.Host.now()
    +t : U32 = U.U64.lo(now)
    Api.snap.in(String.is_empty(Api.dir(v)), Api.dir(v), Sd.Sname.undo(t), True{}, note, t)

# A VM folder: DIR/vm.conf with these options (checked as the command line
# would be); refused when DIR has one already.
def Api.create.go(+why: String, there: Bool, +dir: String, +text: String) -> IO(Result<&1, &1, Err, String>):
  match there:
    case True{}:
      Api.fail(String, EFailed{dir ++ " has a vm.conf already"})
    case False{}:
      Bool.pick(IO(Result<&1, &1, Err, String>), Bool.not(String.is_empty(why)), Api.fail(String, EFailed{why}),
        IO.bind(U32, Result<&1, &1, Err, String>, H.Hvf.mkdir(dir, Hf.Files.private_dir()), rc =>
          IO.bind(Bool, Result<&1, &1, Err, String>, Api.write(dir ++ "/vm.conf", text), ok =>
            IO.pure(Result<&1, &1, Err, String>, Bool.pick(Result<&1, &1, Err, String>, ok, Done{dir ++ "/vm.conf"}, Fail{EFailed{"cannot write " ++ dir ++ "/vm.conf"}})))))

def Vmm.create(+dir: String, +flags: List<&2, String>) -> IO(Result<&1, &1, Err, String>):
  do IO<Result<&1, &1, Err, String>>:
    +old : String <- Api.read(dir ++ "/vm.conf")
    Api.create.go(Cli.Cli.check(Cm.Sub.l1(flags)), Bool.not(String.is_empty(old)), dir, Cm.Conf.text(flags))

# The command line's commands: their results printed (host/main.bend's cli)
def vmdir.undo_said(r: Result<&1, &1, Err, Sd.Info>) -> IO(Unit):
  match r:
    case Done{+i}:
      IO.print("bend-vmm: saved " ++ Sd.Sdir.name(i) ++ " first (to undo: bend-vmm restore " ++ Sd.Sdir.name(i) ++ ")")
    case Fail{e}:
      IO.die(Unit, 1, "bend-vmm: cannot save the current state before restoring: " ++ Err.text(e))

def cli.kib(+k: U32) -> String:
  Bool.pick(String, U32.is_lt(k, 10240), U32.show(k) ++ " KiB", U32.show((k / 1024 : U32)) ++ " MiB")

def cli.info(i: Sd.Info) -> String:
  match i:
    case Sd.Info{+n, +t, +p, +m, +d, +note}:
      n ++ "  " ++ Sd.Sname.of_time(t) ++ "  memory " ++ Bool.pick(String, U32.is_eq(m, 0), "-", cli.kib(m)) ++ "  disks " ++ cli.kib(d)
        ++ Bool.pick(String, String.is_empty(p), "", "  from " ++ p) ++ Bool.pick(String, String.is_empty(note), "", "  (" ++ note ++ ")")

def cli.infos(xs: List<&2, Sd.Info>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{x, rest}:
      do IO<Unit>:
        IO.print(cli.info(x))
        cli.infos(rest)

def cli.lines(xs: List<&2, String>, +pre: String) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{x, rest}:
      do IO<Unit>:
        IO.print(pre ++ x)
        cli.lines(rest, pre)

def cli.die(e: Err) -> IO(Unit):
  IO.die(Unit, 1, "bend-vmm: " ++ Err.text(e))

def cli.text(r: Result<&1, &1, Err, String>, +pre: String) -> IO(Unit):
  match r:
    case Done{t}:
      IO.print(pre ++ t)
    case Fail{e}:
      cli.die(e)

def cli.snap(r: Result<&1, &1, Err, Sd.Info>) -> IO(Unit):
  match r:
    case Done{i}:
      IO.print("saved " ++ cli.info(i))
    case Fail{e}:
      cli.die(e)

def cli.snaps(r: Result<&1, &1, Err, List<&2, Sd.Info>>) -> IO(Unit):
  match r:
    case Done{+xs}:
      Bool.pick(IO(Unit), List.is_empty(&2, Sd.Info, xs), IO.print("no snapshots"), cli.infos(xs))
    case Fail{e}:
      cli.die(e)

def cli.names(r: Result<&1, &1, Err, List<&2, String>>) -> IO(Unit):
  match r:
    case Done{+xs}:
      Bool.pick(IO(Unit), List.is_empty(&2, String, xs), IO.print("nothing to remove"), cli.lines(xs, "removed "))
    case Fail{e}:
      cli.die(e)

def cli.status(r: Result<&1, &1, Err, Status>) -> IO(Unit):
  match r:
    case Done{Status{+st, +fw}}:
      IO.print(st ++ Bool.pick(String, String.is_empty(fw), "", "  forwards " ++ fw))
    case Fail{e}:
      cli.die(e)

def cli.created(r: Result<&1, &1, Err, String>) -> IO(Unit):
  match r:
    case Done{+p}:
      IO.print("created " ++ p ++ " (run it: bend-vmm run " ++ String.take(p, Nat.sub(String.length(p), 8n)) ++ ")")
    case Fail{e}:
      cli.die(e)

def cli.ctl(+vm: String, +line: String) -> IO(Unit):
  Bool.pick(IO(Unit), String.eq(line, "status json"), IO.bind(Result<&1, &1, Err, Status>, Unit, Vmm.status(vm), cli.status),
    IO.bind(Result<&1, &1, Err, String>, Unit, Vmm.ctl(vm, line), r => cli.text(r, "")))

def cli.none(s: Cm.Sub) -> Bool:
  match s:
    case Cm.SubNone{}:
      True{}
    case _:
      False{}


# Running a VM folder's VM (run: host/main.bend's Vmm.run, passed in)

def die_if(bad: Bool, what: String) -> IO(Unit):
  match bad:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.die(Unit, 1, "bend-vmm: " ++ what)
def vmdir.sock(+dir: String) -> String:
  dir ++ "/control.sock"

# Runs the VM of a folder: its vm.conf's options, its control socket in it.
@unsafe def Vmm.run_dir(run: List<String> -> List<String> -> IO(Unit), +prog: List<String>, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +text : String <- Api.read(dir ++ "/vm.conf")
    die_if(String.is_empty(text), Err.text(ENoVm{dir}))
    run(prog, Cm.Sub.l1(List.append(&2, String, Cm.Conf.flags(dir, text), ["--control", vmdir.sock(dir)])))

def vmdir.stopped(st: Result<&1, &1, Err, Status>) -> Bool:
  match st:
    case Done{Status{state, fw}}:
      String.eq(state, "stopped")
    case Fail{e}:
      True{}

# Waits (at most fuel x 100 ms) for the VM to stop.
def vmdir.wait_stop(fuel: Nat, +vm: String) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      do IO<Unit>:
        st : Result<&1, &1, Err, Status> <- Vmm.status(vm)
        Bool.pick(IO(Unit), vmdir.stopped(st), IO.pure(Unit, Unit{}), IO.bind(Unit, Unit, IO.sleep(100), u => vmdir.wait_stop(k, vm)))

# Runs a folder's VM from one of its snapshots. A snapshot with memory
# restores (its disks set back from its copies, src/vmm/disksnap.bend); one
# of disks only sets them back and boots.
@unsafe def vmdir.restore.go(mem: Bool, run: List<String> -> List<String> -> IO(Unit), +prog: List<String>, +vm: String, +snap: String, +flags: List<&2, String>) -> IO(Unit):
  match mem:
    case True{}:
      run(prog, Cm.Sub.l1(List.append(&2, String, Cm.Conf.for_restore(flags), ["--restore", snap ++ "/memory", "--control", vmdir.sock(vm)])))
    case False{}:
      do IO<Unit>:
        +rc : U32 <- Api.steps(Ds.Dsnap.restore(snap ++ "/memory", Ds.Dsnap.folder_gen(), Ds.Dsnap.writable(Cm.Sub.opt(flags, "--disk", ""))), 0)
        die_if(U32.is_ne(rc, 0), "cannot set the disks back from " ++ snap ++ " (" ++ U32.show(rc) ++ ")")
        run(prog, Cm.Sub.l1(List.append(&2, String, flags, ["--control", vmdir.sock(vm)])))

# bend-vmm restore NAME: the current state is saved first (memory and disks
# when running, disks when stopped: Sname.undo), the VM stopped, then run
# from NAME in this process.
@unsafe def Vmm.restore(run: List<String> -> List<String> -> IO(Unit), +prog: List<String>, +vm: String, +name: String) -> IO(Unit):
  do IO<Unit>:
    +text : String <- Api.read(vm ++ "/vm.conf")
    die_if(String.is_empty(text), Err.text(ENoVm{vm}))
    +snap : String = Sd.Sdir.dir(vm, name)
    +info : String <- Api.read(Sd.Sdir.info(snap))
    die_if(Bool.not(Sd.Sname.valid(name)) || String.is_empty(info), Err.text(ENoSnapshot{name}))
    undo : Result<&1, &1, Err, Sd.Info> <- Vmm.snapshot_undo(vm, "saved before restoring " ++ name)
    vmdir.undo_said(undo)
    _ : Result<&1, &1, Err, String> <- Vmm.stop(vm)
    vmdir.wait_stop(300n, vm)
    _ : Bool <- Api.write(Sd.Sdir.root(vm) ++ "/.current", name)
    +ws : +List<U32> <- H.Hvf.sock_facts(snap ++ "/memory")
    vmdir.restore.go(U32.is_eq(H.Host.first(ws), 2), run, prog, vm, snap, Cm.Conf.flags(vm, text))

@unsafe def cli(run: List<String> -> List<String> -> IO(Unit), +prog: List<String>, s: Cm.Sub) -> IO(Unit):
  match s:
    case Cm.SubNone{}:
      IO.pure(Unit, Unit{})
    case Cm.SubBad{why}:
      IO.die(Unit, 2, "bend-vmm: " ++ why)
    case Cm.SubCreate{dir, flags}:
      IO.bind(Result<&1, &1, Err, String>, Unit, Vmm.create(dir, flags), cli.created)
    case Cm.SubRun{dir}:
      Vmm.run_dir(run, prog, dir)
    case Cm.SubSnap{vm, name, note}:
      IO.bind(Result<&1, &1, Err, Sd.Info>, Unit, Vmm.snapshot(vm, name, note), cli.snap)
    case Cm.SubSnaps{vm}:
      IO.bind(Result<&1, &1, Err, List<&2, Sd.Info>>, Unit, Vmm.snapshots(vm), cli.snaps)
    case Cm.SubRestore{vm, name}:
      Vmm.restore(run, prog, vm, name)
    case Cm.SubRm{vm, name}:
      IO.bind(Result<&1, &1, Err, String>, Unit, Vmm.snapshot_rm(vm, name), r => cli.text(r, "removed "))
    case Cm.SubPrune{vm, keep}:
      IO.bind(Result<&1, &1, Err, List<&2, String>>, Unit, Vmm.prune(vm, keep), cli.names)
    case Cm.SubCtl{vm, line}:
      cli.ctl(vm, line)
    case Cm.SubRaw{sock, line}:
      IO.bind(Result<&1, &1, Err, String>, Unit, Vmm.ctl(sock, line), r => cli.text(r, ""))

