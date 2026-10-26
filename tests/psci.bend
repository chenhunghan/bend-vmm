import Base
import ../src/lib/u64.bend as U
import ../src/arm64/psci.bend as P
import ./t.bend as T

# Tests for src/arm64/psci.bend beyond its laws. Function ids are decimal with
# their hex in the comment.

def h(a: U.U64) -> String:
  U.U64.show_hex(a)

def u(x: U32) -> String:
  U32.show(x)

def w(x: U32) -> U.U64:
  U.U64{0, x}

def z() -> U.U64:
  U.U64{0, 0}

def show_call(c: P.PsciCall) -> String:
  match c:
    case P.SmcccVersion{}:
      "SmcccVersion"
    case P.PsciVersion{}:
      "PsciVersion"
    case P.CpuOff{}:
      "CpuOff"
    case P.CpuOnCall{t, e, x}:
      "CpuOn " ++ h(t) ++ " " ++ h(e) ++ " " ++ h(x)
    case P.AffinityInfo{t, l}:
      "AffinityInfo " ++ h(t) ++ " " ++ h(l)
    case P.MigrateInfoType{}:
      "MigrateInfoType"
    case P.SystemOff{}:
      "SystemOff"
    case P.SystemReset{}:
      "SystemReset"
    case P.Features{f}:
      "Features " ++ u(f)
    case P.Unsupported{f}:
      "Unsupported " ++ u(f)

def show_effect(e: P.PsciEffect) -> String:
  match e:
    case P.NoEffect{}:
      "none"
    case P.StartCpu{c, e, x}:
      "start " ++ u(c) ++ " " ++ h(e) ++ " " ++ h(x)
    case P.StopCpu{}:
      "stop"
    case P.Off{}:
      "off"
    case P.Reset{}:
      "reset"

def show_on(on: +List<Bool>) -> String:
  match on:
    case Nil{}:
      ""
    case Con{True{}, t}:
      "1" ++ show_on(t)
    case Con{False{}, t}:
      "0" ++ show_on(t)

def show(r: P.PsciResult) -> String:
  match r:
    case P.PsciResult{P.PsciState{on}, x0, e}:
      "[" ++ show_on(on) ++ "] x0=" ++ h(x0) ++ " " ++ show_effect(e)

def dec(fid: U32, x1: U.U64, x2: U.U64, x3: U.U64) -> String:
  show_call(P.Psci.decode(w(fid), x1, x2, x3))

def st(on: +List<Bool>) -> P.PsciState:
  P.PsciState{on}

def run(self: U32, on: +List<Bool>, c: P.PsciCall) -> String:
  show(P.Psci.handle(self, P.PsciState{on}, c))

def feat(fid: U32) -> String:
  run(0, [True{}], P.Features{fid})

