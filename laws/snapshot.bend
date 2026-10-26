import Base
import ../src/lib/u64.bend as U
import ../src/arm64/psci.bend as P
import ../src/dev/pl011.bend as Uart
import ../src/dev/pl031.bend as Rtc
import ../src/net/nat.bend as Nt
import ../src/virtio/mmio.bend as M
import ../src/virtio/queue.bend as Q
import ../src/virtio/device.bend as D
import ../src/fs/p9.bend as F
import ../src/vmm/machine.bend as Mc
import ../src/virtio/vsock.bend as Vs
import ../src/vmm/snapshot.bend as S

# Frozen spec for src/vmm/snapshot.bend: decode inverts encode.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def kinds() -> +List<D.DevKind>:
  [D.RngKind{}, D.ConsoleKind{}, D.NetKind{[82, 84, 0, 18, 52, 86]}, D.BlkKind{0, w(16384)}, D.BlkRoKind{1, U.U64{1, 2}}, D.P9Kind{0, "share"}]

def fresh() -> Mc.Machine:
  Mc.Machine.new(4n, kinds())

def busy_dev() -> D.Dev:
  D.Dev{D.NetKind{[1, 2, 3, 4, 5, 6]}, M.VirtioMmio{1, U.U64{1, 32}, U.U64{1, 32}, 1, 0, 1, [M.QueueCfg{256, 128, True{}, w(4096), w(8192), U.U64{1, 12288}}, M.QueueCfg{256, 0, False{}, w(0), w(0), w(0)}], 15, 1, 0, [1, 2, 3, 4, 5, 6]}, [Q.Vq{128, w(4096), w(8192), U.U64{1, 12288}, 65535, 7}], D.NetState{[[9, 9], [], [1]]}}

def busy_p9() -> D.Dev:
  D.Dev{D.P9Kind{2, "home"}, M.VirtioMmio{9, U.U64{1, 1}, U.U64{1, 1}, 0, 0, 0, [M.QueueCfg{256, 64, True{}, w(1), w(2), w(3)}], 15, 0, 0, [4, 0, 104, 111, 109, 101]}, [], D.P9Dev{F.P9State{65536, [F.Fid{0, "", False{}}, F.Fid{7, "a/b.txt", True{}}]}}}

def busy() -> Mc.Machine:
  Mc.Machine{P.PsciState{[True{}, False{}, True{}]}, Uart.Pl011{1, 2, 112, 769, 18, 80, [104, 105]}, True{}, [busy_dev(), busy_p9()], [True{}, False{}], Rtc.Pl031{4294967295, 10, 100, 1, 2}, False{}, Nt.Slirp{[Nt.Conn{0, 40000, 16909060, 80, 1, 1000, 2}, Nt.Conn{3, 5353, 167772675, 53, 3, 7, 9}], 4}}

law snapshot.roundtrip_fresh:
  {S.Snap.decode(S.Snap.encode(fresh())) == Some{fresh()} : Maybe<&2, Mc.Machine>}

law snapshot.roundtrip_busy:
  {S.Snap.decode(S.Snap.encode(busy())) == Some{busy()} : Maybe<&2, Mc.Machine>}

law snapshot.magic_first:
  {List.take(&2, U32, S.Snap.encode(fresh()), 2n) == [1112428109, 1] : +List<U32>}

law snapshot.bad_magic:
  {S.Snap.decode(List.set(&2, U32, S.Snap.encode(fresh()), 0n, 7)) == None{} : Maybe<&2, Mc.Machine>}

law snapshot.bad_version:
  {S.Snap.decode(List.set(&2, U32, S.Snap.encode(fresh()), 1n, 2)) == None{} : Maybe<&2, Mc.Machine>}

law snapshot.truncated:
  {S.Snap.decode(List.take(&2, U32, S.Snap.encode(busy()), 40n)) == None{} : Maybe<&2, Mc.Machine>}

law snapshot.trailing:
  {S.Snap.decode(List.append(&2, U32, S.Snap.encode(busy()), [0])) == None{} : Maybe<&2, Mc.Machine>}

law snapshot.empty:
  {S.Snap.decode([]) == None{} : Maybe<&2, Mc.Machine>}

# A machine with a vsock device holding a connection, pending host data and
# a packet for the guest.
def vsock_machine() -> Mc.Machine:
  Mc.Machine{P.PsciState{[True{}]}, Uart.Pl011.new(), False{}, [D.Dev{D.VsockKind{w(3)}, M.VirtioMmio.new(19, U.U64{1, 0}, 3n, 256, [3, 0, 0, 0, 0, 0, 0, 0]), [], D.VsState{Vs.Vsock{w(3), [Vs.VConn{0, 40000, 1234, 1, 10, 4096, 4, 7, 0, [1, 2, 3], True{}}], 1, 1024, [[9, 8]]}}}], [False{}], Rtc.Pl031.new(), False{}, Nt.Slirp.new()}

law snapshot.roundtrip_vsock:
  {S.Snap.decode(S.Snap.encode(vsock_machine())) == Some{vsock_machine()} : Maybe<&2, Mc.Machine>}
