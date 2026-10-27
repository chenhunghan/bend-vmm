import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/net/wire.bend as W
import ../src/net/nat.bend as N
import ../src/virtio/device.bend as D
import ../src/vmm/machine.bend as M
import ./t.bend as T

# The new devices wired into the machine, driven through Machine.on_exit,
# Machine.input and Machine.net_event on the simulator.
#
# The machine: slot 0 virtio-console (167772160, INTID 48), slot 1 virtio-net
# (167772672, INTID 49), slot 2 virtio-9p (167773184, INTID 50); the PL031 at
# 151060480 (INTID 34). Guest memory: 8192 bytes at 1073741824 (RAM). Queue g
# (0, 1 the console's, 2, 3 the net's, 4 the 9p's) has 8 entries: descriptors
# at RAM + g*512, available ring + 128, used ring + 256. Buffers from
# RAM + 4096. Every MMIO access is `str w1` (2474704960) or `ldr w1`
# (2474704896).

def w(x: U32) -> U.U64:
  U.U64{0, x}

def ram() -> U32:
  1073741824

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def slot(n: U32) -> U32:
  (167772160 + (n * 512 : U32) : U32)

def rtc() -> U32:
  151060480

def kinds() -> +List<D.DevKind>:
  [D.ConsoleKind{}, D.NetKind{N.Slirp.guest_mac()}, D.P9Kind{0, "share"}]

def machine() -> M.Machine:
  M.Machine.new(1n, kinds())

def mem() -> S.Sim:
  S.Sim.new(w(ram()), 8192n)

# Queue g's tables.
def qdesc(+g: U32) -> U32:
  (ram() + (g * 512 : U32) : U32)

def qavail(+g: U32) -> U32:
  (qdesc(g) + 128 : U32)

def qused(+g: U32) -> U32:
  (qdesc(g) + 256 : U32)

# A step: an MMIO write or read exit, bytes typed on the host console, a
# network event from the host, or the guest writing its memory.
type Ev is Data:
  Wr{addr: U32, v: U32}
  Rd{addr: U32}
  Typed{bytes: +List<U32>}
  Host{ev: V.NetEvent}
  Poke{addr: U32, bytes: +List<U32>}

def exc(esr: U32, ipa: U32, xt: U32) -> V.RawExit:
  V.Exception{w(esr), w(0), w(ipa), w(0), w(0), w(0), w(0), w(xt)}

def Ev.after(r: Maybe<&1, S.Sim & M.Step>) -> Maybe<&1, S.Sim & M.Machine>:
  match r:
    case None{}:
      None{}
    case Some{(s, step)}:
      match step:
        case M.Step{m, c}:
          Some{(s, m)}

def Ev.exit(s: S.Sim, m: M.Machine, e: V.RawExit) -> Maybe<&1, S.Sim & M.Machine>:
  Ev.after(S.Sim.run(100000n, M.Step, s, M.Machine.on_exit(0, m, e)))

def Ev.step(ev: Ev, st: Maybe<&1, S.Sim & M.Machine>) -> Maybe<&1, S.Sim & M.Machine>:
  match ev st:
    case _ None{}:
      None{}
    case Wr{a, v} Some{(s, m)}:
      Ev.exit(s, m, exc(2474704960, a, v))
    case Rd{a} Some{(s, m)}:
      Ev.exit(s, m, exc(2474704896, a, 0))
    case Typed{bs} Some{(s, m)}:
      S.Sim.run(100000n, M.Machine, s, M.Machine.input(m, bs))
    case Host{e} Some{(s, m)}:
      S.Sim.run(100000n, M.Machine, s, M.Machine.net_event(m, e))
    case Poke{a, bs} Some{(s, m)}:
      Some{(S.Sim.write(s, w(a), bs), m)}

def trace(evs: List<Ev>, st: Maybe<&1, S.Sim & M.Machine>) -> Maybe<&1, S.Sim & M.Machine>:
  match evs:
    case Nil{}:
      st
    case Con{ev, rest}:
      trace(rest, Ev.step(ev, st))

def evs(a: List<Ev>, b: List<Ev>) -> List<Ev>:
  List.append(&1, Ev, a, b)

