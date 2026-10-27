import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ./abi.bend as V
import ./simfs.bend as F

# A pure interpreter for Vm programs: the stand-in for the macOS host in
# tests and proofs. Guest memory is one flat region of bytes at `base`; every
# other effect is recorded so a test can assert on it.

type SetReg is Data:
  SetReg{reg: U32, value: U.U64}

type Irq is Data:
  Irq{intid: U32, level: Bool}

type CpuOn is Data:
  CpuOn{cpu: U32, entry: U.U64, ctx: U.U64}

# Recorded lists are newest first. now is the wall clock VmNow answers (it does
# not advance by itself; tests set it with Sim.with_now). disk is disk image 0 (the only one the
# simulator models; others read as empty and ignore writes). Entropy is the
# counter sequence seed, seed+1, ... (mod 256), so tests can predict it. fs is
# the shared directory of share 0 (src/vmm/simfs.bend; an empty root unless a
# test sets it with Sim.with_fs); other shares answer ENOSYS. The UEFI flash
# reads as erased (0xFFFFFFFF) and ignores the rest.
type Sim is Data:
  Sim{
    base: U.U64,
    mem: +List<U32>,
    disk: +List<U32>,
    seed: U32,
    console: +List<U32>,
    regs: +List<SetReg>,
    pc_steps: Nat,
    irqs: +List<Irq>,
    power: +List<V.PowerOp>,
    cpu_ons: +List<CpuOn>,
    log: +List<String>,
    flushes: Nat,
    net: +List<V.NetCmd>,
    now: U.U64,
    fs: F.SimFs,
    vsock: +List<V.VsockCmd>
  }

# A machine with size bytes of zeroed memory at base.
def Sim.new(base: U.U64, size: Nat) -> Sim:
  Sim{base, B.Bytes.zeros(size), [], 0, [], [], 0n, [], [], [], [], 0n, [], U.U64{0, 0}, F.SimFs.new(), []}

# The same, with memory initialised to the given bytes.
def Sim.with_mem(base: U.U64, mem: +List<U32>) -> Sim:
  Sim{base, mem, [], 0, [], [], 0n, [], [], [], [], 0n, [], U.U64{0, 0}, F.SimFs.new(), []}

# Offset of addr in the region; addresses below base wrap and read as absent.
def Sim.offset(+base: U.U64, addr: U.U64) -> Nat:
  U32.to_nat(U.U64.lo(U.U64.sub(addr, base)))

def Sim.read(s: Sim, addr: U.U64, len: U32) -> +List<U32>:
  match s:
    case Sim{+base, +mem, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      B.Bytes.slice(mem, Sim.offset(base, addr), U32.to_nat(len))

def Sim.splice(mem: +List<U32>, +off: Nat, +bs: +List<U32>) -> +List<U32>:
  +mem = mem
  head = List.take(&2, U32, mem, off)
  tail = List.drop(&2, U32, mem, Nat.add(off, List.length(&2, U32, bs)))
  List.append(&2, U32, head, List.append(&2, U32, bs, tail))

def Sim.write(s: Sim, addr: U.U64, bytes: +List<U32>) -> Sim:
  match s:
    case Sim{+base, mem, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{base, Sim.splice(mem, Sim.offset(base, addr), bytes), d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.set_reg(s: Sim, reg: U32, value: U.U64) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, SetReg{reg, value} <> r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.advance_pc(s: Sim) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, 1n+p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.console(s: Sim, bytes: +List<U32>) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, List.append(&2, U32, c, bytes), r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.irq(s: Sim, intid: U32, level: Bool) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, Irq{intid, level} <> i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.power(s: Sim, op: V.PowerOp) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, op <> pw, co, l, fl, nt, nw, fs, vs}

def Sim.cpu_on(s: Sim, cpu: U32, entry: U.U64, ctx: U.U64) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, CpuOn{cpu, entry, ctx} <> co, l, fl, nt, nw, fs, vs}

def Sim.log(s: Sim, msg: String) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, msg <> l, fl, nt, nw, fs, vs}

# A disk with the given bytes as image 0.
def Sim.with_disk(s: Sim, disk: +List<U32>) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, disk, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.disk(s: Sim) -> +List<U32>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      d

