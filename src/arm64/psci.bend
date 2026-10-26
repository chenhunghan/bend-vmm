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

# A machine of ncpus CPUs with only CPU 0 on.
def PsciState.boot(ncpus: Nat) -> PsciState:
  ?TODO

# The call the guest makes with x0 (function id in its low 32 bits) .. x3.
def Psci.decode(x0: U.U64, x1: U.U64, x2: U.U64, x3: U.U64) -> PsciCall:
  ?TODO

# Answers a call from CPU `self`. CPU_ON of an index >= ncpus answers
# INVALID_PARAMETERS; of a CPU already on, ALREADY_ON; else SUCCESS and the
# StartCpu effect, marking the CPU on. CPU_OFF marks `self` off.
# AFFINITY_INFO (level 0) answers 0 for on, 1 for off. PSCI_FEATURES answers 0
# for every function id this module implements, NOT_SUPPORTED otherwise.
# MIGRATE_INFO_TYPE answers 2 (no trusted OS).
def Psci.handle(self: U32, s: PsciState, call: PsciCall) -> PsciResult:
  ?TODO