# The driver's setup of queue qi of the device at base as queue g.
def setup_queue(+base: U32, qi: U32, +g: U32) -> List<Ev>:
  [Wr{(base + 48 : U32), qi}, Wr{(base + 56 : U32), 8},
   Wr{(base + 128 : U32), qdesc(g)}, Wr{(base + 132 : U32), 0},
   Wr{(base + 144 : U32), qavail(g)}, Wr{(base + 148 : U32), 0},
   Wr{(base + 160 : U32), qused(g)}, Wr{(base + 164 : U32), 0},
   Wr{(base + 68 : U32), 1}]

# Every device set up and DRIVER_OK.
def setup() -> List<Ev>:
  +c = slot(0)
  +n = slot(1)
  +p = slot(2)
  evs(setup_queue(c, 0, 0), evs(setup_queue(c, 1, 1), evs([Wr{(c + 112 : U32), 15}],
    evs(setup_queue(n, 0, 2), evs(setup_queue(n, 1, 3), evs([Wr{(n + 112 : U32), 15}],
    evs(setup_queue(p, 0, 4), [Wr{(p + 112 : U32), 15}])))))))

# Descriptor i of queue g: addr, len, flags (1 NEXT, 2 WRITE), next.
def desc(+g: U32, +i: U32, addr: U32, len: U32, flags: U32, next: U32) -> Ev:
  Poke{(qdesc(g) + (i * 16 : U32) : U32), cat(B.Bytes.le64(w(addr)), cat(B.Bytes.le32(len), cat(B.Bytes.le16(flags), B.Bytes.le16(next))))}

def ring16(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      cat(B.Bytes.le16(x), ring16(t))

# The available ring of queue g publishing heads.
def avail(+g: U32, +heads: +List<U32>) -> Ev:
  Poke{qavail(g), cat([0, 0], cat(B.Bytes.le16(U32.from_nat(List.length(&2, U32, heads))), ring16(heads)))}

def notify(n: U32, q: U32) -> Ev:
  Wr{(slot(n) + 80 : U32), q}

def run(s: S.Sim, es: List<Ev>) -> Maybe<&1, S.Sim & M.Machine>:
  trace(evs(setup(), es), Some{(s, machine())})

# Observations of the end state.

def Out.sim(r: Maybe<&1, S.Sim & M.Machine>) -> S.Sim:
  match r:
    case None{}:
      S.Sim.new(w(0), 0n)
    case Some{(s, m)}:
      s

def Out.backlog(r: Maybe<&1, S.Sim & M.Machine>) -> U32:
  match r:
    case None{}:
      999
    case Some{(s, m)}:
      M.Machine.net_backlog(m)

def bytes_at(+s: S.Sim, addr: U32, n: U32) -> +List<U32>:
  S.Sim.read(s, w(addr), n)

# The used ring's index and first two elements of queue g.
def used(+s: S.Sim, +g: U32) -> String:
  show(bytes_at(s, (qused(g) + 2 : U32), 18))

def show_irq(i: S.Irq) -> String:
  match i:
    case S.Irq{n, l}:
      U32.show(n) ++ ":" ++ Bool.pick(String, l, "1", "0")

def irqs(+s: S.Sim) -> String:
  List.show(~&2, ~S.Irq, ~show_irq, S.Sim.irqs(s))

def show_reg(r: S.SetReg) -> String:
  match r:
    case S.SetReg{n, v}:
      "x" ++ U32.show(n) ++ "=" ++ U32.show(U.U64.lo(v))

def regs(+s: S.Sim) -> String:
  List.show(~&2, ~S.SetReg, ~show_reg, S.Sim.regs(s))

def show_cmd(c: V.NetCmd) -> String:
  match c:
    case V.TcpConnect{id, ip, port}:
      "connect " ++ U32.show(id) ++ " " ++ U32.show(ip) ++ ":" ++ U32.show(port)
    case V.TcpSend{id, bs}:
      "send " ++ U32.show(id) ++ " " ++ show(bs)
    case V.TcpShutdown{id}:
      "shutdown " ++ U32.show(id)
    case V.TcpClose{id}:
      "close " ++ U32.show(id)
    case V.TcpAbort{id}:
      "abort " ++ U32.show(id)
    case V.UdpSend{sport, ip, port, bs}:
      "udp " ++ U32.show(sport) ++ " " ++ U32.show(ip) ++ ":" ++ U32.show(port) ++ " " ++ show(bs)
    case V.TcpSendStaged{id, slot}:
      "send " ++ U32.show(id) ++ " staged " ++ U32.show(slot)
    case V.StageDrop{slot}:
      "drop staged " ++ U32.show(slot)
    case V.TcpRelease{id}:
      "release " ++ U32.show(id)

def cmds(+s: S.Sim) -> String:
  List.show(~&2, ~V.NetCmd, ~show_cmd, S.Sim.net(s))

def len(+bs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

def byte(bs: +List<U32>) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, bs, 0n), 999)

