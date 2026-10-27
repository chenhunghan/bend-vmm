import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as Sim
import ../src/virtio/queue.bend as Q
import ../src/virtio/vsock.bend as S
import ./t.bend as T

# virtio-vsock protocol scenarios beyond laws/vsock.bend: credit-limited
# host data, credit updates, EOF and shutdown, host-initiated connections.

def cid() -> U.U64:
  U.U64{0, 3}

def pkt(sp: U32, dp: U32, op: U32, flags: U32, alloc: U32, fwd: U32, pl: +List<U32>) -> +List<U32>:
  S.Pkt.build(S.Pkt{cid(), U.U64{0, 2}, sp, dp, op, flags, alloc, fwd, pl})

def st(o: S.VsOut) -> S.Vsock:
  match o:
    case S.VsOut{v, cs}:
      v

def cmds(o: S.VsOut) -> +List<V.VsockCmd>:
  match o:
    case S.VsOut{v, cs}:
      cs

def outs(v: S.Vsock) -> +List<+List<U32>>:
  match v:
    case S.Vsock{c, cs, n, p, o}:
      o

# Payload lengths and ops of the packets queued for the guest.
def shape(ps: +List<+List<U32>>) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{+p, rest}:
      "op" ++ U32.show(B.Bytes.read_le16(B.Bytes.slice(p, 30n, 2n))) ++ "/" ++ U32.show(B.Bytes.read_le32(B.Bytes.slice(p, 24n, 4n))) ++ " " ++ shape(rest)

def show_cmd(c: V.VsockCmd) -> String:
  match c:
    case V.VsConnect{id, port}:
      "connect " ++ U32.show(id) ++ ":" ++ U32.show(port)
    case V.VsSend{id, bs}:
      "send " ++ U32.show(id) ++ "/" ++ Nat.show(List.length(&2, U32, bs))
    case V.VsShutdown{id}:
      "shutdown " ++ U32.show(id)
    case V.VsClose{id}:
      "close " ++ U32.show(id)
    case V.VsAccepted{id, port}:
      "accepted " ++ U32.show(id) ++ ":" ++ U32.show(port)

def show_cmds(cs: +List<V.VsockCmd>) -> String:
  List.show(~&2, ~V.VsockCmd, ~show_cmd, cs)

# The guest connects (buffer 4096) and the host accepts.
def open4k() -> S.Vsock:
  +v = st(S.Vsock.guest_packet(S.Vsock.new(cid()), pkt(40000, 1234, 1, 0, 4096, 0, [])))
  S.Vsock.drop_out(st(S.Vsock.host_event(v, V.VsConnected{0})))

# n RW packets from guest port 30000 + i to host port 1234, none of them for
# a connection: each asks for an RST.
def flood_rw(n: Nat, v: S.Vsock) -> S.Vsock:
  match n:
    case 0n:
      v
    case 1n+(+p):
      flood_rw(p, st(S.Vsock.guest_packet(v, pkt((30000 + U32.from_nat(p) : U32), 1234, 5, 0, 4096, 0, [1]))))

# n REQUESTs from guest ports 30000 + i to host port 1234, each a new
# connection; ps collects the host commands, newest first.
def flood_req(n: Nat, v: S.Vsock, ps: Nat) -> S.Vsock & Nat:
  match n:
    case 0n:
      (v, ps)
    case 1n+(+p):
      +o = S.Vsock.guest_packet(v, pkt((30000 + U32.from_nat(p) : U32), 1234, 1, 0, 4096, 0, []))
      flood_req(p, st(o), Nat.add(ps, List.length(&2, V.VsockCmd, cmds(o))))

def conns_of(r: S.Vsock & Nat) -> Nat:
  match r:
    case (v, n):
      List.length(&2, S.VConn, S.Vsock.conns(v))

def connects_of(r: S.Vsock & Nat) -> Nat:
  match r:
    case (v, n):
      n

def outs_of(r: S.Vsock & Nat) -> String:
  match r:
    case (v, n):
      shape(outs(v))

# The longest guest read a program asks for, running it on the simulator's
# memory up to its first effect other than a read or a write; reads past
# 4096 bytes answer nothing (too large for the simulator's lists).
def longest(fuel: Nat, -A: Type, s: Sim.Sim, m: V.Vm<A>, +top: U32) -> U32:
  match fuel:
    case 0n:
      top
    case 1n+f:
      match m:
        case V.VmRead{+a, +n, k}:
          +s = s
          +big = U32.is_lt(4096, n)
          longest(f, A, s, k(Bool.pick(+List<U32>, big, [], Sim.Sim.read(s, a, n))), U32.max(top, n))
        case V.VmWrite{a, bs, next}:
          longest(f, A, Sim.Sim.write(s, a, bs), next, top)
        case _:
          top

