import Base
import ../src/arm64/irqroute.bend as R
import ../src/lib/u64.bend as U

# A device's SPI goes to the vCPU whose exit raised it
# (src/arm64/irqroute.bend; bend-vk8s: 9p reads from a vCPU other than 0
# waited for an IPI per request; approved by the owner 2026-11-25).

# An SPI raised high from vCPU 1's exit goes to vCPU 1.
law irqroute.to_vcpu:
  {R.Route.target(1, 51, True{}) == Some{1} : Maybe<&2, U32>}

law irqroute.first_spi:
  {R.Route.target(3, 32, True{}) == Some{3} : Maybe<&2, U32>}

# Raised outside a vCPU exit (the host's events): routing is left as it is.
law irqroute.host_event:
  for intid: U32
  for level: Bool
  {R.Route.target(R.Route.none(), intid, level) == None{} : Maybe<&2, U32>}

# Lowering a line routes nothing.
law irqroute.lowered:
  for cpu: U32
  for intid: U32
  {R.Route.target(cpu, intid, False{}) == None{} : Maybe<&2, U32>}

# SGIs and PPIs (the timers' 27 and 30) are never routed.
law irqroute.ppi:
  {R.Route.target(0, 27, True{}) == None{} : Maybe<&2, U32>}

law irqroute.last_ppi:
  {R.Route.target(1, 31, True{}) == None{} : Maybe<&2, U32>}

# GICD_IROUTER<n> is at 0x6000 + 8n: 32 at 0x6100, 51 at 0x6198, 1019 at
# 0x7FD8.
law irqroute.reg_first:
  {R.Route.reg(32) == 24832 : U32}

law irqroute.reg_51:
  {R.Route.reg(51) == 24984 : U32}

law irqroute.reg_last:
  {R.Route.reg(1019) == 32728 : U32}

# The value names the vCPU by Aff0, routing mode 0.
law irqroute.irouter:
  {R.Route.irouter(5) == U.U64{0, 5} : U.U64}
