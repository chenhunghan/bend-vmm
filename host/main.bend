import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/layout.bend as L
import ../src/vmm/machine.bend as M
import ../src/virtio/device.bend as D
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

type Opts is Data:
  Opts{kernel: String, initrd: String, payload: String, cmdline: String, mem: U32, cpus: U32, disk: String}

def Opts.default() -> Opts:
  Opts{"", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 512, 1, ""}

def Opts.mem(o: Opts) -> U32:
  match o:
    case Opts{k, i, p, c, m, n, d}:
      m

def Opts.disk(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d}:
      d

def Opts.kernel(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d}:
      k

def Opts.num(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def Opts.set(+flag: String, +v: String, o: Opts) -> Opts:
  match o:
    case Opts{k, i, p, c, +m, +n, d}:
      Opts{
        Bool.pick(String, String.eq(flag, "--kernel"), v, k),
        Bool.pick(String, String.eq(flag, "--initrd"), v, i),
        Bool.pick(String, String.eq(flag, "--payload"), v, p),
        Bool.pick(String, String.eq(flag, "--cmdline"), v, c),
        Bool.pick(U32, String.eq(flag, "--mem"), Opts.num(v, m), m),
        Bool.pick(U32, String.eq(flag, "--cpus"), Opts.num(v, n), n),
        Bool.pick(String, String.eq(flag, "--disk"), v, d)
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
        IO.print_err("[vmm] " ++ msg)
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
      # Wired to host sockets once the NAT lands (src/net/nat.bend).
      interp(cpu, mc, done, A, next)
    case V.VmFs{sh, op, k}:
      do IO<A>:
        r : V.FsResult <- Fs.Host.fs(sh, op)
        interp(cpu, mc, done, A, k(r))

# Bytes typed on the host console go to the UART: this loop parks on stdin
# and hands each chunk to the machine. An idle guest may never exit (the GIC
# and timer live in Hypervisor.framework), so input cannot wait for exits.
@unsafe def input_loop.go(eof: Bool, +mc: Chan(M.Machine), +done: Chan(U32), bs: +List<U32>) -> IO(Unit):
  match eof:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        m0 : M.Machine <- take(mc)
        m1 : M.Machine <- interp(0, mc, done, M.Machine, M.Machine.input(m0, bs))
        put(mc, m1)
        input_loop(mc, done)

@unsafe def input_loop(+mc: Chan(M.Machine), +done: Chan(U32)) -> IO(Unit):
  do IO<Unit>:
    +bs : +List<U32> <- H.Hvf.stdin_wait(64)
    input_loop.go(List.is_empty(&2, U32, bs), mc, done, bs)

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

# Devices: virtio-rng in slot 0, plus a virtio-blk in slot 1 with --disk.
def devices.open(+id: U32) -> IO(+List<D.DevKind>):
  do IO<+List<D.DevKind>>:
    die_if(U32.is_eq(id, err()), "cannot open the disk image")
    size : U.U64 <- H.Host.disk_size(id)
    return [D.RngKind{}, D.BlkKind{id, U.U64.shr(9n, size)}]

def devices(none: Bool, disk: String) -> IO(+List<D.DevKind>):
  match none:
    case True{}:
      IO.pure(+List<D.DevKind>, [D.RngKind{}])
    case False{}:
      do IO<+List<D.DevKind>>:
        id : U32 <- H.Hvf.disk_open(disk)
        devices.open(id)

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
    case I.Layout{kernel, kend, +dtb, +rd, rd_end} Opts{k, initrd, p, cmdline, +mem, cpus, d}:
      +has_rd = U32.is_ne(ilen, 0)
      do IO<U.U64 & U.U64>:
        cfg : T.DtbCfg = T.DtbCfg{U32.to_nat(cpus), ram_bytes(mem), cmdline, initrd_of(has_rd, rd, rd_end), nslots}
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
    case Opts{kernel, +initrd, p, c, +mem, cpus, d}:
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
    case Opts{k, i, payload, cmdline, +mem, cpus, d}:
      +dtb = U.U64.add_u32(ram(), 67108864)
      do IO<U.U64 & U.U64>:
        cfg : T.DtbCfg = T.DtbCfg{U32.to_nat(cpus), ram_bytes(mem), cmdline, None{}, nslots}
        n : U32 <- H.Host.load(payload, ram())
        die_if(U32.is_eq(n, err()), "cannot load the payload")
        _ : U32 <- H.Host.write(dtb, T.Dtb.build(cfg))
        return (ram(), dtb)

def boot(payload: Bool, o: Opts, nslots: Nat) -> IO(U.U64 & U.U64):
  match payload:
    case True{}:
      boot_payload(o, nslots)
    case False{}:
      boot_linux(o, nslots)

# Stop code 1 is a guest reset: start over in a fresh process.
def stopped.reset(reset: Bool, +code: U32) -> IO(Unit):
  match reset:
    case True{}:
      do IO<Unit>:
        IO.print_err("bend-vmm: reset")
        _ : U32 <- H.Hvf.reexec()
        IO.die(Unit, 1, "bend-vmm: cannot restart")
    case False{}:
      do IO<Unit>:
        IO.print_err("bend-vmm: stopped (" ++ U32.show(code) ++ ")")
        IO.exit(code)

def stopped(+code: U32) -> IO(Unit):
  stopped.reset(U32.is_eq(code, 1), code)

@unsafe def start.go(cpus: U32, kinds: +List<D.DevKind>, pc: U.U64, dtb: U.U64) -> IO(Unit):
  do IO<Unit>:
    rc : U32 <- H.Host.vcpu_create(0)
    die_if(U32.is_ne(rc, 0), "cannot create vCPU 0")
    boot_regs(0, pc, dtb)
    +mc : Chan(M.Machine) <- Chan.new(M.Machine, 1)
    put(mc, M.Machine.new(U32.to_nat(cpus), kinds))
    +done : Chan(U32) <- Chan.new(U32, 4)
    IO.spawn(Unit, vcpu_loop(0, mc, done))
    IO.spawn(Unit, input_loop(mc, done))
    got : Maybe<&1, U32> <- Chan.recv(U32, done)
    +code : U32 = Maybe.default(&1, U32, got, 2)
    stopped(code)

@unsafe def start(o: Opts, kinds: +List<D.DevKind>, entry: U.U64 & U.U64) -> IO(Unit):
  match o:
    case Opts{k, i, p, c, m, cpus, d}:
      match entry:
        case (pc, dtb):
          start.go(cpus, kinds, pc, dtb)

@unsafe def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    +o : Opts = Opts.parse(List.drop(&1, String, args, 1n), Opts.default())
    +rc : U32 <- H.Host.vm_init(Opts.mem(o), L.Layout.gicd_base(), L.Layout.gicr_base(), ram())
    die_if(U32.is_ne(rc, 0), "cannot create the VM (step " ++ U32.show(rc) ++ ")")
    +kinds : +List<D.DevKind> <- devices(String.is_empty(Opts.disk(o)), Opts.disk(o))
    entry : U.U64 & U.U64 <- boot(String.is_empty(Opts.kernel(o)), o, List.length(&2, D.DevKind, kinds))
    start(o, kinds, entry)
