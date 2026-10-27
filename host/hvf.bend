import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V

# Hypervisor.framework effects (host/hvf.c) and their typed wrappers.
# Words cross the boundary as U32; 64-bit values as (hi, lo) pairs.

def Hvf.init(ram_mb: U32, gicd_hi: U32, gicd_lo: U32, gicr_hi: U32, gicr_lo: U32, ram_hi: U32, ram_lo: U32, cpus: U32) -> IO(U32):
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

def Hvf.vcpu_queue(cpu: U32, op: U32, reg: U32, hi: U32, lo: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.irq(intid: U32, level: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.kick(cpu: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.set_args(bytes: +List<U32>) -> IO(U32):
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

def Hvf.out_flush() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stdin(max: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stdin_tty() -> IO(U32):
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

def Hvf.disk_copy(disk: U32, dir: U32, off_hi: U32, off_lo: U32, iovs: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.zero_ram(iovs: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_alloc(disk: U32, len: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.disk_xcopy(src: U32, soff_hi: U32, soff_lo: U32, dst: U32, doff_hi: U32, doff_lo: U32, len: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.inflate_ram(disk: U32, off_hi: U32, off_lo: U32, clen: U32, skip: U32, iovs: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.inflate_disk(disk: U32, off_hi: U32, off_lo: U32, clen: U32, dst: U32, doff_hi: U32, doff_lo: U32, skip: U32, len: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

# Host sockets for the NAT (see host/hvf.c, "Network").
def Hvf.set_dns(ip: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.dns() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_connect(conn: U32, ip: U32, port: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_wait(conn: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_recv(conn: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_fill(conn: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.net_copy(conn: U32, iovs: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stage(iovs: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.stage_drop(slot: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_send_staged(conn: U32, slot: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_send(conn: U32, bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_shutdown(conn: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.tcp_close(conn: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.udp_send(sport: U32, ip: U32, port: U32, bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.udp_recv(sport: U32) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

# Shared directories for virtio-9p (host/fs.bend wraps these).
def Hvf.share_open(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.fs(share: U32, op: U32, path: String, path2: String, a_hi: U32, a_lo: U32, b: U32, bytes: +List<U32>) -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

# Pause, snapshots and restore (host/hvf.c).
def Hvf.pause() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.resume() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.pause_state() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_write(path: String, words: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_open(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_info() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_args() -> IO(List<String>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_machine() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.snap_gic() -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

# The control socket (host/hvf.c).
def Hvf.ctl_listen(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.ctl_next() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.ctl_reply(text: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

# vsock over Unix sockets (host/hvf.c). Sockets share the tcp_* table under
# the key conn XOR 0x40000000.
def Hvf.unix_connect(key: U32, path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.vsock_listen(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.vsock_base() -> IO(String):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.vsock_accept() -> IO(+List<U32>):
  import "./hvf.c"
  import "./hvf.js"

# UEFI flash (host/hvf.c): the firmware and variable banks.
def Hvf.fw_load(code: String, vars: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.flash(op: U32, a: U32, b: U32, bytes: +List<U32>) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

# The framebuffer and its window (host/hvf.c).
def Hvf.fb_init(width: U32, height: U32) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.fb_dump(path: String) -> IO(U32):
  import "./hvf.c"
  import "./hvf.js"

def Hvf.fb_present(window: Window) -> IO(Window & List<Event>):
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
def Op.advance_pc() -> U32:
  5

# Register numbers beyond V.Reg: 32 is CPSR.
def Reg.cpsr() -> U32:
  32

def Host.vm_init(ram_mb: U32, gicd: U.U64, gicr: U.U64, ram: U.U64, cpus: U32) -> IO(U32):
  match gicd gicr ram:
    case U.U64{dh, dl} U.U64{rh, rl} U.U64{mh, ml}:
      Hvf.init(ram_mb, dh, dl, rh, rl, mh, ml, cpus)

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

# Queued: applied by the vCPU thread before its next request.
def Host.set_reg(cpu: U32, reg: U32, v: U.U64) -> IO(U32):
  match v:
    case U.U64{h, l}:
      Hvf.vcpu_queue(cpu, Op.set_reg(), reg, h, l)

# Queued, like Host.set_reg: PC += 4.
def Host.advance_pc(cpu: U32) -> IO(U32):
  Hvf.vcpu_queue(cpu, Op.advance_pc(), 0, 0, 0)

def Host.get_reg(cpu: U32, reg: U32) -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.vcpu(cpu, Op.get_reg(), 0, reg, 0, 0)
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}

def Host.vtimer_mask(cpu: U32, masked: U32) -> IO(U32):
  do IO<U32>:
    ws : +List<U32> <- Hvf.vcpu(cpu, Op.set_vtimer_mask(), 0, masked, 0, 0)
    return Host.first(ws)

# An exit record: [kind, esr, far, ipa, x0, x1, x2, x3, xt], each 64-bit
# value as (hi, lo). One pattern match decodes it (walking the list per field
# was the hottest code on the exit path).
def Host.exception(ws: +List<U32>) -> V.RawExit:
  match ws:
    case Con{eh, Con{el, Con{fh, Con{fl, Con{ih, Con{il, Con{ah, Con{al, Con{bh, Con{bl, Con{ch, Con{cl, Con{dh, Con{dl, Con{th, Con{tl, rest}}}}}}}}}}}}}}}}:
      V.Exception{U.U64{eh, el}, U.U64{fh, fl}, U.U64{ih, il}, U.U64{ah, al}, U.U64{bh, bl}, U.U64{ch, cl}, U.U64{dh, dl}, U.U64{th, tl}}
    case _:
      V.UnknownExit{4294967295}

def Host.decode_exit.kind(is0: Bool, is1: Bool, is2: Bool, kind: U32, rest: +List<U32>) -> V.RawExit:
  match is0 is1 is2:
    case True{} _ _:
      Host.exception(rest)
    case False{} True{} _:
      V.VtimerActivated{}
    case False{} False{} True{}:
      V.Canceled{}
    case False{} False{} False{}:
      V.UnknownExit{kind}

# Decodes Hvf.vcpu(.., Op.run(), ..) words into a RawExit.
def Host.decode_exit(ws: +List<U32>) -> V.RawExit:
  match ws:
    case Nil{}:
      V.UnknownExit{4294967295}
    case Con{+kind, rest}:
      Host.decode_exit.kind(U32.is_eq(kind, 0), U32.is_eq(kind, 1), U32.is_eq(kind, 2), kind, rest)

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

# Pieces of guest memory as the host takes them: each addr (8 bytes) then
# len (4), little-endian.
def Host.iovs(xs: +List<V.Iov>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case V.Iov{a, l} <> t:
      List.append(&2, U32, B.Bytes.le64(a), List.append(&2, U32, B.Bytes.le32(l), Host.iovs(t)))

# Moves bytes between a disk and pieces of guest RAM on the host: dir 0 disk
# to RAM, 1 RAM to disk.
def Host.disk_copy(disk: U32, dir: U32, off: U.U64, iovs: +List<V.Iov>) -> IO(U32):
  match off:
    case U.U64{oh, ol}:
      Hvf.disk_copy(disk, dir, oh, ol, Host.iovs(iovs))

# Moves the bytes the host holds for TCP connection conn into pieces of
# guest RAM.
def Host.net_copy(conn: U32, iovs: +List<V.Iov>) -> IO(U32):
  Hvf.net_copy(conn, Host.iovs(iovs))

# Copies pieces of guest RAM into a staged slot on the host.
def Host.stage(iovs: +List<V.Iov>) -> IO(U32):
  Hvf.stage(Host.iovs(iovs))

def Host.disk_alloc(disk: U32, len: U32) -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.disk_alloc(disk, len)
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}

def Host.disk_xcopy(src: U32, soff: U.U64, dst: U32, doff: U.U64, len: U32) -> IO(U32):
  match soff doff:
    case U.U64{sh, sl} U.U64{dh, dl}:
      Hvf.disk_xcopy(src, sh, sl, dst, dh, dl, len)

def Host.inflate_ram(disk: U32, off: U.U64, clen: U32, skip: U32, iovs: +List<V.Iov>) -> IO(U32):
  match off:
    case U.U64{h, l}:
      Hvf.inflate_ram(disk, h, l, clen, skip, Host.iovs(iovs))

def Host.inflate_disk(disk: U32, off: U.U64, clen: U32, dst: U32, doff: U.U64, skip: U32, len: U32) -> IO(U32):
  match off doff:
    case U.U64{oh, ol} U.U64{dh, dl}:
      Hvf.inflate_disk(disk, oh, ol, clen, dst, dh, dl, skip, len)

def Host.disk_size(disk: U32) -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.disk_size(disk)
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}

def Host.now() -> IO(U.U64):
  do IO<U.U64>:
    +ws : +List<U32> <- Hvf.now()
    return U.U64{Host.first(ws), Host.first(List.drop(&2, U32, ws, 1n))}
