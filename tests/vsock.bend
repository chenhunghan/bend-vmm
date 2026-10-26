import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
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
