import Base
import ../lib/u64.bend as U

# Where a device's interrupt is delivered (laws/irqroute.bend).
#
# A virtio-mmio device has one SPI, and Linux routes every SPI to one vCPU
# (vCPU 0 unless told otherwise). A request issued on another vCPU then
# completes in two hops: the SPI wakes vCPU 0, whose handler wakes the
# waiting task with an IPI. On Hypervisor.framework that IPI costs about
# 85 us, more than the request itself: a 4 KiB 9p read from vCPU 1 took
# 100 us, from vCPU 0 17 us (bend-vk8s's layer store, 2026-11-24).
#
# So an SPI raised while the exit of vCPU c is handled (its QueueNotify:
# the request was issued on c) goes to c: its GICD_IROUTER names c before
# the line is raised, and the completion is taken on the vCPU that waits for
# it, as a multi-queue device's would be. An SPI raised outside a vCPU exit
# (the host's events: network input, the console, timers) keeps the routing
# it has. SGIs and PPIs (INTID below 32) belong to one vCPU and are never
# routed; lowering a line needs no routing.
#
# An SPI has an active state: while it is handled on one vCPU the GIC does
# not signal it to another, so moving it between raises loses no interrupt.
# This overrides the routing the guest programmed for device SPIs.

# The cpu that interprets an effect outside any vCPU exit (host/main.bend
# passes it for the host's events).
def Route.none() -> U32:
  4294967295

# The first shared peripheral interrupt.
def Route.first_spi() -> U32:
  32

def Route.spi_target(spi: Bool, +cpu: U32) -> Maybe<&2, U32>:
  match spi:
    case True{}:
      Some{cpu}
    case False{}:
      None{}

# The vCPU an interrupt raised by an exit of `cpu` is routed to, if any:
# cpu itself, for an SPI raised high from a vCPU's exit.
def Route.target(+cpu: U32, +intid: U32, level: Bool) -> Maybe<&2, U32>:
  match level:
    case False{}:
      None{}
    case True{}:
      Route.spi_target(U32.is_ne(cpu, Route.none()) && U32.is_ge(intid, Route.first_spi()), cpu)

# The distributor offset of GICD_IROUTER<intid> (0x6000 + 8 * intid).
def Route.reg(intid: U32) -> U32:
  (24576 + (intid * 8 : U32) : U32)

# GICD_IROUTER's value naming vCPU cpu: Aff0 is the vCPU's index, as its
# MPIDR says (host/hvf.c), Interrupt_Routing_Mode 0 (that one PE).
def Route.irouter(cpu: U32) -> U.U64:
  U.U64{0, (cpu .&. 255 : U32)}
