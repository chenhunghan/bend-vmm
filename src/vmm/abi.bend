import Base
import ../lib/u64.bend as U

# The boundary between the pure VMM and the macOS host layer (host/).
#
# The host runs a vCPU until it exits and hands the exit over as a RawExit.
# The pure side answers with a Vm program: a description of the effects it
# wants (read guest memory, set a register, print to the console, ...). The
# host interprets that program against Hypervisor.framework; tests interpret
# it against a pure memory (src/vmm/sim.bend). Nothing in src/ performs IO.

# Register numbers used by VmSetReg: 0..30 are X0..X30, 31 is PC.
def Reg.pc() -> U32:
  31

# A vCPU exit as Hypervisor.framework reports it, decoded no further.
type RawExit is Data:
  # An exception to EL2. esr is ESR_EL2, far is FAR_EL2, ipa the faulting
  # guest physical address (data and instruction aborts). x0..x3 are the
  # guest's X0..X3 at the exit (HVC/SMC arguments). xt is the value of the
  # register ESR.ISS.SRT names when ISV is set (a store's data), else zero.
  Exception{esr: U.U64, far: U.U64, ipa: U.U64, x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64, xt: U.U64}
  # The guest's virtual timer fired (HV_EXIT_REASON_VTIMER_ACTIVATED).
  VtimerActivated{}
  # hv_vcpus_exit forced the exit.
  Canceled{}
  # Any other HV_EXIT_REASON value.
  UnknownExit{reason: U32}

type PowerOp is Data:
  PowerOff{}
  PowerReset{}

# Host network commands from the NAT (src/net/nat.bend). Connections are
# numbered by the NAT; addresses are IPv4 as U32 (10.0.2.2 = 167772674). The
# host maps 10.0.2.2 to its own loopback and 10.0.2.3 to its DNS resolver.
type NetCmd is Data:
  TcpConnect{conn: U32, ip: U32, port: U32}
  TcpSend{conn: U32, bytes: +List<U32>}
  # Half-close: no more data from the guest (shutdown(SHUT_WR)).
  TcpShutdown{conn: U32}
  # Full close: forget the connection.
  TcpClose{conn: U32}
  # A datagram from guest port sport to ip:port.
  UdpSend{sport: U32, ip: U32, port: U32, bytes: +List<U32>}

# What the host reports back to the NAT.
type NetEvent is Data:
  TcpConnected{conn: U32}
  TcpRefused{conn: U32}
  TcpData{conn: U32, bytes: +List<U32>}
  # The remote side finished sending (EOF).
  TcpEof{conn: U32}
  # A datagram from ip:port to guest port dport.
  UdpData{ip: U32, port: U32, dport: U32, bytes: +List<U32>}

# A program of host effects that ends with a value of type A. Each effect
# applies to the vCPU whose exit is being handled, unless it names a cpu.
type Vm<-A: Type> is Type:
  VmRet{value: A}
  # Reads len bytes of guest memory at addr, continues with them.
  VmRead{addr: U.U64, len: U32, k: +List<U32> -> Vm<A>}
  # Writes bytes to guest memory at addr.
  VmWrite{addr: U.U64, bytes: +List<U32>, next: Vm<A>}
  # Sets a register of the exiting vCPU (see Reg).
  VmSetReg{reg: U32, value: U.U64, next: Vm<A>}
  # Moves the exiting vCPU's PC past the trapping instruction (PC += 4).
  VmAdvancePc{next: Vm<A>}
  # Writes bytes to the VM's console (the host's stdout).
  VmConsole{bytes: +List<U32>, next: Vm<A>}
  # Sets the level of a GIC SPI by its INTID (32..1019).
  VmIrq{intid: U32, level: Bool, next: Vm<A>}
  # Powers the VM off or resets it, after the program ends.
  VmPower{op: PowerOp, next: Vm<A>}
  # PSCI CPU_ON: starts cpu at entry with X0 = ctx.
  VmCpuOn{cpu: U32, entry: U.U64, ctx: U.U64, next: Vm<A>}
  # A diagnostic line for the host's log (stderr), not the guest console.
  VmLog{msg: String, next: Vm<A>}
  # Reads len bytes of disk image `disk` at byte offset; short at its end.
  VmDiskRead{disk: U32, offset: U.U64, len: U32, k: +List<U32> -> Vm<A>}
  # Writes bytes to disk image `disk` at byte offset.
  VmDiskWrite{disk: U32, offset: U.U64, bytes: +List<U32>, next: Vm<A>}
  # len bytes from the host's entropy source.
  VmRandom{len: U32, k: +List<U32> -> Vm<A>}
  # Wall-clock time: seconds since the Unix epoch.
  VmNow{k: U.U64 -> Vm<A>}
  # Makes earlier writes to disk image `disk` durable (fsync).
  VmDiskFlush{disk: U32, next: Vm<A>}
  # A network command for the host's sockets.
  VmNet{cmd: NetCmd, next: Vm<A>}

