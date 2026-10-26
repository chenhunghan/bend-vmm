import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/layout.bend as L
import ../src/vmm/machine.bend as M
import ../src/vmm/snapshot.bend as Snap
import ../src/net/nat.bend as Nt
import ../src/arm64/psci.bend as Ps
import ../src/virtio/device.bend as D
import ../src/virtio/input.bend as In
import ../src/dev/keymap.bend as Km
import ../src/dev/pflash.bend as Pf
import ../src/boot/image.bend as I
import ../src/boot/dtb.bend as T
import ./hvf.bend as H
import ./fs.bend as Fs

# bend-vmm: boots an arm64 Linux kernel (or a bare-metal payload) on
# Hypervisor.framework. All machine logic is the pure src/vmm/machine.bend;
# this file only drives it:
#   - one vCPU loop per CPU, each its own Bend computation (IO.spawn), whose
#     H.Host.run parks while the guest runs, so vCPUs run in parallel;
#   - the machine state lives in a one-slot channel, taken by the vCPU whose
#     exit is being handled and put back after, so exits serialize;
#   - interp runs the Vm program an exit handler answers, effect by effect.
#
# usage: bend-vmm --kernel Image [--initrd file] [--cmdline "..."]
#                 [--mem MiB] [--cpus N] [--disk image]
#        bend-vmm --payload file.bin      (bare metal: entered at RAM base)

# A VMM message on stderr, after the guest's console output so far.
def log_err(msg: String) -> IO(Unit):
  do IO<Unit>:
    _ : U32 <- H.Hvf.out_flush()
    IO.print_err(msg)

type Opts is Data:
  Opts{kernel: String, initrd: String, payload: String, cmdline: String, mem: U32, cpus: U32, disk: String, share: String, restore: String, control: String, vsock: String, display: String, firmware: String, vars: String}

def Opts.default() -> Opts:
  Opts{"", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 512, 1, "", "", "", "", "", "", "", ""}

def Opts.mem(o: Opts) -> U32:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      m