# The used element {id 0, len} after one use: index 1, then id and len.
def used1(len: U32) -> String:
  show(cat([1, 0, 0, 0, 0, 0], cat(B.Bytes.le32(len), B.Bytes.zeros(8n))))

# RTC

def rtc_tests() -> IO(Unit):
  +s1 = Out.sim(run(S.Sim.with_now(mem(), w(1700000000)), [Rd{rtc()}]))
  +s2 = Out.sim(run(S.Sim.with_now(mem(), w(1000)), [Wr{(rtc() + 8 : U32), 100}, Rd{rtc()}]))
  +s3 = Out.sim(run(S.Sim.with_now(mem(), w(1000)), [Wr{(rtc() + 16 : U32), 1}, Wr{(rtc() + 4 : U32), 1000}, Rd{(rtc() + 24 : U32)}]))
  +s4 = Out.sim(run(mem(), [Rd{(rtc() + 4064 : U32)}]))
  do IO<Unit>:
    T.eq_str("integration rtc DR reads the clock", regs(s1), "[x1=1700000000]")
    T.eq_str("integration rtc DR after LR", regs(s2), "[x1=100]")
    T.eq_str("integration rtc alarm MIS and irq", regs(s3) ++ " " ++ irqs(s3), "[x1=1] [34:1]")
    T.eq_str("integration rtc PeriphID0", regs(s4), "[x1=49]")

# Console

def hi() -> +List<U32>:
  [104, 105, 10]

# One receive buffer of 16 bytes posted in queue 0, then notified.
def con_post() -> List<Ev>:
  [desc(0, 0, (ram() + 4096 : U32), 16, 2, 0), avail(0, [0]), notify(0, 0)]

def console_tests() -> IO(Unit):
  +tx = Out.sim(run(mem(), [desc(1, 0, (ram() + 4096 : U32), 3, 0, 0), Poke{(ram() + 4096 : U32), hi()}, avail(1, [0]), notify(0, 1)]))
  +rx = Out.sim(run(mem(), evs(con_post(), [Typed{[65, 66]}])))
  +early = Out.sim(run(mem(), evs([Typed{[67, 68, 69]}], con_post())))
  do IO<Unit>:
    T.eq_str("integration hvc0 tx becomes VmConsole", show(S.Sim.console_out(tx)), show(hi()))
    T.eq_str("integration hvc0 tx used", used(tx, 1), used1(0))
    T.eq_str("integration hvc0 tx irq", irqs(tx), "[48:1]")
    T.eq_str("integration input reaches hvc0 buffer", show(bytes_at(rx, (ram() + 4096 : U32), 3)), "[65, 66, 0]")
    T.eq_str("integration input hvc0 used", used(rx, 0), used1(2))
    T.eq_str("integration input hvc0 irq", irqs(rx), "[48:1]")
    T.eq_str("integration input before buffer, delivered on notify", show(bytes_at(early, (ram() + 4096 : U32), 4)), "[67, 68, 69, 0]")
    T.eq_str("integration input before buffer used", used(early, 0), used1(3))

# Net

# A DHCP DISCOVER from the guest's MAC: op 1, xid 0x01020304, flags 0x8000.
def dhcp_msg() -> +List<U32>:
  +head = {[1, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0] : +List<U32>}
  +chaddr = cat(N.Slirp.guest_mac(), B.Bytes.zeros(10n))
  cat(head, cat(B.Bytes.zeros(16n), cat(chaddr, cat(B.Bytes.zeros(192n), [99, 130, 83, 99, 53, 1, 1, 255]))))

def dhcp_frame() -> +List<U32>:
  udp = W.Udp.build(0, 4294967295, W.Udp{68, 67, dhcp_msg()})
  W.Eth.build(W.Eth{[255, 255, 255, 255, 255, 255], N.Slirp.guest_mac(), 2048, W.Ipv4.build(W.Ipv4{0, 4294967295, 17, 64, 0, udp})})

