import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V

# Hypervisor.framework effects (host/hvf.c) and their typed wrappers.
# Words cross the boundary as U32; 64-bit values as (hi, lo) pairs.

def Hvf.init(ram_mb: U32, gicd_hi: U32, gicd_lo: U32, gicr_hi: U32, gicr_lo: U32, ram_hi: U32, ram_lo: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.load(path: String, gpa_hi: U32, gpa_lo: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.write(gpa_hi: U32, gpa_lo: U32, bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.read(gpa_hi: U32, gpa_lo: U32, len: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.vcpu(cpu: U32, op: U32, a_hi: U32, a_lo: U32, b_hi: U32, b_lo: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.irq(intid: U32, level: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.kick(cpu: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.reexec() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.file_size(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.out(bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stdin(max: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stdin_wait(max: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.random(len: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_open(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_size(disk: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_flush(disk: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.now() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_read(disk: U32, off_hi: U32, off_lo: U32, len: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_write(disk: U32, off_hi: U32, off_lo: U32, bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

# vCPU request codes (host/hvf.c).
def Op.create() -> U32:
  0
def Op.run() -> U32:
  1
def Op.set_reg() -> U32:
  2
def Op.get_reg() -> U32:
  3
def Op.set_vtimer_mask() -> U32:
  4

# Register numbers beyond V.Reg: 32 is CPSR.
def Reg.cpsr() -> U32:
  32

def Host.vm_init(ram_mb: U32, gicd: U.U64, gicr: U.U64, ram: U.U64) -> IO(U32):
  match gicd gicr ram:
    case U.U64{dh, dl} U.U64{rh, rl} U.U64{mh, ml}:
      Hvf.init(ram_mb, dh, dl, rh, rl, mh, ml)

def Host.load(path: String, gpa: U.U64) -> IO(U32):
  match gpa:
    case U.U64{h, l}:
      Hvf.load(path, h, l)

def Host.write(gpa: U.U64, bytes: +List<U32>) -> IO(U32):
  match gpa:
    case U.U64{h, l}:
      Hvf.write(h, l, bytes)

def Host.read(gpa: U.U64, len: U32) -> IO(+List<U32>):
  match gpa:
    case U.U64{h, l}:
      Hvf.read(h, l, len)

def Host.first(ws: +List<U32>) -> U32:
  Maybe.default(&2, U32, List.head(&2, U32, ws), 4294967295)

def Host.vcpu_create(cpu: U32) -> IO(U32):
  do IO<U32>:
    ws : +List<U32> <- Hvf.vcpu(cpu, Op.create(), 0, 0, 0, 0)
    return Host.first(ws)

def Host.set_reg(cpu: U32, reg: U32, v: U.U64) -> IO(U32):
  match v:
    case U.U64{h, l}:
      do IO<U32>:
        ws : +List<U32> <- Hvf.vcpu(cpu, Op.set_reg(), 0, reg, h, l)
        return Host.first(ws)

def Host.get_reg(cpu: U32, reg: U32) -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.vcpu(cpu, Op.get_reg(), 0, reg, 0, 0)
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}

def Host.vtimer_mask(cpu: U32, masked: U32) -> IO(U32):
  do IO<U32>:
    ws : +List<U32> <- Hvf.vcpu(cpu, Op.set_vtimer_mask(), 0, masked, 0, 0)
    return Host.first(ws)

# The i-th 64-bit value of an exit record (after the kind word).
def Host.word64(+ws: +List<U32>, i: Nat) -> U.U64:
  +at = Nat.add(1n, Nat.mul(i, 2n))
  U.U64{Host.first(List.drop(&2, U32, ws, at)), Host.first(List.drop(&2, U32, ws, Nat.add(at, 1n)))}

def Host.decode_exit.pick(is0: Bool, is1: Bool, is2: Bool, kind: U32, +ws: +List<U32>) -> V.RawExit:
  match is0 is1 is2:
    case True{} _ _:
      V.Exception{Host.word64(ws, 0n), Host.word64(ws, 1n), Host.word64(ws, 2n), Host.word64(ws, 3n), Host.word64(ws, 4n), Host.word64(ws, 5n), Host.word64(ws, 6n), Host.word64(ws, 7n)}
    case False{} True{} _:
      V.VtimerActivated{}
    case False{} False{} True{}:
      V.Canceled{}
    case False{} False{} False{}:
      V.UnknownExit{kind}

def Host.decode_exit.kind(+kind: U32, +ws: +List<U32>) -> V.RawExit:
  Host.decode_exit.pick(U32.is_eq(kind, 0), U32.is_eq(kind, 1), U32.is_eq(kind, 2), kind, ws)

# Decodes Hvf.vcpu(.., Op.run(), ..) words into a RawExit.
def Host.decode_exit(+ws: +List<U32>) -> V.RawExit:
  Host.decode_exit.kind(Host.first(ws), ws)

def Host.run(cpu: U32) -> IO(V.RawExit):
  do IO<V.RawExit>:
    +ws : +List<U32> <- Hvf.vcpu(cpu, Op.run(), 0, 0, 0, 0)
    return Host.decode_exit(ws)

def Host.disk_read(disk: U32, off: U.U64, len: U32) -> IO(+List<U32>):
  match off:
    case U.U64{h, l}:
      Hvf.disk_read(disk, h, l, len)

def Host.disk_write(disk: U32, off: U.U64, bytes: +List<U32>) -> IO(U32):
  match off:
    case U.U64{h, l}:
      Hvf.disk_write(disk, h, l, bytes)

def Host.disk_size(disk: U32) -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.disk_size(disk)
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}

def Host.now() -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.now()
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}