def Opts.disk(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      d

def Opts.kernel(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      k

def Opts.share(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      sh

def Opts.restore(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      rs

def Opts.control(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      ct

def Opts.cpus(o: Opts) -> U32:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      n

def Opts.vsock(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      vk

def Opts.firmware(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      fw

def Opts.display(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      dp

# "WxH" as a display; None for "" or anything malformed.
def display_of.mk(w: Maybe<&2, U32>, h: Maybe<&2, U32>) -> Maybe<&2, T.Display>:
  match w h:
    case Some{x} Some{y}:
      Some{T.Display{x, y}}
    case _ _:
      None{}

def display_of.go(ws: List<&2, String>) -> Maybe<&2, T.Display>:
  match ws:
    case Con{w, Con{h, Nil{}}}:
      display_of.mk(U32.read(w), U32.read(h))
    case _:
      None{}

def display_of(spec: String) -> Maybe<&2, T.Display>:
  display_of.go(String.split(spec, 'x'))

def Opts.num(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def Opts.set(+flag: String, +v: String, o: Opts) -> Opts:
  match o:
    case Opts{k, i, p, c, +m, +n, d, sh, rs, ct, vk, dp, fw, nv}:
      Opts{
        Bool.pick(String, String.eq(flag, "--kernel"), v, k),
        Bool.pick(String, String.eq(flag, "--initrd"), v, i),
        Bool.pick(String, String.eq(flag, "--payload"), v, p),
        Bool.pick(String, String.eq(flag, "--cmdline"), v, c),
        Bool.pick(U32, String.eq(flag, "--mem"), Opts.num(v, m), m),
        Bool.pick(U32, String.eq(flag, "--cpus"), Opts.num(v, n), n),
        Bool.pick(String, String.eq(flag, "--disk"), v, d),
        Bool.pick(String, String.eq(flag, "--share"), v, sh),
        Bool.pick(String, String.eq(flag, "--restore"), v, rs),
        Bool.pick(String, String.eq(flag, "--control"), v, ct),
        Bool.pick(String, String.eq(flag, "--vsock"), v, vk),
        Bool.pick(String, String.eq(flag, "--display"), v, dp),
        Bool.pick(String, String.eq(flag, "--firmware"), v, fw),
        Bool.pick(String, String.eq(flag, "--vars"), v, nv)
      }

def Opts.parse(args: List<String>, o: Opts) -> Opts:
  match args:
    case Nil{}:
      o
    case Con{flag, rest}:
      match rest:
        case Nil{}:
          o
        case Con{v, more}:
          Opts.parse(more, Opts.set(flag, v, o))

def ram() -> U.U64:
  L.Layout.ram_base()

# RAM size in bytes for mem MiB.
def ram_bytes(mem: U32) -> U.U64:
  U.U64.shl(20n, U.U64.from_u32(mem))

def err() -> U32:
  4294967295

def die_if(bad: Bool, what: String) -> IO(Unit):
  match bad:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.die(Unit, 1, "bend-vmm: " ++ what)

# Boot registers: PC at entry, X0 the DTB, EL1h with DAIF masked (0x3c5).
def boot_regs(+cpu: U32, entry: U.U64, x0: U.U64) -> IO(Unit):
  do IO<Unit>:
    _ : U32 <- H.Host.set_reg(cpu, V.Reg.pc(), entry)
    _ : U32 <- H.Host.set_reg(cpu, 0, x0)
    _ : U32 <- H.Host.set_reg(cpu, H.Reg.cpsr(), U.U64{0, 965})
    return Unit{}

def advance_pc(cpu: U32) -> IO(U32):
  H.Host.advance_pc(cpu)

# The machine lives in a one-slot channel: take it, handle an exit, put it back.
def take.got(got: Maybe<&1, M.Machine>) -> IO(M.Machine):
  match got:
    case None{}:
      IO.die(M.Machine, 1, "bend-vmm: machine channel closed")
    case Some{m}:
      IO.pure(M.Machine, m)

def take(mc: Chan(M.Machine)) -> IO(M.Machine):
  do IO<M.Machine>:
    got : Maybe<&1, M.Machine> <- Chan.recv(M.Machine, mc)
    take.got(got)

def put(mc: Chan(M.Machine), m: M.Machine) -> IO(Unit):
  do IO<Unit>:
    _ : Result<&1, &1, M.Machine, Unit> <- Chan.send(M.Machine, mc, m)
    return Unit{}

# A UEFI flash command on bank 1 (host/hvf.c, Hvf.flash).
def flash_cmd(cmd: V.FlashCmd) -> IO(U32):
  match cmd:
    case V.FlashRead{off, size}:
      H.Hvf.flash(0, off, size, [])
    case V.FlashWrite{off, bs}:
      H.Hvf.flash(1, off, 0, bs)
    case V.FlashErase{off, len}:
      H.Hvf.flash(2, off, len, [])
    case V.FlashMap{on}:
      H.Hvf.flash(3, Bool.to_u32(on), 0, [])

# Runs the Vm program of an exit of vCPU cpu. VmCpuOn starts that vCPU's loop,
# which is defined below (hence @unsafe: the two recurse into each other).
@unsafe def interp(+cpu: U32, +mc: Chan(M.Machine), +done: Chan(U32), -A: Type, m: V.Vm<A>) -> IO(A):
  match m:
    case V.VmRet{x}:
      IO.pure(A, x)
    case V.VmRead{a, n, k}:
      do IO<A>:
        bs : +List<U32> <- H.Host.read(a, n)
        interp(cpu, mc, done, A, k(bs))
    case V.VmWrite{a, bs, next}:
      do IO<A>:
        _ : U32 <- H.Host.write(a, bs)
        interp(cpu, mc, done, A, next)
    case V.VmSetReg{r, v, next}:
      do IO<A>:
        _ : U32 <- H.Host.set_reg(cpu, r, v)
        interp(cpu, mc, done, A, next)
    case V.VmAdvancePc{next}:
      do IO<A>:
        _ : U32 <- advance_pc(cpu)
        interp(cpu, mc, done, A, next)
    case V.VmConsole{bs, next}:
      do IO<A>:
        _ : U32 <- H.Hvf.out(bs)
        interp(cpu, mc, done, A, next)
    case V.VmIrq{i, l, next}:
      do IO<A>:
        _ : U32 <- H.Hvf.irq(i, Bool.to_u32(l))
        interp(cpu, mc, done, A, next)
    case V.VmPower{op, next}:
      interp(cpu, mc, done, A, next)
    case V.VmCpuOn{+c, e, x, next}:
      do IO<A>:
        _ : U32 <- H.Host.vcpu_create(c)
        boot_regs(c, e, x)
        IO.spawn(Unit, vcpu_loop(c, mc, done))
        interp(cpu, mc, done, A, next)
    case V.VmLog{msg, next}:
      do IO<A>:
        log_err("[vmm] " ++ msg)
        interp(cpu, mc, done, A, next)
    case V.VmDiskRead{d, off, n, k}:
      do IO<A>:
        bs : +List<U32> <- H.Host.disk_read(d, off, n)
        interp(cpu, mc, done, A, k(bs))
    case V.VmDiskWrite{d, off, bs, next}:
      do IO<A>:
        _ : U32 <- H.Host.disk_write(d, off, bs)
        interp(cpu, mc, done, A, next)
    case V.VmRandom{n, k}:
      do IO<A>:
        bs : +List<U32> <- H.Hvf.random(n)
        interp(cpu, mc, done, A, k(bs))
    case V.VmNow{k}:
      do IO<A>:
        t : U.U64 <- H.Host.now()
        interp(cpu, mc, done, A, k(t))
    case V.VmDiskFlush{d, next}:
      do IO<A>:
        _ : U32 <- H.Hvf.disk_flush(d)
        interp(cpu, mc, done, A, next)
    case V.VmNet{cmd, next}:
      do IO<A>:
        net_cmd(mc, done, cmd)
        interp(cpu, mc, done, A, next)
    case V.VmVsock{cmd, next}:
      do IO<A>:
        vsock_cmd(mc, done, cmd)
        interp(cpu, mc, done, A, next)
    case V.VmFlash{cmd, k}:
      do IO<A>:
        v : U32 <- flash_cmd(cmd)
        interp(cpu, mc, done, A, k(v))
    case V.VmFs{sh, op, k}:
      do IO<A>:
        r : V.FsResult <- Fs.Host.fs(sh, op)
        interp(cpu, mc, done, A, k(r))

# Host network: the NAT's commands run on host sockets; what the sockets
# report comes back as NetEvents, each delivered by a task of its own (the
# machine is held while a Vm program runs, so delivery must wait its turn).
@unsafe def net_deliver(+mc: Chan(M.Machine), +done: Chan(U32), ev: V.NetEvent) -> IO(Unit):
  do IO<Unit>:
    m0 : M.Machine <- take(mc)
    m1 : M.Machine <- interp(0, mc, done, M.Machine, M.Machine.net_event(m0, ev))
    put(mc, m1)

# Backpressure: the link to the guest must stay lossless, so a reader waits
# while too many frames are pending for the guest.
@unsafe def net_wait(+mc: Chan(M.Machine), fuel: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        +m : M.Machine <- take(mc)
        put(mc, m)
        net_wait.go(U32.is_lt(M.Machine.net_backlog(m), 64), mc, f)

@unsafe def net_wait.go(ok: Bool, +mc: Chan(M.Machine), fuel: Nat) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.sleep(2)
        net_wait(mc, fuel)

@unsafe def tcp_reader.got(eof: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32, bs: +List<U32>) -> IO(Unit):
  match eof:
    case True{}:
      net_deliver(mc, done, V.TcpEof{conn})
    case False{}:
      do IO<Unit>:
        net_deliver(mc, done, V.TcpData{conn, bs})
        net_wait(mc, 5000n)
        tcp_reader(mc, done, conn)

@unsafe def tcp_reader(+mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  do IO<Unit>:
    +bs : +List<U32> <- H.Hvf.tcp_recv(conn)
    tcp_reader.got(List.is_empty(&2, U32, bs), mc, done, conn, bs)

@unsafe def tcp_task.connected(ok: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        net_deliver(mc, done, V.TcpConnected{conn})
        tcp_reader(mc, done, conn)
    case False{}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_close(conn)
        net_deliver(mc, done, V.TcpRefused{conn})

@unsafe def tcp_task(+mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  do IO<Unit>:
    rc : U32 <- H.Hvf.tcp_wait(conn)
    tcp_task.connected(U32.is_zero(rc), mc, done, conn)

@unsafe def udp_task.got(stop: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +sport: U32, +ws: +List<U32>) -> IO(Unit):
  match stop:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        net_deliver(mc, done, V.UdpData{H.Host.first(ws), H.Host.first(List.drop(&2, U32, ws, 1n)), sport, List.drop(&2, U32, ws, 2n)})
        udp_task(mc, done, sport)

@unsafe def udp_task(+mc: Chan(M.Machine), +done: Chan(U32), +sport: U32) -> IO(Unit):
  do IO<Unit>:
    +ws : +List<U32> <- H.Hvf.udp_recv(sport)
    udp_task.got(List.is_empty(&2, U32, ws), mc, done, sport, ws)

@unsafe def net_cmd.connect(ok: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  match ok:
    case True{}:
      IO.spawn(Unit, tcp_task(mc, done, conn))
    case False{}:
      IO.spawn(Unit, net_deliver(mc, done, V.TcpRefused{conn}))

@unsafe def net_cmd.udp(fresh: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +sport: U32) -> IO(Unit):
  match fresh:
    case True{}:
      IO.spawn(Unit, udp_task(mc, done, sport))
    case False{}:
      IO.pure(Unit, Unit{})

@unsafe def net_cmd(+mc: Chan(M.Machine), +done: Chan(U32), cmd: V.NetCmd) -> IO(Unit):
  match cmd:
    case V.TcpConnect{+conn, ip, port}:
      do IO<Unit>:
        rc : U32 <- H.Hvf.tcp_connect(conn, ip, port)
        net_cmd.connect(U32.is_zero(rc), mc, done, conn)
    case V.TcpSend{conn, bs}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_send(conn, bs)
        return Unit{}
    case V.TcpShutdown{conn}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_shutdown(conn)
        return Unit{}
    case V.TcpClose{conn}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_close(conn)
        return Unit{}
    case V.UdpSend{+sport, ip, port, bs}:
      do IO<Unit>:
        rc : U32 <- H.Hvf.udp_send(sport, ip, port, bs)
        net_cmd.udp(U32.is_eq(rc, 1), mc, done, sport)

# Management: pause, resume and snapshots, from the console escapes
# (Ctrl-A p / s) and the control socket (--control PATH).
# ==============================================================

# Waits until no vCPU is inside the guest (they stop at the pause gate).
@unsafe def wait_stopped(fuel: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        +st : +List<U32> <- H.Hvf.pause_state()
        wait_stopped.go(U32.is_zero(H.Host.first(List.drop(&2, U32, st, 1n))), f)

@unsafe def wait_stopped.go(done: Bool, fuel: Nat) -> IO(Unit):
  match done:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.sleep(1)
        wait_stopped(fuel)

@unsafe def pause_vm() -> IO(U32):
  do IO<U32>:
    was : U32 <- H.Hvf.pause()
    wait_stopped(10000n)
    return was

def resume_if(was_running: Bool) -> IO(Unit):
  match was_running:
    case True{}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.resume()
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})

# Pauses (if running), writes the snapshot while holding the machine, and
# resumes if it was running. Answers 0 or an errno.
@unsafe def snapshot(+mc: Chan(M.Machine), path: String) -> IO(U32):
  do IO<U32>:
    +was : U32 <- pause_vm()
    +m : M.Machine <- take(mc)
    rc : U32 <- H.Hvf.snap_write(path, Snap.Snap.encode(m))
    put(mc, m)
    resume_if(U32.is_zero(was))
    return rc

def reply_rc(+rc: U32, ok: String) -> String:
  Bool.pick(String, U32.is_zero(rc), ok, "error " ++ U32.show(rc))

# A keyboard or pointer report into the machine (M.Machine.hid).
@unsafe def display.hid(+mc: Chan(M.Machine), +done: Chan(U32), ev: In.Hid) -> IO(Unit):
  do IO<Unit>:
    m0 : M.Machine <- take(mc)
    m1 : M.Machine <- interp(0, mc, done, M.Machine, M.Machine.hid(m0, ev))
    put(mc, m1)

@unsafe def type_keys(+mc: Chan(M.Machine), +done: Chan(U32), evs: +List<In.Hid>) -> IO(Unit):
  match evs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{ev, rest}:
      do IO<Unit>:
        display.hid(mc, done, ev)
        type_keys(mc, done, rest)

@unsafe def command.dump(is_dump: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +verb: String, arg: String) -> IO(String):
  match is_dump:
    case True{}:
      do IO<String>:
        +rc : U32 <- H.Hvf.fb_dump(arg)
        return reply_rc(rc, "saved")
    case False{}:
      command.run(String.eq(verb, "pause"), String.eq(verb, "resume"), String.eq(verb, "snapshot"), String.eq(verb, "status"), String.eq(verb, "quit"), mc, done, arg)

@unsafe def command.run(is_pause: Bool, is_resume: Bool, is_snap: Bool, is_status: Bool, is_quit: Bool, +mc: Chan(M.Machine), +done: Chan(U32), arg: String) -> IO(String):
  match is_pause is_resume is_snap is_status is_quit:
    case True{} _ _ _ _:
      do IO<String>:
        _ : U32 <- pause_vm()
        return "paused"
    case False{} True{} _ _ _:
      do IO<String>:
        _ : U32 <- H.Hvf.resume()
        return "running"
    case False{} False{} True{} _ _:
      do IO<String>:
        +rc : U32 <- snapshot(mc, arg)
        return reply_rc(rc, "saved")
    case False{} False{} False{} True{} _:
      do IO<String>:
        +st : +List<U32> <- H.Hvf.pause_state()
        return Bool.pick(String, U32.is_zero(H.Host.first(st)), "running", "paused")
    case False{} False{} False{} False{} True{}:
      do IO<String>:
        _ : Result<&1, &1, U32, Unit> <- Chan.send(U32, done, 0)
        return "bye"
    case False{} False{} False{} False{} False{}:
      IO.pure(String, "unknown command (pause, resume, snapshot PATH, screendump PATH, type TEXT, pointer X Y, status, quit)")

# The tablet report of "X Y" (0..32767 each): a move.
def pointer_of.mk(x: Maybe<&2, U32>, y: Maybe<&2, U32>) -> Maybe<&2, In.Hid>:
  match x y:
    case Some{a} Some{b}:
      Some{In.HidMove{a, b}}
    case _ _:
      None{}

def pointer_of.go(ws: List<&2, String>) -> Maybe<&2, In.Hid>:
  match ws:
    case Con{x, Con{y, Nil{}}}:
      pointer_of.mk(U32.read(x), U32.read(y))
    case _:
      None{}

def pointer_of(arg: String) -> Maybe<&2, In.Hid>:
  pointer_of.go(String.split(arg, ' '))

@unsafe def command.pointer.go(ev: Maybe<&2, In.Hid>, +mc: Chan(M.Machine), +done: Chan(U32)) -> IO(String):
  match ev:
    case None{}:
      IO.pure(String, "usage: pointer X Y (0..32767)")
    case Some{h}:
      do IO<String>:
        display.hid(mc, done, h)
        return "moved"

# pointer X Y: moves the virtio tablet to (X, Y) on its 0..32767 scale.
@unsafe def command.pointer(is_pointer: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +verb: String, arg: String) -> IO(String):
  match is_pointer:
    case True{}:
      command.pointer.go(pointer_of(arg), mc, done)
    case False{}:
      command.dump(String.eq(verb, "screendump"), mc, done, verb, arg)

# type TEXT: types TEXT on the virtio keyboard (Km.Keymap.typing; \n is
# Return).
@unsafe def command.type(is_type: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +verb: String, arg: String) -> IO(String):
  match is_type:
    case True{}:
      do IO<String>:
        type_keys(mc, done, Km.Keymap.typing(B.Bytes.of_string(arg), False{}))
        return "typed"
    case False{}:
      command.pointer(String.eq(verb, "pointer"), mc, done, verb, arg)

# One command line: a verb and an optional argument.
@unsafe def command(+mc: Chan(M.Machine), +done: Chan(U32), +line: String) -> IO(String):
  +parts = String.split(String.trim(line), ' ')
  +verb = Maybe.default(&2, String, List.head(&2, String, parts), "")
  +arg = String.join(List.drop(&2, String, parts, 1n), " ")
  command.type(String.eq(verb, "type"), mc, done, verb, arg)

@unsafe def ctl_loop.got(stop: Bool, +mc: Chan(M.Machine), +done: Chan(U32), bs: +List<U32>) -> IO(Unit):
  match stop:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        r : String <- command(mc, done, Fs.Fs.chars(bs))
        _ : U32 <- H.Hvf.ctl_reply(r)
        ctl_loop(mc, done)

@unsafe def ctl_loop(+mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    +bs : +List<U32> <- H.Hvf.ctl_next()
    ctl_loop.got(List.is_empty(&2, U32, bs), mc, done, bs)

# A console escape (a word above 255): p toggles pause, s snapshots to
# ./bend-vmm.snap, h prints the keys.
@unsafe def escape.run(is_p: Bool, is_s: Bool, paused: Bool, +mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  match is_p is_s paused:
    case True{} _ True{}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.resume()
        log_err("\r\n[bend-vmm] resumed\r")
    case True{} _ False{}:
      do IO<Unit>:
        _ : U32 <- pause_vm()
        log_err("\r\n[bend-vmm] paused (Ctrl-A p resumes)\r")
    case False{} True{} _:
      do IO<Unit>:
        +rc : U32 <- snapshot(mc, "bend-vmm.snap")
        log_err("\r\n[bend-vmm] snapshot ./bend-vmm.snap: " ++ reply_rc(rc, "saved") ++ "\r")
    case False{} False{} _:
      log_err("\r\n[bend-vmm] Ctrl-A: p pause/resume, s snapshot, x quit, Ctrl-A send Ctrl-A\r")

# vsock: the device's commands run on Unix sockets (host/hvf.c); what the
# sockets report comes back as VsockEvents, each delivered by its own task.
@unsafe def vs_deliver(+mc: Chan(M.Machine), +done: Chan(U32), ev: V.VsockEvent) -> IO(Unit):
  do IO<Unit>:
    m0 : M.Machine <- take(mc)
    m1 : M.Machine <- interp(0, mc, done, M.Machine, M.Machine.vsock_event(m0, ev))
    put(mc, m1)

def vkey(+conn: U32) -> U32:
  (conn .^. 1073741824 : U32)

# Holds a reader back while the guest has too much vsock data pending.
@unsafe def vs_wait(+mc: Chan(M.Machine), fuel: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        +m : M.Machine <- take(mc)
        put(mc, m)
        vs_wait.go(U32.is_lt(M.Machine.vsock_backlog(m), 32), mc, f)

@unsafe def vs_wait.go(ok: Bool, +mc: Chan(M.Machine), fuel: Nat) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.sleep(2)
        vs_wait(mc, fuel)

@unsafe def vs_reader.got(eof: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32, bs: +List<U32>) -> IO(Unit):
  match eof:
    case True{}:
      vs_deliver(mc, done, V.VsEof{conn})
    case False{}:
      do IO<Unit>:
        vs_deliver(mc, done, V.VsData{conn, bs})
        vs_wait(mc, 5000n)
        vs_reader(mc, done, conn)

@unsafe def vs_reader(+mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  do IO<Unit>:
    +bs : +List<U32> <- H.Hvf.tcp_recv(vkey(conn))
    vs_reader.got(List.is_empty(&2, U32, bs), mc, done, conn, bs)

@unsafe def vs_task.connected(ok: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        vs_deliver(mc, done, V.VsConnected{conn})
        vs_reader(mc, done, conn)
    case False{}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_close(vkey(conn))
        vs_deliver(mc, done, V.VsRefused{conn})

@unsafe def vs_task(+mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  do IO<Unit>:
    rc : U32 <- H.Hvf.tcp_wait(vkey(conn))
    vs_task.connected(U32.is_zero(rc), mc, done, conn)

@unsafe def vs_connect.go(ok: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +conn: U32) -> IO(Unit):
  match ok:
    case True{}:
      IO.spawn(Unit, vs_task(mc, done, conn))
    case False{}:
      IO.spawn(Unit, vs_deliver(mc, done, V.VsRefused{conn}))

# The --vsock base path, kept by the C side (Hvf.vsock_base).
@unsafe def vsock_cmd(+mc: Chan(M.Machine), +done: Chan(U32), cmd: V.VsockCmd) -> IO(Unit):
  match cmd:
    case V.VsConnect{+conn, port}:
      do IO<Unit>:
        base : String <- H.Hvf.vsock_base()
        rc : U32 <- H.Hvf.unix_connect(vkey(conn), base ++ "_" ++ U32.show(port))
        vs_connect.go(U32.is_zero(rc), mc, done, conn)
    case V.VsSend{conn, bs}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_send(vkey(conn), bs)
        return Unit{}
    case V.VsShutdown{conn}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_shutdown(vkey(conn))
        return Unit{}
    case V.VsClose{conn}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_close(vkey(conn))
        return Unit{}
    case V.VsAccepted{+conn, port}:
      do IO<Unit>:
        _ : U32 <- H.Hvf.tcp_send(vkey(conn), B.Bytes.of_string("OK " ++ U32.show(port) ++ "\n"))
        IO.spawn(Unit, vs_reader(mc, done, conn))

# Host clients asking for guest ports.
@unsafe def vs_accept_loop.got(stop: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +ws: +List<U32>) -> IO(Unit):
  match stop:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.spawn(Unit, vs_deliver(mc, done, V.VsIncoming{H.Host.first(ws), H.Host.first(List.drop(&2, U32, ws, 1n))}))
        vs_accept_loop(mc, done)

@unsafe def vs_accept_loop(+mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    +ws : +List<U32> <- H.Hvf.vsock_accept()
    vs_accept_loop.got(List.is_empty(&2, U32, ws), mc, done, ws)

# The display: Bend's Window shows the guest's framebuffer (host/hvf.c,
# Hvf.fb_present). The first frame goes through Window.frame (Bend's own
# renderer), the rest are blitted straight from guest memory. Keys go to the
# virtio keyboard (as Linux key codes, Km.Keymap.linux), the pointer and its
# buttons to the virtio tablet; closing the window stops the VM. The window
# is w x h points, one per framebuffer pixel.
# A window coordinate (0..size-1) on the tablet's 0..32767 scale.
def display.scale(+v: U32, +size: U32) -> U32:
  ((v * 32767 : U32) / Bool.pick(U32, U32.is_lt(size, 2), 1, (size - 1 : U32)) : U32)

@unsafe def display.events(+mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, evs: List<Event>) -> IO(Bool):
  match evs:
    case Nil{}:
      IO.pure(Bool, False{})
    case Con{ev, rest}:
      match ev:
        case Close{}:
          do IO<Bool>:
            _ : Result<&1, &1, U32, Unit> <- Chan.send(U32, done, 0)
            return True{}
        case Key{code, down}:
          do IO<Bool>:
            display.hid(mc, done, In.HidKey{Km.Keymap.linux(code), down})
            display.events(mc, done, w, h, rest)
        case Mouse{x, y, b, down}:
          do IO<Bool>:
            display.hid(mc, done, In.HidMove{display.scale(x, w), display.scale(y, h)})
            display.hid(mc, done, In.HidButton{b, down})
            display.events(mc, done, w, h, rest)
        case Move{x, y}:
          do IO<Bool>:
            display.hid(mc, done, In.HidMove{display.scale(x, w), display.scale(y, h)})
            display.events(mc, done, w, h, rest)
        case _:
          display.events(mc, done, w, h, rest)

@unsafe def display.loop(+mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, win: Window) -> IO(Unit):
  do IO<Unit>:
    r : Window & List<Event> <- H.Hvf.fb_present(win)
    display.next(mc, done, w, h, r)

@unsafe def display.next(+mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, r: Window & List<Event>) -> IO(Unit):
  match r:
    case (win, evs):
      do IO<Unit>:
        closed : Bool <- display.events(mc, done, w, h, evs)
        display.again(closed, mc, done, w, h, win)

@unsafe def display.again(closed: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, win: Window) -> IO(Unit):
  match closed:
    case True{}:
      Window.close(win)
    case False{}:
      do IO<Unit>:
        IO.sleep(16)
        display.loop(mc, done, w, h, win)

@unsafe def display.first(+mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, r: Window & Image & List<Event>) -> IO(Unit):
  match r:
    case (win, (img, evs)):
      display.loop(mc, done, w, h, win)

@unsafe def display.opened(+mc: Chan(M.Machine), +done: Chan(U32), +w: U32, +h: U32, r: Result<&1, &1, U32 & String, Window>) -> IO(Unit):
  match r:
    case Fail{(code, why)}:
      log_err("bend-vmm: no display window: " ++ why)
    case Done{win}:
      do IO<Unit>:
        first : Window & Image & List<Event> <- Window.frame(win, Pix{0})
        display.first(mc, done, w, h, first)

@unsafe def display.start(d: Maybe<&2, T.Display>, +mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  match d:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{T.Display{+w, +h}}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, Window> <- Window.open("bend-vmm", w, h)
        IO.spawn(Unit, display.opened(mc, done, w, h, r))

# Maps the framebuffer when --display asks for one.
def display.map(d: Maybe<&2, T.Display>) -> IO(Unit):
  match d:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{T.Display{w, h}}:
      do IO<Unit>:
        +rc : U32 <- H.Hvf.fb_init(w, h)
        die_if(U32.is_ne(rc, 0), "cannot map the framebuffer (" ++ U32.show(rc) ++ ")")

# Bytes typed on the host console go to the UART: this loop parks on stdin
# and hands each chunk to the machine. An idle guest may never exit (the GIC
# and timer live in Hypervisor.framework), so input cannot wait for exits.
# Pasted or piped input outruns the UART's 32-byte FIFO, so input_feed gives
# it what fits and the rest as the guest drains it, polling every 2 ms; after
# tries polls with no room (a guest not reading the UART) the rest goes
# anyway, and what does not fit is dropped as by the hardware.
@unsafe def input_feed(+mc: Chan(M.Machine), +done: Chan(U32), bs: +List<U32>, +tries: U32) -> IO(Unit):
  match bs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{b, t}:
      +all = {b <> t : +List<U32>}
      do IO<Unit>:
        +m0 : M.Machine <- take(mc)
        +room : Nat = Bool.pick(Nat, U32.is_zero(tries), 4096n, M.Machine.uart_room(m0))
        m1 : M.Machine <- interp(0, mc, done, M.Machine, M.Machine.input(m0, List.take(&2, U32, all, room)))
        put(mc, m1)
        IO.sleep(Bool.pick(U32, List.is_empty(&2, U32, List.drop(&2, U32, all, room)), 0, 2))
        input_feed(mc, done, List.drop(&2, U32, all, room), Bool.pick(U32, Nat.is_eq(room, 0n), (tries - 1 : U32), 250))

@unsafe def input_loop.cmd(+mc: Chan(M.Machine), +done: Chan(U32), +key: U32) -> IO(Unit):
  do IO<Unit>:
    +st : +List<U32> <- H.Hvf.pause_state()
    escape.run(U32.is_eq(key, 368), U32.is_eq(key, 371), U32.is_ne(H.Host.first(st), 0), mc, done)
    input_loop(mc, done)

@unsafe def input_loop.go(eof: Bool, byte: Bool, +mc: Chan(M.Machine), +done: Chan(U32), +bs: +List<U32>) -> IO(Unit):
  match eof byte:
    case True{} _:
      IO.pure(Unit, Unit{})
    case False{} False{}:
      input_loop.cmd(mc, done, H.Host.first(bs))
    case False{} True{}:
      do IO<Unit>:
        input_feed(mc, done, bs, 250)
        input_loop(mc, done)

@unsafe def input_loop(+mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    +bs : +List<U32> <- H.Hvf.stdin_wait(64)
    input_loop.go(List.is_empty(&2, U32, bs), U32.is_lt(H.Host.first(bs), 256), mc, done, bs)

# One vCPU: run, hand the exit to the machine, act on the answer, repeat.
@unsafe def vcpu_loop(+cpu: U32, +mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    e : V.RawExit <- H.Host.run(cpu)
    m : M.Machine <- take(mc)
    step : M.Step <- interp(cpu, mc, done, M.Step, M.Machine.on_exit(cpu, m, e))
    vcpu_loop.next(cpu, mc, done, step)

@unsafe def vcpu_loop.ctl(+cpu: U32, +mc: Chan(M.Machine), +done: Chan(U32), ctl: M.Control) -> IO(Unit):
  match ctl:
    case M.Run{}:
      vcpu_loop(cpu, mc, done)
    case M.Idle{}:
      # WFI: give the timer and the devices a moment, then resume.
      do IO<Unit>:
        IO.sleep(1)
        vcpu_loop(cpu, mc, done)
    case M.CpuStop{}:
      IO.pure(Unit, Unit{})
    case M.Stop{code}:
      do IO<Unit>:
        _ : Result<&1, &1, U32, Unit> <- Chan.send(U32, done, code)
        return Unit{}

@unsafe def vcpu_loop.next(+cpu: U32, +mc: Chan(M.Machine), +done: Chan(U32), step: M.Step) -> IO(Unit):
  match step:
    case M.Step{m, ctl}:
      do IO<Unit>:
        put(mc, m)
        vcpu_loop.ctl(cpu, mc, done, ctl)

# Devices, in slot order: virtio-rng, virtio-console (hvc0), virtio-net
# (the user-mode NAT), then a virtio-blk with --disk and a virtio-9p (tag
# "share") with --share.
def base_devices() -> +List<D.DevKind>:
  [D.RngKind{}, D.ConsoleKind{}, D.NetKind{[82, 84, 0, 18, 52, 86]}]

# One disk image: "path" (read-write) or "path:ro" (read-only).
def devices.kind(ro: Bool, +id: U32, sectors: U.U64) -> D.DevKind:
  match ro:
    case True{}:
      D.BlkRoKind{id, sectors}
    case False{}:
      D.BlkKind{id, sectors}

def devices.open(ro: Bool, +id: U32) -> IO(D.DevKind):
  do IO<D.DevKind>:
    die_if(U32.is_eq(id, err()), "cannot open a disk image")
    size : U.U64 <- H.Host.disk_size(id)
    return devices.kind(ro, id, U.U64.shr(9n, size))

def devices.one(+spec: String) -> IO(D.DevKind):
  +ro = String.ends_with(spec, ":ro")
  path : String = Bool.pick(String, ro, String.take(spec, Nat.sub(String.length(spec), 3n)), spec)
  do IO<D.DevKind>:
    id : U32 <- H.Hvf.disk_open(path)
    devices.open(ro, id)

# --disk a.img,b.img:ro gives one virtio-blk per image, in order.
def devices.disks(specs: List<&2, String>) -> IO(+List<D.DevKind>):
  match specs:
    case Nil{}:
      IO.pure(+List<D.DevKind>, [])
    case Con{spec, rest}:
      do IO<+List<D.DevKind>>:
        k : D.DevKind <- devices.one(spec)
        ks : +List<D.DevKind> <- devices.disks(rest)
        return k <> ks

def devices.disk(none: Bool, disk: String) -> IO(+List<D.DevKind>):
  match none:
    case True{}:
      IO.pure(+List<D.DevKind>, [])
    case False{}:
      devices.disks(String.split(disk, ','))

def devices.share(none: Bool, dir: String) -> IO(+List<D.DevKind>):
  match none:
    case True{}:
      IO.pure(+List<D.DevKind>, [])
    case False{}:
      do IO<+List<D.DevKind>>:
        +sh : U32 <- H.Hvf.share_open(dir)
        die_if(U32.is_eq(sh, err()), "cannot open the shared directory")
        return [D.P9Kind{sh, "share"}]

# --vsock PATH: a virtio-vsock device (guest CID 3) whose host side is
# Unix sockets under PATH.
def devices.vsock(none: Bool, path: String) -> IO(+List<D.DevKind>):
  match none:
    case True{}:
      IO.pure(+List<D.DevKind>, [])
    case False{}:
      do IO<+List<D.DevKind>>:
        +rc : U32 <- H.Hvf.vsock_listen(path)
        die_if(U32.is_ne(rc, 0), "cannot listen on the vsock socket (" ++ U32.show(rc) ++ ")")
        return [D.VsockKind{U.U64{0, 3}}]

# --display: a virtio keyboard and tablet for the window.
def devices.input(none: Bool) -> +List<D.DevKind>:
  match none:
    case True{}:
      []
    case False{}:
      [D.InputKind{False{}}, D.InputKind{True{}}]

def devices(o: Opts) -> IO(+List<D.DevKind>):
  match o:
    case Opts{k, i, p, c, m, n, +d, +sh, rs, ct, +vk, dp, fw, nv}:
      do IO<+List<D.DevKind>>:
        +disks : +List<D.DevKind> <- devices.disk(String.is_empty(d), d)
        +shares : +List<D.DevKind> <- devices.share(String.is_empty(sh), sh)
        +socks : +List<D.DevKind> <- devices.vsock(String.is_empty(vk), vk)
        return List.append(&2, D.DevKind, base_devices(), List.append(&2, D.DevKind, disks, List.append(&2, D.DevKind, shares, List.append(&2, D.DevKind, socks, devices.input(String.is_empty(dp))))))

def initrd_of(present: Bool, start: U.U64, end: U.U64) -> Maybe<&2, T.Initrd>:
  match present:
    case True{}:
      Some{T.Initrd{start, end}}
    case False{}:
      None{}

def place_initrd(present: Bool, path: String, at: U.U64) -> IO(U32):
  match present:
    case True{}:
      H.Host.load(path, at)
    case False{}:
      IO.pure(U32, 0)

def no_image() -> I.ImageInfo:
  I.ImageInfo{U.U64.zero(), U.U64.zero(), U.U64.zero()}

# Writes the DTB and the initrd where the layout says; answers (entry, dtb).
def boot_linux.lay(lay: I.Layout, o: Opts, +ilen: U32, nslots: Nat) -> IO(U.U64 & U.U64):
  match lay o:
    case I.Layout{kernel, kend, +dtb, +rd, rd_end} Opts{k, initrd, p, cmdline, +mem, cpus, d, sh, rs, ct, vk, dp, fw, nv}:
      +has_rd = U32.is_ne(ilen, 0)
      do IO<U.U64 & U.U64>:
        cfg : T.DtbCfg = T.DtbCfg{U32.to_nat(cpus), ram_bytes(mem), cmdline, initrd_of(has_rd, rd, rd_end), nslots, display_of(dp), False{}}
        rc : U32 <- H.Host.write(dtb, T.Dtb.build(cfg))
        die_if(U32.is_ne(rc, 0), "writing the DTB")
        got : U32 <- place_initrd(has_rd, initrd, rd)
        die_if(U32.is_ne(got, ilen), "loading the initrd")
        return (kernel, dtb)

def boot_linux.placed(placed: Maybe<&2, I.Layout>, o: Opts, ilen: U32, nslots: Nat) -> IO(U.U64 & U.U64):
  match placed:
    case None{}:
      IO.die(U.U64 & U.U64, 1, "bend-vmm: the kernel, DTB and initrd do not fit in RAM")
    case Some{lay}:
      boot_linux.lay(lay, o, ilen, nslots)

# Loads the kernel at the start of RAM (text_offset 0, every kernel since
# 3.17), then places the DTB and initrd after it.
def boot_linux(+o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match o:
    case Opts{kernel, +initrd, p, c, +mem, cpus, d, sh, rs, ct, vk, dp, fw, nv}:
      do IO<U.U64 & U.U64>:
        +klen : U32 <- H.Host.load(kernel, ram())
        die_if(U32.is_eq(klen, err()), "cannot load the kernel")
        hdr : +List<U32> <- H.Host.read(ram(), 64)
        +rlen : U32 <- H.Hvf.file_size(initrd)
        +ilen : U32 = Bool.pick(U32, U32.is_eq(rlen, err()), 0, rlen)
        info : I.ImageInfo = Maybe.default(&2, I.ImageInfo, I.Image.parse(hdr), no_image())
        placed : Maybe<&2, I.Layout> = I.Image.layout(ram(), ram_bytes(mem), info, klen, 65536, ilen)
        boot_linux.placed(placed, o, ilen, nslots)

# A bare-metal payload runs from the start of RAM, with the DTB 64 MiB in.
def boot_payload(+o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match o:
    case Opts{k, i, payload, cmdline, +mem, cpus, d, sh, rs, ct, vk, dp, fw, nv}:
      +dtb = U.U64.add_u32(ram(), 67108864)
      do IO<U.U64 & U.U64>:
        cfg : T.DtbCfg = T.DtbCfg{U32.to_nat(cpus), ram_bytes(mem), cmdline, None{}, nslots, display_of(dp), False{}}
        n : U32 <- H.Host.load(payload, ram())
        die_if(U32.is_eq(n, err()), "cannot load the payload")
        _ : U32 <- H.Host.write(dtb, T.Dtb.build(cfg))
        return (ram(), dtb)

# --firmware: UEFI firmware runs in place from flash bank 0 (address 0) and
# finds the device tree, with the flash banks in it, at the start of RAM, as
# edk2's ArmVirtQemu expects of QEMU's virt machine.
def boot_uefi(+o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match o:
    case Opts{k, i, p, cmdline, +mem, cpus, d, sh, rs, ct, vk, dp, fw, nv}:
      do IO<U.U64 & U.U64>:
        +rc : U32 <- H.Hvf.fw_load(fw, nv)
        die_if(U32.is_ne(rc, 0), "cannot load the firmware (step " ++ U32.show(rc) ++ ")")
        cfg : T.DtbCfg = T.DtbCfg{U32.to_nat(cpus), ram_bytes(mem), cmdline, None{}, nslots, display_of(dp), True{}}
        _ : U32 <- H.Host.write(ram(), T.Dtb.build(cfg))
        return (L.Layout.flash0_base(), ram())

def boot.kernel(payload: Bool, o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match payload:
    case True{}:
      boot_payload(o, nslots)
    case False{}:
      boot_linux(o, nslots)

def boot.go(kernel: Bool, +o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match kernel:
    case False{}:
      boot_uefi(o, nslots)
    case True{}:
      boot.kernel(String.is_empty(Opts.kernel(o)), o, nslots)

def boot(+o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  boot.go(String.is_empty(Opts.firmware(o)), o, nslots)

# Stop code 1 is a guest reset: start over in a fresh process.
def stopped.reset(reset: Bool, +code: U32) -> IO(Unit):
  match reset:
    case True{}:
      do IO<Unit>:
        log_err("bend-vmm: reset")
        _ : U32 <- H.Hvf.reexec()
        IO.die(Unit, 1, "bend-vmm: cannot restart")
    case False{}:
      do IO<Unit>:
        log_err("bend-vmm: stopped (" ++ U32.show(code) ++ ")")
        IO.exit(code)

def stopped(+code: U32) -> IO(Unit):
  stopped.reset(U32.is_eq(code, 1), code)

# Starts the control socket when --control names one.
@unsafe def control(none: Bool, path: String, +mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        +rc : U32 <- H.Hvf.ctl_listen(path)
        die_if(U32.is_ne(rc, 0), "cannot listen on the control socket (" ++ U32.show(rc) ++ ")")
        IO.spawn(Unit, ctl_loop(mc, done))

# Runs a machine: the vCPU loops of the given CPUs, console input and the
# control socket; ends when a vCPU stops the VM.
@unsafe def run_machine(+mc: Chan(M.Machine), +done: Chan(U32), +ctl: String, disp: String, cpus: +List<U32>) -> IO(Unit):
  do IO<Unit>:
    spawn_cpus(mc, done, cpus)
    display.start(display_of(disp), mc, done)
    IO.spawn(Unit, input_loop(mc, done))
    IO.spawn(Unit, vs_accept_loop(mc, done))
    control(String.is_empty(ctl), ctl, mc, done)
    got : Maybe<&1, U32> <- Chan.recv(U32, done)
    +code : U32 = Maybe.default(&1, U32, got, 2)
    stopped(code)

@unsafe def spawn_cpus(+mc: Chan(M.Machine), +done: Chan(U32), cpus: +List<U32>) -> IO(Unit):
  match cpus:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{c, rest}:
      do IO<Unit>:
        IO.spawn(Unit, vcpu_loop(c, mc, done))
        spawn_cpus(mc, done, rest)

@unsafe def start.go(cpus: U32, ctl: String, disp: String, kinds: +List<D.DevKind>, pc: U.U64, dtb: U.U64) -> IO(Unit):
  do IO<Unit>:
    rc : U32 <- H.Host.vcpu_create(0)
    die_if(U32.is_ne(rc, 0), "cannot create vCPU 0")
    boot_regs(0, pc, dtb)
    +mc : Chan(M.Machine) <- Chan.new(M.Machine, 1)
    put(mc, M.Machine.new(U32.to_nat(cpus), kinds))
    +done : Chan(U32) <- Chan.new(U32, 4)
    run_machine(mc, done, ctl, disp, [0])

@unsafe def start(o: Opts, kinds: +List<D.DevKind>, entry: U.U64 & U.U64) -> IO(Unit):
  match o:
    case Opts{k, i, p, c, m, cpus, d, sh, rs, ct, vk, dp, fw, nv}:
      match entry:
        case (pc, dtb):
          start.go(cpus, ct, dp, kinds, pc, dtb)

# Restore
# =======
#
# --restore FILE: the VMM starts with the options the snapshot was taken with
# (its devices must be reachable at the same paths), maps guest RAM from the
# file, decodes the machine, creates every vCPU the snapshot saved (their
# registers come back as they are created), restores the GIC, and runs the
# vCPUs that PSCI had on. Host sockets are gone, so the NAT starts empty.

def forget_net(m: M.Machine) -> M.Machine:
  match m:
    case M.Machine{ps, u, ui, ds, ls, r, ri, n, fl}:
      M.Machine{ps, u, ui, ds, ls, r, ri, Nt.Slirp.new(), fl}

def psci_on(m: M.Machine) -> +List<Bool>:
  match m:
    case M.Machine{Ps.PsciState{on}, u, ui, ds, ls, r, ri, n, fl}:
      on

# CPU indexes i (from i0) whose saved flag is set, created now; answers the
# ones PSCI has on.
@unsafe def restore_cpus(i: U32, saved: +List<U32>, +on: +List<Bool>) -> IO(+List<U32>):
  match saved:
    case Nil{}:
      IO.pure(+List<U32>, [])
    case Con{+flag, rest}:
      +i = i
      +now_on = Maybe.default(&2, Bool, List.head(&2, Bool, on), False{}) && U32.is_ne(flag, 0)
      do IO<+List<U32>>:
        _ : U32 <- restore_cpu(U32.is_ne(flag, 0), i)
        +more : +List<U32> <- restore_cpus((i + 1 : U32), rest, List.drop(&2, Bool, on, 1n))
        return Bool.pick(+List<U32>, now_on, i <> more, more)

@unsafe def restore_cpu(saved: Bool, i: U32) -> IO(U32):
  match saved:
    case True{}:
      H.Host.vcpu_create(i)
    case False{}:
      IO.pure(U32, 0)

@unsafe def restore.machine(got: Maybe<&2, M.Machine>, +o: Opts, kinds: +List<D.DevKind>) -> IO(Unit):
  match got:
    case None{}:
      IO.die(Unit, 1, "bend-vmm: the snapshot's machine state does not decode")
    case Some{m}:
      do IO<Unit>:
        +info : +List<U32> <- H.Hvf.snap_info()
        +m2 : M.Machine = forget_net(m)
        cpus : +List<U32> <- restore_cpus(0, List.drop(&2, U32, info, 2n), psci_on(m2))
        gic : U32 <- H.Hvf.snap_gic()
        die_if(U32.is_ne(gic, 0), "cannot restore the GIC state")
        +mc : Chan(M.Machine) <- Chan.new(M.Machine, 1)
        put(mc, m2)
        +done : Chan(U32) <- Chan.new(U32, 4)
        log_err("bend-vmm: restored")
        run_machine(mc, done, Opts.control(o), Opts.display(o), cpus)

# Options for a restore: the snapshot's own, plus this run's --control.
def restore.opts(saved: List<String>, now: Opts) -> Opts:
  match now:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
      Opts.set("--control", ct, Opts.parse(List.drop(&1, String, saved, 1n), Opts.default()))

# A UEFI guest's flash banks come back from the same firmware and variable
# files; bank 1 stays unmapped when the snapshot caught a flash command.
def restore.flash(none: Bool, +o: Opts) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      match o:
        case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv}:
          do IO<Unit>:
            +rc : U32 <- H.Hvf.fw_load(fw, nv)
            die_if(U32.is_ne(rc, 0), "cannot load the firmware (step " ++ U32.show(rc) ++ ")")

def restore.flash_mode(m: Maybe<&2, M.Machine>) -> IO(U32):
  match m:
    case None{}:
      IO.pure(U32, 0)
    case Some{mc}:
      H.Hvf.flash(3, Bool.to_u32(U32.is_zero(Pf.Pflash.mode(M.Machine.flash_of(mc)))), 0, [])

@unsafe def restore(path: String, now: Opts) -> IO(Unit):
  do IO<Unit>:
    +rc : U32 <- H.Hvf.snap_open(path)
    die_if(U32.is_ne(rc, 0), "cannot read the snapshot (" ++ U32.show(rc) ++ ")")
    saved : List<String> <- H.Hvf.snap_args()
    +o : Opts = restore.opts(saved, now)
    +vm : U32 <- H.Host.vm_init(Opts.mem(o), L.Layout.gicd_base(), L.Layout.gicr_base(), ram())
    die_if(U32.is_ne(vm, 0), "cannot create the VM (step " ++ U32.show(vm) ++ ")")
    display.map(display_of(Opts.display(o)))
    restore.flash(String.is_empty(Opts.firmware(o)), o)
    +kinds : +List<D.DevKind> <- devices(o)
    ws : +List<U32> <- H.Hvf.snap_machine()
    +got : Maybe<&2, M.Machine> = Snap.Snap.decode(ws)
    _ : U32 <- restore.flash_mode(got)
    restore.machine(got, o, kinds)

@unsafe def boot_fresh(+o: Opts) -> IO(Unit):
  do IO<Unit>:
    +rc : U32 <- H.Host.vm_init(Opts.mem(o), L.Layout.gicd_base(), L.Layout.gicr_base(), ram())
    die_if(U32.is_ne(rc, 0), "cannot create the VM (step " ++ U32.show(rc) ++ ")")
    display.map(display_of(Opts.display(o)))
    +kinds : +List<D.DevKind> <- devices(o)
    entry : U.U64 & U.U64 <- boot(o, List.length(&2, D.DevKind, kinds))
    start(o, kinds, entry)

@unsafe def main.mode(fresh: Bool, +o: Opts) -> IO(Unit):
  match fresh:
    case True{}:
      boot_fresh(o)
    case False{}:
      restore(Opts.restore(o), o)

@unsafe def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    +o : Opts = Opts.parse(List.drop(&1, String, args, 1n), Opts.default())
    main.mode(String.is_empty(Opts.restore(o)), o)
