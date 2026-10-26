import Base
import ../lib/u64.bend as U

# PSCI 1.1 (Arm DEN 0022) and SMCCC version discovery, as the guest calls
# them with HVC #0: function id in W0, arguments in X1..X3, result in X0.
# Function ids (decimal; hex in comments):
#   SMCCC_VERSION      2147483648  0x80000000
#   PSCI_VERSION       2214592512  0x84000000
#   CPU_OFF            2214592514  0x84000002
#   CPU_ON (64-bit)    3288334339  0xC4000003
#   AFFINITY_INFO (64) 3288334340  0xC4000004
#   MIGRATE_INFO_TYPE  2214592518  0x84000006
#   SYSTEM_OFF         2214592520  0x84000008
#   SYSTEM_RESET       2214592521  0x84000009
#   PSCI_FEATURES      2214592522  0x8400000A
# Return codes are signed 64-bit: SUCCESS 0, NOT_SUPPORTED -1,
# INVALID_PARAMETERS -2, DENIED -3, ALREADY_ON -4. PSCI_VERSION answers
# 0x00010001 (1.1) and SMCCC_VERSION 0x00010001 (1.1).

type PsciCall is Data:
  SmcccVersion{}
  PsciVersion{}
  CpuOff{}
  # target is the MPIDR of the CPU to start; cpu index = Aff0 (bits [7:0]).
  CpuOnCall{target: U.U64, entry: U.U64, ctx: U.U64}
  AffinityInfo{target: U.U64, level: U.U64}
  MigrateInfoType{}
  SystemOff{}
  SystemReset{}
  Features{fid: U32}
  # Any other function id (answered NOT_SUPPORTED).
  Unsupported{fid: U32}

# What the VMM must do besides writing x0.
type PsciEffect is Data:
  NoEffect{}
  StartCpu{cpu: U32, entry: U.U64, ctx: U.U64}
  StopCpu{}
  Off{}
  Reset{}

# Which CPUs are powered on: on[i] for cpu i, ncpus long.
type PsciState is Data:
  PsciState{on: +List<Bool>}

type PsciResult is Data:
  PsciResult{state: PsciState, x0: U.U64, effect: PsciEffect}

# Function ids (decimal; hex in comments).
def Fid.smccc_version() -> U32:
  2147483648   # 0x80000000
def Fid.psci_version() -> U32:
  2214592512   # 0x84000000
def Fid.cpu_off() -> U32:
  2214592514   # 0x84000002
def Fid.cpu_on() -> U32:
  3288334339   # 0xC4000003
def Fid.affinity_info() -> U32:
  3288334340   # 0xC4000004
def Fid.migrate_info_type() -> U32:
  2214592518   # 0x84000006
def Fid.system_off() -> U32:
  2214592520   # 0x84000008
def Fid.system_reset() -> U32:
  2214592521   # 0x84000009
def Fid.features() -> U32:
  2214592522   # 0x8400000A

# Return codes, sign-extended to 64 bits.
def Ret.success() -> U.U64:
  U.U64{0, 0}
def Ret.not_supported() -> U.U64:
  U.U64{4294967295, 4294967295}   # -1
def Ret.invalid_parameters() -> U.U64:
  U.U64{4294967295, 4294967294}   # -2
def Ret.already_on() -> U.U64:
  U.U64{4294967295, 4294967292}   # -4

# Version 1.1 (major in [31:16], minor in [15:0]), for PSCI and SMCCC.
def Ret.version_1_1() -> U.U64:
  U.U64{0, 65537}   # 0x00010001

# n CPUs, all off.
def PsciState.all_off(n: Nat) -> +List<Bool>:
  match n:
    case 0n:
      []
    case 1n+p:
      False{} <> PsciState.all_off(p)

# A machine of ncpus CPUs with only CPU 0 on.
def PsciState.boot(ncpus: Nat) -> PsciState:
  match ncpus:
    case 0n:
      PsciState{[]}
    case 1n+p:
      PsciState{True{} <> PsciState.all_off(p)}