def Sim.disk_read(s: Sim, disk: U32, offset: U.U64, len: U32) -> +List<U32>:
  match s:
    case Sim{b, m, +d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Bool.pick(+List<U32>, U32.is_zero(disk), B.Bytes.slice(d, U32.to_nat(U.U64.lo(offset)), U32.to_nat(len)), [])

# The bytes bs laid over the pieces of memory, in order.
def Sim.scatter(ss: +List<V.Iov>, s: Sim, +bs: +List<U32>) -> Sim:
  match ss:
    case Nil{}:
      s
    case V.Iov{a, +l} <> t:
      +n = U32.to_nat(l)
      Sim.scatter(t, Sim.write(s, a, List.take(&2, U32, bs, n)), List.drop(&2, U32, bs, n))

# The bytes of the pieces of memory, in order.
def Sim.gather(ss: +List<V.Iov>, +s: Sim) -> +List<U32>:
  match ss:
    case Nil{}:
      []
    case V.Iov{a, l} <> t:
      List.append(&2, U32, Sim.read(s, a, l), Sim.gather(t, s))

# bs cut or zero-padded to len bytes.
def Sim.fill(bs: +List<U32>, +len: U32) -> +List<U32>:
  +n = U32.to_nat(len)
  List.take(&2, U32, List.append(&2, U32, bs, B.Bytes.zeros(n)), n)

# VmDiskAlloc on the simulated disk: the first multiple of len at or past its
# end (disks stay below 4 GiB here).
def Sim.alloc_at(d: +List<U32>, +len: U32) -> U.U64:
  +n = U32.from_nat(List.length(&2, U32, d))
  +r = (n % len : U32)
  U.U64.from_u32(Bool.pick(U32, U32.is_zero(r), n, (n + (len - r : U32) : U32)))

# VmDiskToRam: the disk's bytes, zero-padded to the pieces' length, laid
# over them.
def Sim.disk_to_ram(+s: Sim, disk: U32, offset: U.U64, +iovs: +List<V.Iov>) -> Sim:
  +len = V.Iov.total(iovs)
  +n = U32.to_nat(len)
  bs = List.take(&2, U32, List.append(&2, U32, Sim.disk_read(s, disk, offset, len), B.Bytes.zeros(n)), n)
  Sim.scatter(iovs, s, bs)

def Sim.disk_write.go(zero: Bool, s: Sim, offset: U.U64, bytes: +List<U32>) -> Sim:
  match zero:
    case False{}:
      s
    case True{}:
      match s:
        case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
          Sim{b, m, Sim.splice(d, U32.to_nat(U.U64.lo(offset)), bytes), sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.disk_write(s: Sim, disk: U32, offset: U.U64, bytes: +List<U32>) -> Sim:
  Sim.disk_write.go(U32.is_zero(disk), s, offset, bytes)

def Sim.entropy(n: Nat, +x: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      (x .&. 255 : U32) <> Sim.entropy(p, (x + 1 : U32))

# The next len entropy bytes.
def Sim.random(s: Sim, len: U32) -> +List<U32>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim.entropy(U32.to_nat(len), sd)

# The state after drawing len entropy bytes.
def Sim.random_next(s: Sim, len: U32) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, (sd + len : U32), c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.flush(s: Sim) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, l, 1n+fl, nt, nw, fs, vs}

def Sim.net_cmd(s: Sim, cmd: V.NetCmd) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, cmd <> nt, nw, fs, vs}

def Sim.now(s: Sim) -> U.U64:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      nw

# The wall clock VmNow answers.
def Sim.with_now(s: Sim, now: U.U64) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, now, fs, vs}

def Sim.vsock_cmd(s: Sim, cmd: V.VsockCmd) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, cmd <> vs}

# Vsock commands the program issued, newest first.
def Sim.vsock(s: Sim) -> +List<V.VsockCmd>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      vs

def Sim.flushes(s: Sim) -> Nat:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      fl

def Sim.net(s: Sim) -> +List<V.NetCmd>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      nt

# The shared directory of share 0.
def Sim.fs(s: Sim) -> F.SimFs:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      fs

def Sim.with_fs(s: Sim, fs: F.SimFs) -> Sim:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, old, vs}:
      Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}