def remote() -> U32:
  16909060

# A TCP segment from the guest's port 40000 to 1.2.3.4:80.
def gtcp(flags: U32, seq: U32, ack: U32) -> +List<U32>:
  +g = N.Slirp.guest_ip()
  W.Eth.build(W.Eth{N.Slirp.gateway_mac(), N.Slirp.guest_mac(), 2048, W.Ipv4.build(W.Ipv4{g, remote(), 6, 64, 0, W.Tcp.build(g, remote(), W.Tcp{40000, 80, seq, ack, flags, 65535, 0, []})})})

def first(fs: +List<+List<U32>>) -> +List<U32>:
  match fs:
    case Nil{}:
      []
    case Con{f, t}:
      f

def frames_of(o: N.SlirpOut) -> +List<+List<U32>>:
  match o:
    case N.SlirpOut{n, fs, cs}:
      fs

# One receive buffer of 1024 bytes posted in queue 2.
def rx_post() -> List<Ev>:
  [desc(2, 0, (ram() + 4096 : U32), 1024, 2, 0), avail(2, [0])]

# A frame transmitted through queue 3 (header first) from RAM + 6144.
def tx_frame(+f: +List<U32>) -> List<Ev>:
  [desc(3, 0, (ram() + 6144 : U32), (12 + len(f) : U32), 0, 0), Poke{(ram() + 6144 : U32), cat(B.Bytes.zeros(12n), f)}, avail(3, [0]), notify(1, 1)]

# The guest's SYN to 1.2.3.4:80 with a receive buffer posted.
def syn() -> Maybe<&1, S.Sim & M.Machine>:
  run(mem(), evs(rx_post(), tx_frame(gtcp(2, 1000, 0))))

def net_tests() -> IO(Unit):
  +offer = first(frames_of(N.Slirp.guest_frame(N.Slirp.new(), dhcp_frame())))
  +d = Out.sim(run(mem(), evs(rx_post(), tx_frame(dhcp_frame()))))
  +synack = N.Slirp.tcp_frame(remote(), 80, 40000, 1, 1001, 18, 1460, [])
  +c1 = Out.sim(syn())
  +c2 = Out.sim(trace([Host{V.TcpConnected{0}}], syn()))
  do IO<Unit>:
    T.eq_str("integration dhcp offer in rx buffer", show(bytes_at(d, (ram() + 4108 : U32), len(offer))), show(offer))
    T.eq_u32("integration dhcp offer type", byte(bytes_at(d, (ram() + 4096 + 12 + 284 : U32), 1)), 2)
    T.eq_str("integration dhcp rx used", used(d, 2), used1((12 + len(offer) : U32)))
    T.eq_str("integration dhcp tx used", used(d, 3), used1(0))
    T.eq_str("integration dhcp irq", irqs(d), "[49:1]")
    T.eq_str("integration dhcp no host command", cmds(d), "[]")
    T.eq_str("integration tcp syn becomes TcpConnect", cmds(c1), "[connect 0 16909060:80]")
    T.eq_str("integration tcp syn: nothing for the guest yet", used(c1, 2), show(B.Bytes.zeros(18n)))
    T.eq_str("integration tcp connected delivers SYN|ACK", show(bytes_at(c2, (ram() + 4108 : U32), len(synack))), show(synack))
    T.eq_u32("integration tcp SYN|ACK flags", byte(bytes_at(c2, (ram() + 4096 + 12 + 47 : U32), 1)), 18)
    T.eq_str("integration tcp SYN|ACK used", used(c2, 2), used1((12 + len(synack) : U32)))
    T.eq_str("integration tcp irq", irqs(c2), "[49:1]")

# Backpressure: frames wait for receive buffers.

def udp(n: U32) -> Ev:
  Host{V.UdpData{remote(), 53, 5000, [n]}}

# Two datagrams from the host, no receive buffer posted.
def b2() -> Maybe<&1, S.Sim & M.Machine>:
  run(mem(), [udp(1), udp(2)])

# Then one receive buffer posted and queue 0 notified.
def b1() -> Maybe<&1, S.Sim & M.Machine>:
  trace([desc(2, 0, (ram() + 4096 : U32), 1024, 2, 0), avail(2, [0]), notify(1, 0)], b2())