# Does decode know this function id? PSCI_FEATURES answers from it.
def Psci.implemented(+fid: U32) -> Bool:
  U32.is_eq(fid, Fid.smccc_version()) || U32.is_eq(fid, Fid.psci_version())
    || U32.is_eq(fid, Fid.cpu_off()) || U32.is_eq(fid, Fid.cpu_on())
    || U32.is_eq(fid, Fid.affinity_info()) || U32.is_eq(fid, Fid.migrate_info_type())
    || U32.is_eq(fid, Fid.system_off()) || U32.is_eq(fid, Fid.system_reset())
    || U32.is_eq(fid, Fid.features())

# The decoders below each test one id (from the list at the top, in reverse)
# and hand the rest to the one above.
def Psci.by_features(hit: Bool, +fid: U32, x1: U.U64) -> PsciCall:
  match hit:
    case True{}:
      Features{U.U64.lo(x1)}
    case False{}:
      Unsupported{fid}

def Psci.by_reset(hit: Bool, +fid: U32, x1: U.U64) -> PsciCall:
  match hit:
    case True{}:
      SystemReset{}
    case False{}:
      Psci.by_features(U32.is_eq(fid, Fid.features()), fid, x1)

def Psci.by_off(hit: Bool, +fid: U32, x1: U.U64) -> PsciCall:
  match hit:
    case True{}:
      SystemOff{}
    case False{}:
      Psci.by_reset(U32.is_eq(fid, Fid.system_reset()), fid, x1)

def Psci.by_migrate(hit: Bool, +fid: U32, x1: U.U64) -> PsciCall:
  match hit:
    case True{}:
      MigrateInfoType{}
    case False{}:
      Psci.by_off(U32.is_eq(fid, Fid.system_off()), fid, x1)

def Psci.by_affinity(hit: Bool, +fid: U32, x1: U.U64, x2: U.U64) -> PsciCall:
  match hit:
    case True{}:
      AffinityInfo{x1, x2}
    case False{}:
      Psci.by_migrate(U32.is_eq(fid, Fid.migrate_info_type()), fid, x1)

