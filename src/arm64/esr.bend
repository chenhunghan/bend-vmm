import Base
import ../lib/u64.bend as U

# Decoding ESR_EL2, the syndrome of an exception taken from the guest
# (Arm ARM D24.2.40). EC is bits [31:26]; ISS is bits [24:0].

# Exception classes the VMM handles (decimal; hex in comments).
def Ec.wfx() -> U32:
  1            # 0x01 WFI / WFE
def Ec.hvc64() -> U32:
  22           # 0x16 HVC from AArch64
def Ec.smc64() -> U32:
  23           # 0x17 SMC from AArch64
def Ec.sysreg() -> U32:
  24           # 0x18 MSR / MRS / system instruction
def Ec.iabt_lower() -> U32:
  32           # 0x20 instruction abort from a lower EL
def Ec.dabt_lower() -> U32:
  36           # 0x24 data abort from a lower EL

# A decoded trap. Sizes are in bytes (1, 2, 4 or 8).
type Trap is Data:
  # A data abort with a valid syndrome (ISV = 1): an MMIO access.
  # value is the store data (xt truncated to size) for writes, zero for reads.
  # srt is the transfer register (31 = XZR); sse asks to sign-extend a load;
  # sf says the register is 64-bit.
  Mmio{ipa: U.U64, write: Bool, size: U32, srt: U32, value: U.U64, sse: Bool, sf: Bool}
  # A data abort without a valid syndrome; the VMM cannot emulate it.
  MmioNoIsv{ipa: U.U64}
  Hvc{imm: U32}
  Smc{imm: U32}
  # WFI (wfe False) or WFE (wfe True).
  Wfx{wfe: Bool}
  # MSR/MRS: op0 op1 crn crm op2 name the register, rt the GPR, read is MRS.
  SysReg{op0: U32, op1: U32, crn: U32, crm: U32, op2: U32, rt: U32, read: Bool}
  InsnAbort{ipa: U.U64}
  # Any other class, with its EC.
  Other{ec: U32}

# EC, bits [31:26] of the syndrome.
def Esr.ec(esr: U.U64) -> U32:
  ?TODO

# ISS, bits [24:0] of the syndrome.
def Esr.iss(esr: U.U64) -> U32:
  ?TODO

# Decodes an exception exit. ipa is the faulting IPA the host reports and
# xt the value of the register ISS.SRT names (both as in RawExit).
def Trap.decode(esr: U.U64, ipa: U.U64, xt: U.U64) -> Trap:
  ?TODO
