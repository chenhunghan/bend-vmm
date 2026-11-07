import Base
import ../src/lib/u64.bend as U
import ../src/net/limits.bend as N

# Spec for src/net/limits.bend: the NAT's host-side limits, what the host is
# handed, and that they hold together.

law limits.sane:
  {N.Lim.sane(N.Lim.default()) == True{} : Bool}

# 4 MiB, 32 MiB, 60 s, 100 ms, 64 MiB, 96 MiB, 30 s, 64, 128, 60 s
law limits.wire:
  {N.Lim.wire(N.Lim.default()) == [0, 4194304, 0, 33554432, 13, 4165425152, 0, 100000000, 0, 67108864, 0, 100663296, 6, 4230196224, 64, 128, 13, 4165425152] : +List<U32>}

law limits.secs:
  {N.Lim.secs(1) == U.U64{0, 1000000000} : U.U64}

law limits.cap_past_hard:
  {N.Lim.sane(N.Limits{N.Lim.mib(64), N.Lim.mib(32), N.Lim.secs(60), N.Lim.millis(100), N.Lim.mib(64), N.Lim.mib(96), N.Lim.secs(30), 64, 128, N.Lim.secs(60)}) == False{} : Bool}

law limits.hard_past_wall:
  {N.Lim.sane(N.Limits{N.Lim.mib(4), N.Lim.mib(128), N.Lim.secs(60), N.Lim.millis(100), N.Lim.mib(64), N.Lim.mib(96), N.Lim.secs(30), 64, 128, N.Lim.secs(60)}) == False{} : Bool}

law limits.no_udp:
  {N.Lim.sane(N.Limits{N.Lim.mib(4), N.Lim.mib(32), N.Lim.secs(60), N.Lim.millis(100), N.Lim.mib(64), N.Lim.mib(96), N.Lim.secs(30), 64, 0, N.Lim.secs(60)}) == False{} : Bool}

law limits.tick_past_stall:
  {N.Lim.sane(N.Limits{N.Lim.mib(4), N.Lim.mib(32), N.Lim.millis(50), N.Lim.millis(100), N.Lim.mib(64), N.Lim.mib(96), N.Lim.secs(30), 64, 128, N.Lim.secs(60)}) == False{} : Bool}
