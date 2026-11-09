import Base
import ../src/arm64/regplan.bend as R

# Spec for src/arm64/regplan.bend: the registers a Hypervisor.framework
# snapshot keeps.

# 31 X registers, PC, CPSR, FPCR, FPSR, 52 system registers, 64 SIMD halves,
# 9 GIC CPU interface registers, the virtual count.
law regplan.count:
  {List.length(&2, U32, R.Regs.hvf()) == 161n : Nat}

# X0 first; then X30 and PC (hv_reg_t 31) at 0x1001e and 0x1001f.
law regplan.first:
  {List.take(&2, U32, R.Regs.hvf(), 1n) == [65536] : List<&2, U32>}

law regplan.pc:
  {List.take(&2, U32, List.drop(&2, U32, R.Regs.hvf(), 30n), 2n) == [65566, 65567] : List<&2, U32>}

# SCTLR_EL1 (0xc080) is a system register key (0x2c080).
law regplan.sctlr:
  {List.take(&2, U32, List.drop(&2, U32, R.Regs.hvf(), 46n), 1n) == [180352] : List<&2, U32>}

# The SIMD halves follow the system registers: Q0's low half (0x30000).
law regplan.simd:
  {List.take(&2, U32, List.drop(&2, U32, R.Regs.hvf(), 87n), 1n) == [196608] : List<&2, U32>}

# ICC_SRE_EL1 (0xc665) as a GIC key (0x5c665); the virtual count last.
law regplan.icc:
  {List.take(&2, U32, List.drop(&2, U32, R.Regs.hvf(), 151n), 1n) == [378469] : List<&2, U32>}

law regplan.vcount_last:
  {List.drop(&2, U32, R.Regs.hvf(), 160n) == [262144] : List<&2, U32>}
