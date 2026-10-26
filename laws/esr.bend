import Base
import ../src/lib/u64.bend as U
import ../src/arm64/esr.bend as E

# Frozen spec for src/arm64/esr.bend. Syndromes are built from the Arm ARM
# field layout; the hex form of each is in its comment.

def z() -> U.U64:
  U.U64{0, 0}

law esr.ec_hvc:
  # 0x5A000000: EC 0x16, IL
  {E.Esr.ec(U.U64{0, 1509949440}) == 22 : U32}

law esr.ec_ignores_high_word:
  {E.Esr.ec(U.U64{4294967295, 1509949440}) == 22 : U32}

law esr.iss_hvc5:
  {E.Esr.iss(U.U64{0, 1509949445}) == 5 : U32}

law esr.hvc0:
  {E.Trap.decode(U.U64{0, 1509949440}, z(), z()) == E.Hvc{0} : E.Trap}

law esr.hvc5:
  {E.Trap.decode(U.U64{0, 1509949445}, z(), z()) == E.Hvc{5} : E.Trap}

law esr.smc0:
  # 0x5E000000
  {E.Trap.decode(U.U64{0, 1577058304}, z(), z()) == E.Smc{0} : E.Trap}

law esr.wfi:
  {E.Trap.decode(U.U64{0, 100663296}, z(), z()) == E.Wfx{False{}} : E.Trap}

law esr.wfe:
  {E.Trap.decode(U.U64{0, 100663297}, z(), z()) == E.Wfx{True{}} : E.Trap}

law esr.store32:
  # `str w1, [x0]`: 0x93810040 = EC 0x24, IL, ISV, SAS 2, SRT 1, WnR.
  # The upper half of x1 is not stored.
  {E.Trap.decode(U.U64{0, 2474704960}, U.U64{0, 150994944}, U.U64{7, 65}) == E.Mmio{U.U64{0, 150994944}, True{}, 4, 1, U.U64{0, 65}, False{}, False{}} : E.Trap}

law esr.load64:
  # `ldr x3, [x0]`: 0x93C38000 = ISV, SAS 3, SRT 3, SF.
  {E.Trap.decode(U.U64{0, 2479063040}, U.U64{0, 167772160}, U.U64{9, 9}) == E.Mmio{U.U64{0, 167772160}, False{}, 8, 3, U.U64{0, 0}, False{}, True{}} : E.Trap}

law esr.load8_signed:
  # `ldrsb w2, [x0]`: 0x93220000 = ISV, SAS 0, SSE, SRT 2.
  {E.Trap.decode(U.U64{0, 2468478976}, U.U64{0, 4096}, z()) == E.Mmio{U.U64{0, 4096}, False{}, 1, 2, U.U64{0, 0}, True{}, False{}} : E.Trap}

law esr.no_isv:
  # 0x92000040: ISV clear.
  {E.Trap.decode(U.U64{0, 2449473600}, U.U64{0, 4096}, z()) == E.MmioNoIsv{U.U64{0, 4096}} : E.Trap}

law esr.sysreg:
  # MRS x5, op0 3 op1 3 CRn 14 CRm 0 op2 0 (CNTFRQ_EL0): 0x6230F8A1.
  {E.Trap.decode(U.U64{0, 1647376545}, z(), z()) == E.SysReg{3, 3, 14, 0, 0, 5, True{}} : E.Trap}

law esr.insn_abort:
  # 0x82000000
  {E.Trap.decode(U.U64{0, 2181038080}, U.U64{0, 8192}, z()) == E.InsnAbort{U.U64{0, 8192}} : E.Trap}

law esr.other:
  # EC 0x07 (FP access): 0x1E000000
  {E.Trap.decode(U.U64{0, 503316480}, z(), z()) == E.Other{7} : E.Trap}

# Proposed: general laws added by the esr implementation.

law esr.decode_ignores_high_word:
  # ESR_EL2[63:32] (ISS2 and RES0) never changes the decode.
  for h: U32
  for l: U32
  for ipa: U.U64
  for xt: U.U64
  {E.Trap.decode(U.U64{h, l}, ipa, xt) == E.Trap.decode(U.U64{0, l}, ipa, xt) : E.Trap}

law esr.load_value_zero:
  # `ldr w1, [x0]`: 0x93810000. A read never carries xt, whatever it holds.
  for ipa: U.U64
  for xt: U.U64
  {E.Trap.decode(U.U64{0, 2474704896}, ipa, xt) == E.Mmio{ipa, False{}, 4, 1, U.U64{0, 0}, False{}, False{}} : E.Trap}
