import Base
import ../src/host/handoff.bend as H
import ./t.bend as T

# src/host/handoff.bend over every schedule: the event loop and a vCPU
# thread interleaved in all orders (each search reaches every state of one
# request's handoff), for 0 to 3 spins and with or without a stale byte in
# the pipe. The real order always ends with the answer taken once; the
# swapped order (check, then mark parked) has a schedule that hangs.

def spins_ok(n: Nat, +stale: U32) -> Bool:
  match n:
    case 0n:
      H.Hand.all_good(False{}, H.Hand.start(0, stale))
    case 1n+(+k):
      H.Hand.all_good(False{}, H.Hand.start((U32.from_nat(k) + 1 : U32), stale)) && spins_ok(k, stale)

def fill(n: Nat) -> +List<H.Write>:
  match n:
    case 0n:
      []
    case 1n+k:
      H.Queue.post(fill(k), H.Write{1, 1})

def main() -> IO(Unit):
  do IO<Unit>:
    T.ok("handoff: every schedule ends with the answer taken once (0-3 spins)", spins_ok(3n, 0))
    T.ok("handoff: the same with a stale byte in the pipe", spins_ok(3n, 1))
    T.ok("handoff: marking parked after the last check loses a completion", Bool.not(H.Hand.all_good(True{}, H.Hand.start(2, 0))))
    T.ok("handoff: the search is not vacuous (more than 30 states)", U32.is_lt(30, H.Hand.reached(False{}, H.Hand.start(2, 0))))
    T.eq_u32("handoff: a write queued past 64 waits",
      U32.from_nat(List.length(&2, H.Write, H.Queue.post(fill(64n), H.Write{9, 9}))), 64)
