import Base
import ../src/host/handoff.bend as H

# Spec for src/host/handoff.bend: the handoff between the Bend event loop
# and a vCPU thread, over every schedule of the two sides (C_TO_BEND.md,
# the pure models).

# The race, both ways (no spinning: start(0, 0)). The loop marks itself
# parked while the thread finishes: either the thread sees parked and writes
# the pipe, or the loop's last check sees the answer; it is taken once.
# Schedules: 0 the loop steps, 1 the thread.
law handoff.race_thread_sees_parked:
  {H.Hand.good(H.Hand.run([0, 0, 1, 1, 0, 1, 1, 0], False{}, H.Hand.start(0, 0))) == True{} : Bool}

law handoff.race_loop_sees_answer:
  {H.Hand.good(H.Hand.run([0, 0, 1, 1, 1, 1, 0, 0], False{}, H.Hand.start(0, 0))) == True{} : Bool}

# A spin that sees the answer takes it without parking.
law handoff.spin_takes:
  {H.Hand.good(H.Hand.run([0, 1, 1, 1, 1, 0], False{}, H.Hand.start(2, 0))) == True{} : Bool}

# A stale byte in the pipe wakes the loop early; it sleeps again until the
# answer.
law handoff.stale_wake:
  {H.Hand.good(H.Hand.run([0, 0, 0, 0, 0, 1, 1, 1, 1, 0], False{}, H.Hand.start(0, 1))) == True{} : Bool}

# The order matters: a loop that checks for the answer before it marks
# itself parked can sleep forever with the answer ready (a lost
# completion). tests/handoff.bend searches every schedule of both orders.
law handoff.late_park_loses:
  {H.Hand.stuck(H.Hand.run([0, 0, 0, 1, 1, 1, 1, 0], True{}, H.Hand.start(0, 0))) && Bool.not(H.Hand.good(H.Hand.run([0, 0, 0, 1, 1, 1, 1, 0], True{}, H.Hand.start(0, 0)))) == True{} : Bool}

# Queued register writes apply in the order posted, all before the next
# request: the later write to a register wins, and a full queue (64) takes
# no more.
law handoff.queue_order:
  {H.Queue.read(H.Queue.apply(H.Queue.post(H.Queue.post(H.Queue.post([], H.Write{1, 10}), H.Write{2, 20}), H.Write{1, 11}), []), 1) == 11 : U32}

law handoff.queue_all:
  {H.Queue.read(H.Queue.apply(H.Queue.post(H.Queue.post([], H.Write{1, 10}), H.Write{2, 20}), []), 2) == 20 : U32}

law handoff.queue_cap:
  {H.Queue.cap() == 64 : U32}