def Sim.fs_op.fin(s: Sim, r: F.SimFs & V.FsResult) -> Sim & V.FsResult:
  match r:
    case (fs, res):
      (Sim.with_fs(s, fs), res)

# FsReadRam: the bytes FsRead answered go over the pieces of memory,
# answered as their count.
def Sim.fs_read_ram(s: Sim, iovs: +List<V.Iov>, r: F.SimFs & V.FsResult) -> Sim & V.FsResult:
  match r:
    case (fs, res):
      match res:
        case V.FsBytes{+bs}:
          (Sim.with_fs(Sim.scatter(iovs, s, bs), fs), V.FsCount{U32.from_nat(List.length(&2, U32, bs))})
        case res:
          (Sim.with_fs(s, fs), res)

# Applies op to the filesystem fs; s holds an empty one meanwhile. The
# guest-memory operations go through memory and FsRead or FsWrite.
def Sim.fs_apply(+s: Sim, fs: F.SimFs, op: V.FsOp) -> Sim & V.FsResult:
  match op:
    case V.FsReadRam{p, off, +iovs}:
      Sim.fs_read_ram(s, iovs, F.SimFs.apply(fs, V.FsRead{p, off, V.Iov.total(iovs)}))
    case V.FsWriteRam{p, off, iovs}:
      Sim.fs_op.fin(s, F.SimFs.apply(fs, V.FsWrite{p, off, Sim.gather(iovs, s)}))
    case op:
      Sim.fs_op.fin(s, F.SimFs.apply(fs, op))

def Sim.fs_op.go(zero: Bool, s: Sim, op: V.FsOp) -> Sim & V.FsResult:
  match zero:
    case False{}:
      # Only share 0 is simulated: ENOSYS (78 on macOS).
      (s, V.FsErr{78})
    case True{}:
      match s:
        case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
          Sim.fs_apply(Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, F.SimFs.new(), vs}, fs, op)

# Applies a filesystem operation of share sh: the new state and the answer.
def Sim.fs_op(s: Sim, sh: U32, op: V.FsOp) -> Sim & V.FsResult:
  Sim.fs_op.go(U32.is_zero(sh), s, op)

def Sim.fs_fst(r: Sim & V.FsResult) -> Sim:
  match r:
    case (s, res):
      s

def Sim.fs_snd(r: Sim & V.FsResult) -> V.FsResult:
  match r:
    case (s, res):
      res

# The state after a filesystem operation.
def Sim.fs_next(s: Sim, sh: U32, op: V.FsOp) -> Sim:
  Sim.fs_fst(Sim.fs_op(s, sh, op))

# The answer to a filesystem operation.
def Sim.fs_answer(s: Sim, sh: U32, op: V.FsOp) -> V.FsResult:
  Sim.fs_snd(Sim.fs_op(s, sh, op))