# A tx queue (8 entries: descriptors 4096, available ring 4224, used ring
# 4352) whose one chain is a readable descriptor 4294967295 bytes long: the
# device reads at most a header and 64 KiB of payload of it.
def tx_huge() -> U32:
  +s = Sim.Sim.new(U.U64{0, 4096}, 1024n)
  s = Sim.Sim.write(s, U.U64{0, 4096}, [0, 18, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0])
  s = Sim.Sim.write(s, U.U64{0, 4224}, [0, 0, 1, 0, 0, 0])
  longest(100n, S.VsTxq, s, V.Op.finish(S.VsTxq, S.Vsq.tx(S.VsTxq, Q.Vq{8, U.U64{0, 4096}, U.U64{0, 4224}, U.U64{0, 4352}, 0, 0})), 0)

def main() -> IO(Unit):
  do IO<Unit>:
    +a : S.Vsock = st(S.Vsock.host_event(open4k(), V.VsData{0, B.Bytes.zeros(5000n)}))
    T.eq_str("vsock credit caps data", shape(outs(a)), "op5/4096 ")
    T.eq_u32("vsock backlog counts waiting bytes", S.Vsock.backlog(a), 1)
    +b : S.Vsock = st(S.Vsock.guest_packet(S.Vsock.drop_out(a), pkt(40000, 1234, 6, 0, 4096, 4096, [])))
    T.eq_str("vsock credit update releases the rest", shape(outs(b)), "op5/904 ")
    +c : S.Vsock = st(S.Vsock.host_event(S.Vsock.drop_out(b), V.VsEof{0}))
    T.eq_str("vsock host eof -> shutdown(send)", shape(outs(c)), "op4/0 ")
    T.eq_str("vsock guest shutdown(send)", show_cmds(cmds(S.Vsock.guest_packet(c, pkt(40000, 1234, 4, 2, 4096, 5000, [])))), "[shutdown 0]")
    T.eq_str("vsock guest shutdown(both)", show_cmds(cmds(S.Vsock.guest_packet(c, pkt(40000, 1234, 4, 3, 4096, 5000, [])))), "[shutdown 0, close 0]")
    T.eq_str("vsock guest rst", show_cmds(cmds(S.Vsock.guest_packet(c, pkt(40000, 1234, 3, 0, 4096, 5000, [])))), "[close 0]")
    T.eq_str("vsock duplicate request ignored", show_cmds(cmds(S.Vsock.guest_packet(open4k(), pkt(40000, 1234, 1, 0, 4096, 0, [])))), "[]")
    +h : S.Vsock = S.Vsock.drop_out(st(S.Vsock.host_event(S.Vsock.new(cid()), V.VsIncoming{2147483648, 5000})))
    T.eq_str("vsock host connect accepted", show_cmds(cmds(S.Vsock.guest_packet(h, pkt(5000, 1024, 2, 0, 65536, 0, [])))), "[accepted 2147483648:1024]")
    T.eq_str("vsock data waits for the response", shape(outs(st(S.Vsock.host_event(h, V.VsData{2147483648, [1, 2]})))), "")
    # Guest-driven state is capped: RSTs for unknown connections stop at 256
    # queued packets, connections at 128 (a REQUEST past it gets an RST and
    # no host connect).
    T.eq_u32("vsock rsts capped at 256 queued", U32.from_nat(List.length(&2, +List<U32>, outs(flood_rw(300n, S.Vsock.new(cid()))))), 256)
    T.eq_u32("vsock 128 connections", U32.from_nat(conns_of(flood_req(128n, S.Vsock.new(cid()), 0n))), 128)
    T.eq_u32("vsock 128 host connects", U32.from_nat(connects_of(flood_req(128n, S.Vsock.new(cid()), 0n))), 128)
    T.eq_u32("vsock connections capped at 128", U32.from_nat(conns_of(flood_req(130n, S.Vsock.new(cid()), 0n))), 128)
    T.eq_u32("vsock no host connect past the cap", U32.from_nat(connects_of(flood_req(130n, S.Vsock.new(cid()), 0n))), 128)
    T.eq_str("vsock request past the cap gets rst", outs_of(flood_req(130n, S.Vsock.new(cid()), 0n)), "op3/0 op3/0 ")
    T.eq_u32("vsock tx reads at most 65580 bytes of a chain", tx_huge(), 65580)