# Then a second one.
def b0() -> Maybe<&1, S.Sim & M.Machine>:
  trace([desc(2, 1, (ram() + 5120 : U32), 1024, 2, 0), avail(2, [0, 1]), notify(1, 0)], b1())

def backlog_tests() -> IO(Unit):
  +s1 = Out.sim(b1())
  do IO<Unit>:
    T.eq_u32("integration backlog empty", Out.backlog(run(mem(), [])), 0)
    T.eq_u32("integration backlog grows without buffers", Out.backlog(b2()), 2)
    T.eq_u32("integration backlog shrinks on notify", Out.backlog(b1()), 1)
    T.eq_u32("integration backlog drains", Out.backlog(b0()), 0)
    T.eq_str("integration backlog first frame delivered in order", show(bytes_at(s1, (ram() + 4108 : U32), 43)), show(first(frames_of(N.Slirp.host_event(N.Slirp.new(), V.UdpData{remote(), 53, 5000, [1]})))))
    T.eq_str("integration backlog irq", irqs(s1), "[49:1]")
    T.eq_u32("integration backlog no net device", M.Machine.net_backlog(M.Machine.new(1n, [D.RngKind{}])), 0)

# At most 256 frames wait; the oldest are dropped.
def many(+n: Nat) -> +List<+List<U32>>:
  match n:
    case 0n:
      []
    case 1n+p:
      [U32.from_nat(p)] <> many(p)

def capped(r: Maybe<&1, S.Sim & D.Dev>) -> String:
  match r:
    case None{}:
      "out of fuel"
    case Some{(s, d)}:
      U32.show(D.Dev.backlog(d))

def cap_tests() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("integration backlog capped at 256", capped(S.Sim.exec(D.Dev, mem(), D.Dev.deliver(D.Dev, D.Dev.new(D.NetKind{N.Slirp.guest_mac()}), many(300n)))), "256")
    T.eq_str("integration deliver ignored by other kinds", capped(S.Sim.exec(D.Dev, mem(), D.Dev.deliver(D.Dev, D.Dev.new(D.ConsoleKind{}), many(3n)))), "0")

# 9p

def tversion() -> +List<U32>:
  cat(B.Bytes.le32(21), cat([100, 1, 0], cat(B.Bytes.le32(8192), cat(B.Bytes.le16(8), B.Bytes.of_string("9P2000.L")))))

def rversion() -> +List<U32>:
  cat(B.Bytes.le32(21), cat([101, 1, 0], cat(B.Bytes.le32(8192), cat(B.Bytes.le16(8), B.Bytes.of_string("9P2000.L")))))

def p9_tests() -> IO(Unit):
  +s = Out.sim(run(mem(), [desc(4, 0, (ram() + 4096 : U32), 21, 1, 1), desc(4, 1, (ram() + 4224 : U32), 64, 2, 0), Poke{(ram() + 4096 : U32), tversion()}, avail(4, [0]), notify(2, 0)]))
  do IO<Unit>:
    T.eq_str("integration 9p Tversion gets Rversion", show(bytes_at(s, (ram() + 4224 : U32), 21)), show(rversion()))
    T.eq_str("integration 9p used", used(s, 4), used1(21))
    T.eq_str("integration 9p irq", irqs(s), "[50:1]")

# Devices

def val_of(r: D.Dev & U32) -> U32:
  match r:
    case (d, v):
      v

def rd(d: D.Dev, off: U32) -> U32:
  val_of(D.Dev.read(d, off, 4))

def dev_tests() -> IO(Unit):
  +c = D.Dev.new(D.ConsoleKind{})
  +n = D.Dev.new(D.NetKind{[1, 2, 3, 4, 5, 6]})
  +p = D.Dev.new(D.P9Kind{0, "share"})
  do IO<Unit>:
    T.eq_str("integration console id, empty config", show([rd(c, 8), rd(c, 256)]), "[3, 0]")
    T.eq_str("integration net id, mac", show([rd(n, 8), rd(n, 256), rd(n, 260)]), "[1, 67305985, 1541]")
    T.eq_str("integration p9 id, tag", show([rd(p, 8), rd(p, 256), rd(p, 260)]), "[9, 1752367109, 6648417]")

def main() -> IO(Unit):
  do IO<Unit>:
    dev_tests()
    rtc_tests()
    console_tests()
    net_tests()
    backlog_tests()
    cap_tests()
    p9_tests()