# Runs a Vm program for at most fuel steps. None when the fuel runs out.
def Sim.run(fuel: Nat, -A: Type, s: Sim, m: V.Vm<A>) -> Maybe<&1, Sim & A>:
  match fuel:
    case 0n:
      None{}
    case 1n+f:
      match m:
        case V.VmRet{x}:
          Some{(s, x)}
        case V.VmRead{+a, n, k}:
          +s = s
          Sim.run(f, A, s, k(Sim.read(s, a, n)))
        case V.VmWrite{a, bs, next}:
          Sim.run(f, A, Sim.write(s, a, bs), next)
        case V.VmSetReg{r, v, next}:
          Sim.run(f, A, Sim.set_reg(s, r, v), next)
        case V.VmAdvancePc{next}:
          Sim.run(f, A, Sim.advance_pc(s), next)
        case V.VmConsole{bs, next}:
          Sim.run(f, A, Sim.console(s, bs), next)
        case V.VmIrq{i, l, next}:
          Sim.run(f, A, Sim.irq(s, i, l), next)
        case V.VmPower{op, next}:
          Sim.run(f, A, Sim.power(s, op), next)
        case V.VmCpuOn{c, e, x, next}:
          Sim.run(f, A, Sim.cpu_on(s, c, e, x), next)
        case V.VmLog{msg, next}:
          Sim.run(f, A, Sim.log(s, msg), next)
        case V.VmDiskRead{+dk, +off, n, k}:
          +s = s
          Sim.run(f, A, s, k(Sim.disk_read(s, dk, off, n)))
        case V.VmDiskWrite{dk, off, bs, next}:
          Sim.run(f, A, Sim.disk_write(s, dk, off, bs), next)
        case V.VmRandom{+n, k}:
          +s = s
          Sim.run(f, A, Sim.random_next(s, n), k(Sim.random(s, n)))
        case V.VmNow{k}:
          +s = s
          Sim.run(f, A, s, k(Sim.now(s)))
        case V.VmDiskFlush{dk, next}:
          Sim.run(f, A, Sim.flush(s), next)
        case V.VmNet{cmd, next}:
          Sim.run(f, A, Sim.net_cmd(s, cmd), next)
        case V.VmVsock{cmd, next}:
          Sim.run(f, A, Sim.vsock_cmd(s, cmd), next)
        case V.VmFlash{cmd, k}:
          Sim.run(f, A, s, k(4294967295))
        case V.VmFs{+sh, +op, k}:
          +s = s
          Sim.run(f, A, Sim.fs_next(s, sh, op), k(Sim.fs_answer(s, sh, op)))
        case V.VmDiskToRam{dk, off, iovs, next}:
          Sim.run(f, A, Sim.disk_to_ram(s, dk, off, iovs), next)
        case V.VmRamToDisk{dk, off, iovs, next}:
          +s = s
          Sim.run(f, A, Sim.disk_write(s, dk, off, Sim.gather(iovs, s)), next)
        case V.VmZeroRam{+iovs, next}:
          Sim.run(f, A, Sim.scatter(iovs, s, B.Bytes.zeros(U32.to_nat(V.Iov.total(iovs)))), next)
        case V.VmDiskAlloc{dk, +len, k}:
          +s = s
          +at = Sim.alloc_at(Sim.disk(s), len)
          Sim.run(f, A, Sim.disk_write(s, dk, at, B.Bytes.zeros(U32.to_nat(len))), k(at))
        case V.VmDiskCopy{sd, so, dd, doff, +len, next}:
          +s = s
          Sim.run(f, A, Sim.disk_write(s, dd, doff, Sim.fill(Sim.disk_read(s, sd, so, len), len)), next)
        case V.VmInflateToRam{dk, off, clen, skip, +iovs, next}:
          # no inflater here: zeros
          Sim.run(f, A, Sim.scatter(iovs, s, B.Bytes.zeros(U32.to_nat(V.Iov.total(iovs)))), next)
        case V.VmInflateToDisk{dk, off, clen, dd, doff, skip, +len, next}:
          Sim.run(f, A, Sim.disk_write(s, dd, doff, B.Bytes.zeros(U32.to_nat(len))), next)
        case V.VmStage{iovs, k}:
          # the simulator stages everything in slot 0
          Sim.run(f, A, s, k(0))
        case V.VmNetToRam{conn, +iovs, next}:
          # the simulator's host holds 120 ('x') in every byte it buffered
          Sim.run(f, A, Sim.scatter(iovs, s, List.replicate(U32, U32.to_nat(V.Iov.total(iovs)), 120)), next)

# Runs an Op to completion with a generous step budget.
def Sim.exec(-A: Type, s: Sim, m: V.Op<A, A>) -> Maybe<&1, Sim & A>:
  Sim.run(100000n, A, s, V.Op.finish(A, m))

def Sim.mem(s: Sim) -> +List<U32>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      m

def Sim.console_out(s: Sim) -> +List<U32>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      c

def Sim.regs(s: Sim) -> +List<SetReg>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      r

def Sim.pc_steps(s: Sim) -> Nat:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      p

def Sim.irqs(s: Sim) -> +List<Irq>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      i

def Sim.powers(s: Sim) -> +List<V.PowerOp>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      pw

def Sim.logs(s: Sim) -> +List<String>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      l

def Sim.cpu_ons(s: Sim) -> +List<CpuOn>:
  match s:
    case Sim{b, m, d, sd, c, r, p, i, pw, co, l, fl, nt, nw, fs, vs}:
      co
