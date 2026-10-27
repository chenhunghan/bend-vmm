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

# Host file operations for virtio-9p (src/fs/p9.bend). Paths are relative
# to the shared directory, "" being its root, components separated by "/",
# never "." or ".." (the 9p server builds them from names it validated; the
# host refuses anything else). Times are seconds since the Unix epoch.
type FsOp is Data:
  FsStat{path: String}
  # Entries of a directory, in a stable order, from index `from` on, at most
  # `max` of them.
  FsList{path: String, from: U32, max: U32}
  FsRead{path: String, offset: U.U64, len: U32}
  FsWrite{path: String, offset: U.U64, bytes: +List<U32>}
  # Creates a regular file (mode: permission bits); fails if it exists.
  FsCreate{path: String, mode: U32}
  FsMkdir{path: String, mode: U32}
  # Removes a file, or an empty directory when dir is True.
  FsRemove{path: String, dir: Bool}
  FsRename{from: String, to: String}
  FsTruncate{path: String, size: U.U64}
  FsChmod{path: String, mode: U32}
  FsSymlink{path: String, target: String}
  FsReadlink{path: String}
  FsStatfs{}

# A file's attributes (lstat): mode is st_mode (type and permission bits).
type FsAttr is Data:
  FsAttr{mode: U32, uid: U32, gid: U32, nlink: U32, size: U.U64, ino: U.U64, blocks: U.U64, atime: U.U64, mtime: U.U64, ctime: U.U64}

# A directory entry: name, inode, and its type (DT_DIR 4, DT_REG 8, DT_LNK 10, ...).
type FsEntry is Data:
  FsEntry{name: String, ino: U.U64, kind: U32}

type FsResult is Data:
  # An errno (ENOENT 2, EACCES 13, EEXIST 17, ENOTDIR 20, EISDIR 21,
  # EINVAL 22, ENOSPC 28, ENOTEMPTY 66 on macOS, ...).
  FsErr{errno: U32}
  FsOk{}
  FsGotAttr{attr: FsAttr}
  FsBytes{bytes: +List<U32>}
  FsCount{n: U32}
  FsEntries{entries: +List<FsEntry>}
  FsLink{target: String}
  # statfs: block size, total, free and available blocks, total and free files.
  FsStatfsOk{bsize: U32, blocks: U.U64, bfree: U.U64, bavail: U.U64, files: U.U64, ffree: U.U64}

# Host commands from virtio-vsock (src/virtio/vsock.bend). Connections are
# numbered by the device for guest-initiated ones and by the host (from
# 2147483648 up) for host-initiated ones. The host maps guest port P on the
# host CID to the Unix socket "<--vsock path>_P" (Firecracker's convention).
type VsockCmd is Data:
  # The guest connects to host port `port`.
  VsConnect{conn: U32, port: U32}
  VsSend{conn: U32, bytes: +List<U32>}
  # The guest will send no more.
  VsShutdown{conn: U32}
  VsClose{conn: U32}
  # The guest accepted a host-initiated connection; the host answers its
  # client "OK <port>".
  VsAccepted{conn: U32, port: U32}

type VsockEvent is Data:
  VsConnected{conn: U32}
  VsRefused{conn: U32}
  VsData{conn: U32, bytes: +List<U32>}
  # The host side will send no more.
  VsEof{conn: U32}
  # A host client asks to connect to guest port `port` (it sent "CONNECT port").
  VsIncoming{conn: U32, port: U32}

# Host commands of the UEFI variable flash (src/dev/pflash.bend); offsets
# are within the bank.
type FlashCmd is Data:
  # Reads size bytes (a trapped read in read-array mode; little-endian).
  FlashRead{off: U32, size: U32}
  FlashWrite{off: U32, bytes: +List<U32>}
  # Sets len bytes to 0xFF.
  FlashErase{off: U32, len: U32}
  # Maps the bank into the guest read-only (on) or unmaps it.
  FlashMap{on: Bool}

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
  # A file operation on the shared directory (`share` numbers the --share).
  VmFs{share: U32, op: FsOp, k: FsResult -> Vm<A>}
  # A vsock command for the host's Unix sockets.
  VmVsock{cmd: VsockCmd, next: Vm<A>}
  # A flash command; continues with the value a FlashRead read (0 for the
  # others).
  VmFlash{cmd: FlashCmd, k: U32 -> Vm<A>}
  # Copies len bytes of disk image `disk` at byte offset into guest memory at
  # addr (zeros past the image's end), host to guest with no copy through
  # Bend. The host does nothing when the range leaves guest RAM.
  VmDiskToRam{disk: U32, offset: U.U64, addr: U.U64, len: U32, next: Vm<A>}
  # Copies len bytes of guest memory at addr to disk image `disk` at offset.
  VmRamToDisk{disk: U32, offset: U.U64, addr: U.U64, len: U32, next: Vm<A>}

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

def Op.disk_to_ram(-R: Type, disk: U32, offset: U.U64, addr: U.U64, len: U32) -> Op<R, Unit>:
  Op{k => VmDiskToRam{disk, offset, addr, len, k(Unit{})}}

def Op.ram_to_disk(-R: Type, disk: U32, offset: U.U64, addr: U.U64, len: U32) -> Op<R, Unit>:
  Op{k => VmRamToDisk{disk, offset, addr, len, k(Unit{})}}

def Op.random(-R: Type, len: U32) -> Op<R, +List<U32>>:
  Op{k => VmRandom{len, k}}

def Op.now(-R: Type) -> Op<R, U.U64>:
  Op{k => VmNow{k}}

def Op.disk_flush(-R: Type, disk: U32) -> Op<R, Unit>:
  Op{k => VmDiskFlush{disk, k(Unit{})}}

def Op.net(-R: Type, cmd: NetCmd) -> Op<R, Unit>:
  Op{k => VmNet{cmd, k(Unit{})}}

def Op.fs(-R: Type, share: U32, op: FsOp) -> Op<R, FsResult>:
  Op{k => VmFs{share, op, k}}

def Op.vsock(-R: Type, cmd: VsockCmd) -> Op<R, Unit>:
  Op{k => VmVsock{cmd, k(Unit{})}}

def Op.flash(-R: Type, cmd: FlashCmd) -> Op<R, U32>:
  Op{k => VmFlash{cmd, k}}
