import Base
import ../src/lib/u64.bend as U
import ../src/arm64/psci.bend as P

# Frozen spec for src/arm64/psci.bend.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def z() -> U.U64:
  U.U64{0, 0}

def not_supported() -> U.U64:
  U.U64{4294967295, 4294967295}

def x0_of(r: P.PsciResult) -> U.U64:
  match r:
    case P.PsciResult{s, x, e}:
      x

def effect_of(r: P.PsciResult) -> P.PsciEffect:
  match r:
    case P.PsciResult{s, x, e}:
      e

def state_of(r: P.PsciResult) -> P.PsciState:
  match r:
    case P.PsciResult{s, x, e}:
      s

def on_of(s: P.PsciState) -> +List<Bool>:
  match s:
    case P.PsciState{on}:
      on

law psci.boot:
  {P.PsciState.boot(3n) == P.PsciState{[True{}, False{}, False{}]} : P.PsciState}

law psci.decode_version:
  {P.Psci.decode(w(2214592512), z(), z(), z()) == P.PsciVersion{} : P.PsciCall}

law psci.decode_ignores_high_word:
  {P.Psci.decode(U.U64{1, 2214592512}, z(), z(), z()) == P.PsciVersion{} : P.PsciCall}

law psci.decode_cpu_on:
  {P.Psci.decode(w(3288334339), w(1), w(1073741824), w(42)) == P.CpuOnCall{w(1), w(1073741824), w(42)} : P.PsciCall}

law psci.decode_off:
  {P.Psci.decode(w(2214592520), z(), z(), z()) == P.SystemOff{} : P.PsciCall}

law psci.decode_reset:
  {P.Psci.decode(w(2214592521), z(), z(), z()) == P.SystemReset{} : P.PsciCall}

law psci.decode_features:
  {P.Psci.decode(w(2214592522), w(3288334339), z(), z()) == P.Features{3288334339} : P.PsciCall}

law psci.decode_unknown:
  # 0x84000005 (CPU_SUSPEND's neighbour MIGRATE) is not implemented.
  {P.Psci.decode(w(2214592517), z(), z(), z()) == P.Unsupported{2214592517} : P.PsciCall}

law psci.version:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.PsciVersion{})) == w(65537) : U.U64}

law psci.smccc_version:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.SmcccVersion{})) == w(65537) : U.U64}

law psci.cpu_on_ok:
  {P.Psci.handle(0, P.PsciState.boot(2n), P.CpuOnCall{w(1), w(1073741824), w(42)}) == P.PsciResult{P.PsciState{[True{}, True{}]}, z(), P.StartCpu{1, w(1073741824), w(42)}} : P.PsciResult}

law psci.cpu_on_already_on:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.CpuOnCall{w(0), z(), z()})) == U.U64{4294967295, 4294967292} : U.U64}

law psci.cpu_on_out_of_range:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.CpuOnCall{w(2), z(), z()})) == U.U64{4294967295, 4294967294} : U.U64}

law psci.cpu_off:
  {state_of(P.Psci.handle(1, P.PsciState{[True{}, True{}]}, P.CpuOff{})) == P.PsciState{[True{}, False{}]} : P.PsciState}

law psci.affinity_on:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.AffinityInfo{w(0), z()})) == z() : U.U64}

law psci.affinity_off:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(2n), P.AffinityInfo{w(1), z()})) == w(1) : U.U64}

law psci.system_off:
  {effect_of(P.Psci.handle(0, P.PsciState.boot(1n), P.SystemOff{})) == P.Off{} : P.PsciEffect}

law psci.system_reset:
  {effect_of(P.Psci.handle(0, P.PsciState.boot(1n), P.SystemReset{})) == P.Reset{} : P.PsciEffect}

law psci.features_cpu_on:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(1n), P.Features{3288334339})) == z() : U.U64}

law psci.features_unknown:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(1n), P.Features{2214592517})) == not_supported() : U.U64}

law psci.unsupported:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(1n), P.Unsupported{2214592517})) == not_supported() : U.U64}

law psci.migrate_info_type:
  {x0_of(P.Psci.handle(0, P.PsciState.boot(1n), P.MigrateInfoType{})) == w(2) : U.U64}

# General: answering a call never changes the number of CPUs.
law psci.handle_keeps_cpu_count:
  for self: U32
  for on: +List<Bool>
  for call: P.PsciCall
  {List.length(&2, Bool, on_of(state_of(P.Psci.handle(self, P.PsciState{on}, call)))) == List.length(&2, Bool, on) : Nat}