# Device code is written in Op, a continuation monad over Vm: its bind needs
# no recursion, so `do Op<R, A>:` blocks pass Bend's termination check. R is
# the type the whole exit handler finally returns (usually the machine).
type Op<-R: Type, -A: Type> is Type:
  Op{run: (A -> Vm<R>) -> Vm<R>}

def Op.pure(-R: Type, -A: Type, x: A) -> Op<R, A>:
  Op{k => k(x)}

def Op.run(-R: Type, -A: Type, m: Op<R, A>, k: A -> Vm<R>) -> Vm<R>:
  match m:
    case Op{run}:
      run(k)

def Op.bind(-R: Type, -A: Type, -B: Type, m: Op<R, A>, f: A -> Op<R, B>) -> Op<R, B>:
  Op{k => Op.run(R, A, m, a => Op.run(R, B, f(a), k))}

# Ends an Op whose result is the final value.
def Op.finish(-R: Type, m: Op<R, R>) -> Vm<R>:
  Op.run(R, R, m, x => VmRet{x})

def Op.read(-R: Type, addr: U.U64, len: U32) -> Op<R, +List<U32>>:
  Op{k => VmRead{addr, len, k}}

def Op.write(-R: Type, addr: U.U64, bytes: +List<U32>) -> Op<R, Unit>:
  Op{k => VmWrite{addr, bytes, k(Unit{})}}

def Op.set_reg(-R: Type, reg: U32, value: U.U64) -> Op<R, Unit>:
  Op{k => VmSetReg{reg, value, k(Unit{})}}

def Op.advance_pc(-R: Type) -> Op<R, Unit>:
  Op{k => VmAdvancePc{k(Unit{})}}

def Op.console(-R: Type, bytes: +List<U32>) -> Op<R, Unit>:
  Op{k => VmConsole{bytes, k(Unit{})}}

def Op.irq(-R: Type, intid: U32, level: Bool) -> Op<R, Unit>:
  Op{k => VmIrq{intid, level, k(Unit{})}}

def Op.power(-R: Type, op: PowerOp) -> Op<R, Unit>:
  Op{k => VmPower{op, k(Unit{})}}

def Op.cpu_on(-R: Type, cpu: U32, entry: U.U64, ctx: U.U64) -> Op<R, Unit>:
  Op{k => VmCpuOn{cpu, entry, ctx, k(Unit{})}}

def Op.log(-R: Type, msg: String) -> Op<R, Unit>:
  Op{k => VmLog{msg, k(Unit{})}}

def Op.disk_read(-R: Type, disk: U32, offset: U.U64, len: U32) -> Op<R, +List<U32>>:
  Op{k => VmDiskRead{disk, offset, len, k}}

def Op.disk_write(-R: Type, disk: U32, offset: U.U64, bytes: +List<U32>) -> Op<R, Unit>:
  Op{k => VmDiskWrite{disk, offset, bytes, k(Unit{})}}

def Op.random(-R: Type, len: U32) -> Op<R, +List<U32>>:
  Op{k => VmRandom{len, k}}

def Op.now(-R: Type) -> Op<R, U.U64>:
  Op{k => VmNow{k}}

def Op.disk_flush(-R: Type, disk: U32) -> Op<R, Unit>:
  Op{k => VmDiskFlush{disk, k(Unit{})}}

def Op.net(-R: Type, cmd: NetCmd) -> Op<R, Unit>:
  Op{k => VmNet{cmd, k(Unit{})}}
