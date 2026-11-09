import Base
import ../src/arm64/gicplan.bend as G

# Spec for src/arm64/gicplan.bend: the vGIC replay a KVM snapshot keeps.

def steps(+ws: List<&2, U32>) -> Nat:
  Nat.div(List.length(&2, U32, ws), 5n)

# One vCPU, no SPIs: GICD_CTLR, the redistributor (3 + 8 priorities + 3 clear
# and keep pairs), the 15 CPU interface registers.
law gicplan.one_cpu:
  {steps(G.Gic.plan(1, 32)) == 33n : Nat}

# It starts with the distributor's control.
law gicplan.ctlr_first:
  {List.take(&2, U32, G.Gic.plan(1, 32), 5n) == [0, 1, 4, 0, 0] : List<&2, U32>}

# The redistributor's pending bits: all ones to ICPENDR0 (0x10280), then
# ISPENDR0 (0x10200) kept.
law gicplan.clear_then_keep:
  {List.take(&2, U32, List.drop(&2, U32, G.Gic.plan(1, 32), 60n), 10n) == [1, 5, 4, 0, 66176, 0, 5, 4, 0, 66048] : List<&2, U32>}

# A CPU interface register names its vCPU in attr hi and is 64-bit:
# ICC_IGRPEN1_EL1 of vCPU 1 ends the plan.
law gicplan.icc_last:
  {List.drop(&2, U32, G.Gic.plan(2, 32), 320n) == [0, 6, 8, 1, 50791] : List<&2, U32>}

# 32 SPIs: 1 group, 8 priority, 2 configuration, 64 routing, 1 level,
# 4 pending/active and 2 enable steps.
law gicplan.spis:
  {steps(G.Gic.spis(64)) == 82n : Nat}

# The VM bend-vmm makes (256 interrupts) with 4 vCPUs.
law gicplan.vm4:
  {steps(G.Gic.plan(4, G.Gic.nirqs())) == 703n : Nat}
