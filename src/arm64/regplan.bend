import Base

# The registers a Hypervisor.framework snapshot keeps for each vCPU, and in
# what order (laws/regplan.bend). host/hvf.c reads each key's register into
# an entry {u32 key, u64 value} (a register this macOS lacks fails to read
# and is left out) and a restore sets each entry it finds by its key:
#   0x10000 | n  hv_reg_t n: X0..X30 (0..30), PC (31), CPSR (34), FPCR (32),
#                FPSR (33)
#   0x20000 | n  system register n (hv_sys_reg_t: op0 << 14 | op1 << 11 |
#                CRn << 7 | CRm << 3 | op2)
#   0x30000 | n  half n of the SIMD registers (Q(n / 2), low half first)
#   0x50000 | n  GIC CPU interface register n (hv_gic_icc_reg_t), which
#                hv_gic_state leaves out
#   0x40000      the guest's virtual count (a restore continues from it)
# KVM lists its own registers (KVM_GET_REG_LIST) and needs no plan.

def Regs.key(kind: U32, n: U32) -> U32:
  ((kind << 16n : U32) .|. n : U32)

def Regs.range(n: Nat, +kind: U32, +i: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      Con{Regs.key(kind, i), Regs.range(p, kind, (i + 1 : U32))}

def Regs.keys(+kind: U32, ns: List<&2, U32>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      []
    case Con{n, t}:
      Con{Regs.key(kind, n), Regs.keys(kind, t)}

# X0..X30, PC, CPSR, FPCR, FPSR.
def Regs.general() -> List<&2, U32>:
  List.append(&2, U32, Regs.range(31n, 1, 0), Regs.keys(1, [31, 34, 32, 33]))

# The EL1 (and EL0) system state: debug breakpoints and watchpoints 0 and 1,
# MDCCINT, MDSCR, MPIDR, SCTLR, ACTLR, CPACR, TTBR0/1, TCR, the pointer
# authentication keys, SPSR, ELR, SP_EL0, AFSR0/1, ESR, FAR, PAR, MAIR, AMAIR,
# VBAR, CONTEXTIDR, TPIDR_EL1, SCXTNUM_EL1, CNTKCTL, CSSELR, TPIDR_EL0,
# TPIDRRO_EL0, TPIDR2_EL0, SCXTNUM_EL0, the virtual timer (CNTV_CTL, CVAL),
# SP_EL1, the physical timer (CNTP_CTL, CVAL).
def Regs.system() -> List<&2, U32>:
  [32772, 32773, 32774, 32775, 32780, 32781, 32782, 32783, 32784, 32786,
   49157, 49280, 49281, 49282, 49408, 49409, 49410, 49416, 49417, 49418,
   49419, 49424, 49425, 49426, 49427, 49432, 49433, 49664, 49665, 49672,
   49800, 49801, 49808, 49920, 50080, 50448, 50456, 50688, 50817, 50820,
   50823, 50952, 53248, 56962, 56963, 56965, 56967, 57113, 57114, 57864,
   57105, 57106]

# ICC_SRE, CTLR, PMR, BPR0, BPR1, AP0R0, AP1R0, IGRPEN0, IGRPEN1.
def Regs.icc() -> List<&2, U32>:
  [50789, 50788, 49712, 50755, 50787, 50756, 50760, 50790, 50791]

def Regs.hvf() -> List<&2, U32>:
  List.concat(&2, U32, [
    Regs.general(),
    Regs.keys(2, Regs.system()),
    Regs.range(64n, 3, 0),
    Regs.keys(5, Regs.icc()),
    [Regs.key(4, 0)]])