def Psci.by_cpu_on(hit: Bool, +fid: U32, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  match hit:
    case True{}:
      CpuOnCall{x1, x2, x3}
    case False{}:
      Psci.by_affinity(U32.is_eq(fid, Fid.affinity_info()), fid, x1, x2)

def Psci.by_cpu_off(hit: Bool, +fid: U32, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  match hit:
    case True{}:
      CpuOff{}
    case False{}:
      Psci.by_cpu_on(U32.is_eq(fid, Fid.cpu_on()), fid, x1, x2, x3)

def Psci.by_version(hit: Bool, +fid: U32, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  match hit:
    case True{}:
      PsciVersion{}
    case False{}:
      Psci.by_cpu_off(U32.is_eq(fid, Fid.cpu_off()), fid, x1, x2, x3)

def Psci.by_smccc(hit: Bool, +fid: U32, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  match hit:
    case True{}:
      SmcccVersion{}
    case False{}:
      Psci.by_version(U32.is_eq(fid, Fid.psci_version()), fid, x1, x2, x3)

# The call the guest makes with x0 (function id in its low 32 bits) .. x3.
def Psci.decode(x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  +fid = U.U64.lo(x0)
  Psci.by_smccc(U32.is_eq(fid, Fid.smccc_version()), fid, x1, x2, x3)

# The CPU index an MPIDR names: Aff0, when every other affinity bit is zero
# (the DTB gives cpu n the MPIDR n). None for any other MPIDR.
def Psci.index.of(ok: Bool, +lo: U32) -> Maybe<&2, Nat>:
  match ok:
    case True{}:
      Some{U32.to_nat(lo)}
    case False{}:
      None{}

def Psci.index(target: U.U64) -> Maybe<&2, Nat>:
  match target:
    case U.U64{hi, +lo}:
      Psci.index.of(U32.is_zero(hi) && U32.is_lt(lo, 256), lo)

# on[i], or None past the end.
def Psci.get(on: +List<Bool>, i: Nat) -> Maybe<&2, Bool>:
  match on i:
    case Nil{} _:
      None{}
    case Con{b, t} 0n:
      Some{b}
    case Con{b, t} 1n+p:
      Psci.get(t, p)

# on with on[i] = v; unchanged when i is past the end.
def Psci.set(on: +List<Bool>, i: Nat, v: Bool) -> +List<Bool>:
  match on i:
    case Nil{} _:
      []
    case Con{b, t} 0n:
      v <> t
    case Con{b, t} 1n+p:
      b <> Psci.set(t, p, v)

# The power state of the CPU an MPIDR names; None when there is no such CPU.
def Psci.lookup(+on: +List<Bool>, mi: Maybe<&2, Nat>) -> Maybe<&2, Bool>:
  match mi:
    case None{}:
      None{}
    case Some{i}:
      Psci.get(on, i)

# on with the CPU an MPIDR names marked v; unchanged when there is no such CPU.
def Psci.mark(on: +List<Bool>, mi: Maybe<&2, Nat>, v: Bool) -> +List<Bool>:
  match mi:
    case None{}:
      on
    case Some{i}:
      Psci.set(on, i, v)

# CPU_ON: x0 from the target's power state (None: no such CPU).
def Psci.cpu_on.x0(cur: Maybe<&2, Bool>) -> U.U64:
  match cur:
    case None{}:
      Ret.invalid_parameters()
    case Some{True{}}:
      Ret.already_on()
    case Some{False{}}:
      Ret.success()

def Psci.cpu_on.effect(cur: Maybe<&2, Bool>, +target: U.U64, entry: U.U64, ctx: U.U64) -> PsciEffect:
  match cur:
    case Some{False{}}:
      StartCpu{U.U64.lo(target), entry, ctx}
    case _:
      NoEffect{}

# AFFINITY_INFO: 0 on, 1 off; only level 0 is implemented.
def Psci.affinity.x0(level0: Bool, cur: Maybe<&2, Bool>) -> U.U64:
  match level0 cur:
    case True{} Some{True{}}:
      U.U64{0, 0}
    case True{} Some{False{}}:
      U.U64{0, 1}
    case _ _:
      Ret.invalid_parameters()

def Psci.features.x0(ok: Bool) -> U.U64:
  match ok:
    case True{}:
      Ret.success()
    case False{}:
      Ret.not_supported()

# Answers a call from CPU `self`. CPU_ON of an index >= ncpus answers
# INVALID_PARAMETERS; of a CPU already on, ALREADY_ON; else SUCCESS and the
# StartCpu effect, marking the CPU on. CPU_OFF marks `self` off.
# AFFINITY_INFO (level 0) answers 0 for on, 1 for off. PSCI_FEATURES answers 0
# for every function id this module implements, NOT_SUPPORTED otherwise.
# MIGRATE_INFO_TYPE answers 2 (no trusted OS).
# Every case builds the result directly, and CPU state changes only through
# Psci.mark and Psci.set, so the number of CPUs never changes.
def Psci.handle(self: U32, s: PsciState, call: PsciCall) -> PsciResult:
  match s call:
    case PsciState{on} SmcccVersion{}:
      PsciResult{PsciState{on}, Ret.version_1_1(), NoEffect{}}
    case PsciState{on} PsciVersion{}:
      PsciResult{PsciState{on}, Ret.version_1_1(), NoEffect{}}
    case PsciState{on} CpuOff{}:
      PsciResult{PsciState{Psci.set(on, U32.to_nat(self), False{})}, Ret.success(), StopCpu{}}
    case PsciState{+on} CpuOnCall{+target, entry, ctx}:
      # Marking a CPU that is on, or none, on again changes nothing.
      +mi = Psci.index(target)
      +cur = Psci.lookup(on, mi)
      PsciResult{PsciState{Psci.mark(on, mi, True{})}, Psci.cpu_on.x0(cur), Psci.cpu_on.effect(cur, target, entry, ctx)}
    case PsciState{+on} AffinityInfo{target, level}:
      PsciResult{PsciState{on}, Psci.affinity.x0(U.U64.is_zero(level), Psci.lookup(on, Psci.index(target))), NoEffect{}}
    case PsciState{on} MigrateInfoType{}:
      PsciResult{PsciState{on}, U.U64{0, 2}, NoEffect{}}
    case PsciState{on} SystemOff{}:
      PsciResult{PsciState{on}, Ret.success(), Off{}}
    case PsciState{on} SystemReset{}:
      PsciResult{PsciState{on}, Ret.success(), Reset{}}
    case PsciState{on} Features{fid}:
      PsciResult{PsciState{on}, Psci.features.x0(Psci.implemented(fid)), NoEffect{}}
    case PsciState{on} Unsupported{fid}:
      PsciResult{PsciState{on}, Ret.not_supported(), NoEffect{}}