def main() -> IO(Unit):
  do IO<Unit>:
    # Boot state.
    T.eq_str("boot 0 cpus", show(P.PsciResult{P.PsciState.boot(0n), z(), P.NoEffect{}}), "[] x0=0x0 none")
    T.eq_str("boot 1 cpu", show(P.PsciResult{P.PsciState.boot(1n), z(), P.NoEffect{}}), "[1] x0=0x0 none")
    T.eq_str("boot 4 cpus", show(P.PsciResult{P.PsciState.boot(4n), z(), P.NoEffect{}}), "[1000] x0=0x0 none")
    # Decode: every id, high word of x0 ignored, arguments passed through.
    T.eq_str("decode smccc version", dec(2147483648, z(), z(), z()), "SmcccVersion")
    T.eq_str("decode cpu_off", dec(2214592514, w(7), z(), z()), "CpuOff")
    T.eq_str("decode cpu_on 64-bit args", dec(3288334339, U.U64{1, 2}, U.U64{3, 4}, U.U64{5, 6}), "CpuOn 0x100000002 0x300000004 0x500000006")
    T.eq_str("decode affinity_info", dec(3288334340, w(1), w(0), w(9)), "AffinityInfo 0x1 0x0")
    T.eq_str("decode migrate_info_type", dec(2214592518, z(), z(), z()), "MigrateInfoType")
    T.eq_str("decode features keeps low word", dec(2214592522, U.U64{1, 2147483648}, z(), z()), "Features 2147483648")
    T.eq_str("decode high word of id", show_call(P.Psci.decode(U.U64{4294967295, 2214592521}, z(), z(), z())), "SystemReset")
    # 0x84000003 / 0x84000004: the 32-bit CPU_ON and AFFINITY_INFO are not implemented.
    T.eq_str("decode cpu_on 32-bit", dec(2214592515, w(1), z(), z()), "Unsupported 2214592515")
    T.eq_str("decode affinity_info 32-bit", dec(2214592516, w(1), z(), z()), "Unsupported 2214592516")
    # 0x84000001 CPU_SUSPEND, 0xC4000012 SYSTEM_RESET2 (64), 0
    T.eq_str("decode cpu_suspend", dec(2214592513, z(), z(), z()), "Unsupported 2214592513")
    T.eq_str("decode system_reset2", dec(3288334354, z(), z(), z()), "Unsupported 3288334354")
    T.eq_str("decode zero", dec(0, z(), z(), z()), "Unsupported 0")
    # Versions and simple answers leave the state alone.
    T.eq_str("psci version", run(1, [True{}, True{}], P.PsciVersion{}), "[11] x0=0x10001 none")
    T.eq_str("smccc version", run(0, [True{}, False{}], P.SmcccVersion{}), "[10] x0=0x10001 none")
    T.eq_str("migrate_info_type", run(0, [True{}, False{}], P.MigrateInfoType{}), "[10] x0=0x2 none")
    T.eq_str("unsupported", run(0, [True{}], P.Unsupported{0}), "[1] x0=0xffffffffffffffff none")
    T.eq_str("system_off", run(0, [True{}, True{}], P.SystemOff{}), "[11] x0=0x0 off")
    T.eq_str("system_reset", run(1, [True{}, True{}], P.SystemReset{}), "[11] x0=0x0 reset")
    # CPU_ON.
    T.eq_str("cpu_on last cpu", run(0, [True{}, False{}, False{}, False{}], P.CpuOnCall{w(3), U.U64{1, 4096}, U.U64{4294967295, 7}}), "[1001] x0=0x0 start 3 0x100001000 0xffffffff00000007")
    T.eq_str("cpu_on from a secondary", run(2, [True{}, False{}, True{}], P.CpuOnCall{w(1), w(64), z()}), "[111] x0=0x0 start 1 0x40 0x0")
    T.eq_str("cpu_on self", run(1, [True{}, True{}], P.CpuOnCall{w(1), w(64), z()}), "[11] x0=0xfffffffffffffffc none")
    T.eq_str("cpu_on index = ncpus", run(0, [True{}, False{}], P.CpuOnCall{w(2), w(64), z()}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("cpu_on aff0 255", run(0, [True{}, False{}], P.CpuOnCall{w(255), w(64), z()}), "[10] x0=0xfffffffffffffffe none")
    # Aff1 (bits [15:8]) and Aff3 (bits [39:32]) name CPUs this machine lacks.
    T.eq_str("cpu_on aff1 set", run(0, [True{}, False{}], P.CpuOnCall{w(257), w(64), z()}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("cpu_on aff3 set", run(0, [True{}, False{}], P.CpuOnCall{U.U64{1, 1}, w(64), z()}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("cpu_on no cpus", run(0, [], P.CpuOnCall{w(0), w(64), z()}), "[] x0=0xfffffffffffffffe none")
    # CPU_OFF.
    T.eq_str("cpu_off cpu 0", run(0, [True{}, True{}], P.CpuOff{}), "[01] x0=0x0 stop")
    T.eq_str("cpu_off last", run(2, [True{}, True{}, True{}], P.CpuOff{}), "[110] x0=0x0 stop")
    T.eq_str("cpu_off out of range self", run(5, [True{}, True{}], P.CpuOff{}), "[11] x0=0x0 stop")
    # Off then on again.
    T.eq_str("cpu_on after cpu_off", show(P.Psci.handle(0, P.PsciState{[True{}, False{}]}, P.CpuOnCall{w(1), w(64), z()})), "[11] x0=0x0 start 1 0x40 0x0")
    # AFFINITY_INFO.
    T.eq_str("affinity_info secondary on", run(0, [True{}, False{}, True{}], P.AffinityInfo{w(2), z()}), "[101] x0=0x0 none")
    T.eq_str("affinity_info cpu 0 off", run(1, [False{}, True{}], P.AffinityInfo{w(0), z()}), "[01] x0=0x1 none")
    T.eq_str("affinity_info out of range", run(0, [True{}, False{}], P.AffinityInfo{w(2), z()}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("affinity_info aff1 set", run(0, [True{}, False{}], P.AffinityInfo{w(256), z()}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("affinity_info level 1", run(0, [True{}, False{}], P.AffinityInfo{w(0), w(1)}), "[10] x0=0xfffffffffffffffe none")
    T.eq_str("affinity_info level high word", run(0, [True{}, False{}], P.AffinityInfo{w(0), U.U64{1, 0}}), "[10] x0=0xfffffffffffffffe none")
    # PSCI_FEATURES: 0 for every id decode knows, NOT_SUPPORTED otherwise.
    T.eq_str("features smccc_version", feat(2147483648), "[1] x0=0x0 none")
    T.eq_str("features psci_version", feat(2214592512), "[1] x0=0x0 none")
    T.eq_str("features cpu_off", feat(2214592514), "[1] x0=0x0 none")
    T.eq_str("features affinity_info", feat(3288334340), "[1] x0=0x0 none")
    T.eq_str("features migrate_info_type", feat(2214592518), "[1] x0=0x0 none")
    T.eq_str("features system_off", feat(2214592520), "[1] x0=0x0 none")
    T.eq_str("features system_reset", feat(2214592521), "[1] x0=0x0 none")
    T.eq_str("features psci_features", feat(2214592522), "[1] x0=0x0 none")
    T.eq_str("features cpu_on 32-bit", feat(2214592515), "[1] x0=0xffffffffffffffff none")
    T.eq_str("features cpu_suspend", feat(2214592513), "[1] x0=0xffffffffffffffff none")
    T.eq_str("features zero", feat(0), "[1] x0=0xffffffffffffffff none")
