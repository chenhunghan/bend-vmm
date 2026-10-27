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
  ((U.U64.lo(esr) >> 26n) .&. 63 : U32)

# ISS, bits [24:0] of the syndrome.
def Esr.iss(esr: U.U64) -> U32:
  (U.U64.lo(esr) .&. 33554431 : U32)  # 0x1FFFFFF

# Bits [lo, lo+width) of a 32-bit word, with width < 32.
def Esr.field(+x: U32, lo: Nat, width: Nat) -> U32:
  ((x >> lo) .&. U32.not((4294967295 << width : U32)) : U32)

# Bit n of a 32-bit word.
def Esr.bit(+x: U32, n: Nat) -> Bool:
  U32.is_ne(Esr.field(x, n, 1n), 0)

# The bytes of a register an access of 2^sas bytes moves.
def Trap.size_mask(+sas: U32) -> U.U64:
  +ones = {4294967295 : U32}
  Bool.pick(U.U64, U32.is_eq(sas, 3), U.U64{ones, ones},
    Bool.pick(U.U64, U32.is_eq(sas, 2), U.U64{0, ones},
      Bool.pick(U.U64, U32.is_eq(sas, 1), U.U64{0, 65535}, U.U64{0, 255})))

# The store data: xt truncated to the access size. Zero for a read, and for a
# store from XZR (srt 31), whatever the host reports for xt.
def Trap.store_value(stores: Bool, +sas: U32, xt: U.U64) -> U.U64:
  match stores:
    case True{}:
      U.U64.and(xt, Trap.size_mask(sas))
    case False{}:
      U.U64.zero()

# A data abort. ISS: ISV [24], SAS [23:22], SSE [21], SRT [20:16], SF [15],
# WnR [6].
def Trap.dabt(isv: Bool, +iss: U32, ipa: U.U64, xt: U.U64) -> Trap:
  match isv:
    case True{}:
      +write = Esr.bit(iss, 6n)
      +sas = Esr.field(iss, 22n, 2n)
      +srt = Esr.field(iss, 16n, 5n)
      value = Trap.store_value(write && U32.is_ne(srt, 31), sas, xt)
      Mmio{ipa, write, (1 << U32.to_nat(sas) : U32), srt, value, Esr.bit(iss, 21n), Esr.bit(iss, 15n)}
    case False{}:
      MmioNoIsv{ipa}

# An MSR/MRS trap. ISS: Op0 [21:20], Op2 [19:17], Op1 [16:14], CRn [13:10],
# Rt [9:5], CRm [4:1], Direction [0] (1 = read, MRS).
def Trap.sysreg(+iss: U32) -> Trap:
  SysReg{Esr.field(iss, 20n, 2n), Esr.field(iss, 14n, 3n), Esr.field(iss, 10n, 4n), Esr.field(iss, 1n, 4n), Esr.field(iss, 17n, 3n), Esr.field(iss, 5n, 5n), Esr.bit(iss, 0n)}

# The decoders below each test one class and hand the rest to the one above.
def Trap.by_iabt(hit: Bool, +ec: U32, ipa: U.U64) -> Trap:
  match hit:
    case True{}:
      InsnAbort{ipa}
    case False{}:
      Other{ec}

def Trap.by_sysreg(hit: Bool, +ec: U32, +iss: U32, ipa: U.U64) -> Trap:
  match hit:
    case True{}:
      Trap.sysreg(iss)
    case False{}:
      Trap.by_iabt(U32.is_eq(ec, Ec.iabt_lower()), ec, ipa)

# SMC64 and HVC64: the immediate is ISS[15:0].
def Trap.by_smc(hit: Bool, +ec: U32, +iss: U32, ipa: U.U64) -> Trap:
  match hit:
    case True{}:
      Smc{Esr.field(iss, 0n, 16n)}
    case False{}:
      Trap.by_sysreg(U32.is_eq(ec, Ec.sysreg()), ec, iss, ipa)

def Trap.by_hvc(hit: Bool, +ec: U32, +iss: U32, ipa: U.U64) -> Trap:
  match hit:
    case True{}:
      Hvc{Esr.field(iss, 0n, 16n)}
    case False{}:
      Trap.by_smc(U32.is_eq(ec, Ec.smc64()), ec, iss, ipa)

# WFx: TI [1:0] is 0 WFI, 1 WFE, 2 WFIT, 3 WFET; bit 0 tells WFE from WFI.
def Trap.by_wfx(hit: Bool, +ec: U32, +iss: U32, ipa: U.U64) -> Trap:
  match hit:
    case True{}:
      Wfx{Esr.bit(iss, 0n)}
    case False{}:
      Trap.by_hvc(U32.is_eq(ec, Ec.hvc64()), ec, iss, ipa)

def Trap.by_dabt(hit: Bool, +ec: U32, +iss: U32, ipa: U.U64, xt: U.U64) -> Trap:
  match hit:
    case True{}:
      Trap.dabt(Esr.bit(iss, 24n), iss, ipa, xt)
    case False{}:
      Trap.by_wfx(U32.is_eq(ec, Ec.wfx()), ec, iss, ipa)

# Decodes an exception exit. ipa is the faulting IPA the host reports and
# xt the value of the register ISS.SRT names (both as in RawExit).
def Trap.decode(esr: U.U64, ipa: U.U64, xt: U.U64) -> Trap:
  +esr = esr
  # sequential: on every exit, and a native parallel let costs about 2.6 us
  # to spawn against a few ns of work here
  +ec = Esr.ec(esr)
  +iss = Esr.iss(esr)
  Trap.by_dabt(U32.is_eq(ec, Ec.dabt_lower()), ec, iss, ipa, xt)
