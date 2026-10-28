import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/virtio/vsock.bend as S

# Frozen spec for src/virtio/vsock.bend. Packet bytes come from an
# independent encoder of the header in the file (guest CID 3).

def cid() -> U.U64:
  U.U64{0, 3}

def out(o: S.VsOut) -> +List<+List<U32>>:
  match o:
    case S.VsOut{S.Vsock{c, cs, n, p, pkts}, cmds}:
      pkts

def cmds(o: S.VsOut) -> +List<V.VsockCmd>:
  match o:
    case S.VsOut{vs, cs}:
      cs

def vs(o: S.VsOut) -> S.Vsock:
  match o:
    case S.VsOut{v, cs}:
      v

# The guest (port 40000, buffer 64 KiB) connects to host port 1234.
def requested() -> S.Vsock:
  vs(S.Vsock.guest_packet(S.Vsock.new(cid()), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]))

def connected() -> S.Vsock:
  S.Vsock.drop_out(vs(S.Vsock.host_event(requested(), V.VsConnected{0})))

law vsock.config:
  {S.Vs.config(U.U64{0, 3}) == [3, 0, 0, 0, 0, 0, 0, 0] : +List<U32>}

law vsock.build:
  {S.Pkt.build(S.Pkt{U.U64{0, 3}, U.U64{0, 2}, 40000, 1234, 1, 0, 65536, 0, []}) == [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0] : +List<U32>}

law vsock.parse:
  {S.Pkt.parse([3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 2, 0, 0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 104, 105]) == Some{S.Pkt{U.U64{0, 3}, U.U64{0, 2}, 40000, 1234, 5, 0, 65536, 0, [104, 105]}} : Maybe<&2, S.Pkt>}

law vsock.parse_short:
  {S.Pkt.parse([1, 2, 3]) == None{} : Maybe<&2, S.Pkt>}

law vsock.connect:
  {cmds(S.Vsock.guest_packet(S.Vsock.new(cid()), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == [V.VsConnect{0, 1234}] : +List<V.VsockCmd>}

law vsock.response:
  {out(S.Vsock.host_event(requested(), V.VsConnected{0})) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 210, 4, 0, 0, 64, 156, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]] : +List<+List<U32>>}

law vsock.refused:
  {out(S.Vsock.host_event(requested(), V.VsRefused{0})) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 210, 4, 0, 0, 64, 156, 0, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]] : +List<+List<U32>>}

law vsock.data_in:
  {cmds(S.Vsock.guest_packet(connected(), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 2, 0, 0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 104, 105])) == [V.VsSend{0, [104, 105]}] : +List<V.VsockCmd>}

law vsock.credit_request:
  # after "hi" was consumed, a credit request reports fwd_cnt 2
  {out(S.Vsock.guest_packet(S.Vsock.drop_out(vs(S.Vsock.guest_packet(connected(), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 2, 0, 0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 104, 105]))), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 7, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 210, 4, 0, 0, 64, 156, 0, 0, 0, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0, 0, 4, 0, 2, 0, 0, 0]] : +List<+List<U32>>}

law vsock.unknown_rst:
  {out(S.Vsock.guest_packet(S.Vsock.new(cid()), [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 2, 0, 0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 104, 105])) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 210, 4, 0, 0, 64, 156, 0, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]] : +List<+List<U32>>}

law vsock.incoming:
  {out(S.Vsock.host_event(S.Vsock.new(cid()), V.VsIncoming{2147483648, 5000})) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 136, 19, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]] : +List<+List<U32>>}

# Proposed: guest-driven state is capped. At most 256 packets that answer the
# guest wait for it (an RST past that is dropped), and at most 128
# connections are open (a REQUEST past that gets an RST, no host connect).
def empties(n: Nat) -> +List<+List<U32>>:
  match n:
    case 0n:
      []
    case 1n+p:
      [] <> empties(p)

def conns(n: Nat) -> +List<S.VConn>:
  match n:
    case 0n:
      []
    case 1n+(+p):
      S.VConn{U32.from_nat(p), U32.from_nat(p), 1, 1, 0, 0, 0, 0, 0, 0, 0} <> conns(p)

law vsock.max_out:
  {S.Vs.max_out() == 256n : Nat}

law vsock.max_conns:
  {S.Vs.max_conns() == 128n : Nat}

law vsock.rst_dropped_when_out_full:
  {out(S.Vsock.guest_packet(S.Vsock{cid(), [], 0, 1024, empties(256n)}, [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 2, 0, 0, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 104, 105])) == empties(256n) : +List<+List<U32>>}

law vsock.request_past_max_conns_no_connect:
  {cmds(S.Vsock.guest_packet(S.Vsock{cid(), conns(128n), 128, 1024, []}, [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == [] : +List<V.VsockCmd>}

law vsock.request_past_max_conns_rst:
  {out(S.Vsock.guest_packet(S.Vsock{cid(), conns(128n), 128, 1024, []}, [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == [[2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 210, 4, 0, 0, 64, 156, 0, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0]] : +List<+List<U32>>}

law vsock.request_below_max_conns_connects:
  {cmds(S.Vsock.guest_packet(S.Vsock{cid(), conns(127n), 127, 1024, []}, [3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 64, 156, 0, 0, 210, 4, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == [V.VsConnect{127, 1234}] : +List<V.VsockCmd>}

law vsock.max_tx:
  {S.Vsq.max_tx() == 65580 : U32}
