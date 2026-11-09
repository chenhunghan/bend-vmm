import Base

# The vGIC's state as a replay (laws/gicplan.bend): what a KVM snapshot
# reads from the in-kernel GICv3 and the order a restore writes it back in.
# host/hvf.c carries the plan out: it reads each kept register (one KVM does
# not have is left out) and writes the entries back in order with
# KVM_SET_DEVICE_ATTR. Each set of enable, pending or active bits comes after
# a write of all ones to its clear register, so the restored bits are exactly
# the saved ones. The order follows the architecture's dependencies:
#   distributor control (GICD_CTLR)
#   each redistributor: group, configuration, priorities of the SGIs and
#     PPIs, then their pending, active and enabled bits
#   the SPIs: groups, priorities, configuration, routing, line levels, then
#     pending and active bits, then enabled bits
#   each CPU interface: ICC_SRE, CTLR, PMR, BPR0, BPR1, AP0R0..3, AP1R0..3,
#     IGRPEN0, IGRPEN1 (64-bit)
#
# On the wire each step is five words: [op, group, width, attr hi, attr lo],
# op 0 keeps (reads) the register, 1 writes all ones to it. Groups are KVM's
# (KVM_DEV_ARM_VGIC_GRP_*): 1 distributor, 5 redistributor, 6 CPU sysregs,
# 7 level info. A redistributor's or CPU interface's vCPU is attr hi
# (KVM_DEV_ARM_VGIC_V3_MPIDR_SHIFT is 32).

def Gic.dist() -> U32:
  1

def Gic.redist() -> U32:
  5

def Gic.cpu() -> U32:
  6

def Gic.level() -> U32:
  7

# The SPIs the VM has: KVM_DEV_ARM_VGIC_GRP_NR_IRQS, as host/hvf.c sets it.
def Gic.nirqs() -> U32:
  256

def Gic.keep(g: U32, w: U32, hi: U32, lo: U32) -> List<&2, U32>:
  [0, g, w, hi, lo]

def Gic.clear(g: U32, hi: U32, lo: U32) -> List<&2, U32>:
  [1, g, 4, hi, lo]

# clear all at off_clear, then keep the saved bits of off_set
def Gic.bits(+g: U32, +hi: U32, off_set: U32, off_clear: U32) -> List<&2, U32>:
  List.append(&2, U32, Gic.clear(g, hi, off_clear), Gic.keep(g, 4, hi, off_set))

def Gic.redist_prio(n: Nat, +cpu: U32, +i: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.keep(Gic.redist(), 4, cpu, (66560 + (4 * i : U32) : U32)), Gic.redist_prio(p, cpu, (i + 1 : U32)))

# A redistributor: IGROUPR0 (0x10080), ICFGR0/1 (0x10c00, 0x10c04),
# IPRIORITYR0..7 (0x10400), ISPENDR0/ICPENDR0 (0x10200, 0x10280),
# ISACTIVER0/ICACTIVER0 (0x10300, 0x10380), ISENABLER0/ICENABLER0 (0x10100,
# 0x10180).
def Gic.redist_one(+cpu: U32) -> List<&2, U32>:
  List.concat(&2, U32, [
    Gic.keep(Gic.redist(), 4, cpu, 65664),
    Gic.keep(Gic.redist(), 4, cpu, 68608),
    Gic.keep(Gic.redist(), 4, cpu, 68612),
    Gic.redist_prio(8n, cpu, 0),
    Gic.bits(Gic.redist(), cpu, 66048, 66176),
    Gic.bits(Gic.redist(), cpu, 66304, 66432),
    Gic.bits(Gic.redist(), cpu, 65792, 65920)])

def Gic.redists(n: Nat, +cpu: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.redist_one(cpu), Gic.redists(p, (cpu + 1 : U32)))

# The SPI sections, from irq 32 on, each n steps of its stride.
# IGROUPR (0x80 + irq / 8), every 32 irqs.
def Gic.spi_group(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.keep(Gic.dist(), 4, 0, (128 + (irq >> 3n : U32) : U32)), Gic.spi_group(p, (irq + 32 : U32)))

# IPRIORITYR (0x400 + irq), every 4 irqs.
def Gic.spi_prio(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.keep(Gic.dist(), 4, 0, (1024 + irq : U32)), Gic.spi_prio(p, (irq + 4 : U32)))

# ICFGR (0xc00 + irq / 4), every 16 irqs.
def Gic.spi_cfg(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.keep(Gic.dist(), 4, 0, (3072 + (irq >> 2n : U32) : U32)), Gic.spi_cfg(p, (irq + 16 : U32)))

# IROUTER (0x6000 + 8 * irq), low half then high, every irq.
def Gic.spi_route(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +at = (24576 + (irq << 3n : U32) : U32)
      List.concat(&2, U32, [Gic.keep(Gic.dist(), 4, 0, at), Gic.keep(Gic.dist(), 4, 0, (at + 4 : U32)), Gic.spi_route(p, (irq + 1 : U32))])

# The line levels (VGIC_LEVEL_INFO_LINE_LEVEL, 0, at bit 10), every 32 irqs.
def Gic.spi_level(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.keep(Gic.level(), 4, 0, irq), Gic.spi_level(p, (irq + 32 : U32)))

# ISPENDR/ICPENDR (0x200, 0x280) and ISACTIVER/ICACTIVER (0x300, 0x380), every
# 32 irqs.
def Gic.spi_pend(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +o = (irq >> 3n : U32)
      List.concat(&2, U32, [Gic.bits(Gic.dist(), 0, (512 + o : U32), (640 + o : U32)), Gic.bits(Gic.dist(), 0, (768 + o : U32), (896 + o : U32)), Gic.spi_pend(p, (irq + 32 : U32))])

# ISENABLER/ICENABLER (0x100, 0x180), every 32 irqs.
def Gic.spi_enable(n: Nat, +irq: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +o = (irq >> 3n : U32)
      List.append(&2, U32, Gic.bits(Gic.dist(), 0, (256 + o : U32), (384 + o : U32)), Gic.spi_enable(p, (irq + 32 : U32)))

# The SPI count (irqs 32 .. nirqs) in steps of the stride.
def Gic.count(+nirqs: U32, stride: U32) -> Nat:
  U32.to_nat(((nirqs - 32 : U32) / stride : U32))

def Gic.spis(+nirqs: U32) -> List<&2, U32>:
  List.concat(&2, U32, [
    Gic.spi_group(Gic.count(nirqs, 32), 32),
    Gic.spi_prio(Gic.count(nirqs, 4), 32),
    Gic.spi_cfg(Gic.count(nirqs, 16), 32),
    Gic.spi_route(Gic.count(nirqs, 1), 32),
    Gic.spi_level(Gic.count(nirqs, 32), 32),
    Gic.spi_pend(Gic.count(nirqs, 32), 32),
    Gic.spi_enable(Gic.count(nirqs, 32), 32)])

# The CPU interface registers as KVM names them (op0 3, op1 0, then CRn, CRm,
# op2: op0 << 14 | op1 << 11 | CRn << 7 | CRm << 3 | op2).
def Gic.icc() -> List<&2, U32>:
  [50789,  # ICC_SRE_EL1     (3, 0, 12, 12, 5)
   50788,  # ICC_CTLR_EL1    (3, 0, 12, 12, 4)
   49712,  # ICC_PMR_EL1     (3, 0, 4, 6, 0)
   50755,  # ICC_BPR0_EL1    (3, 0, 12, 8, 3)
   50787,  # ICC_BPR1_EL1    (3, 0, 12, 12, 3)
   50756, 50757, 50758, 50759,  # ICC_AP0R0..3_EL1 (3, 0, 12, 8, 4..7)
   50760, 50761, 50762, 50763,  # ICC_AP1R0..3_EL1 (3, 0, 12, 9, 0..3)
   50790,  # ICC_IGRPEN0_EL1 (3, 0, 12, 12, 6)
   50791]  # ICC_IGRPEN1_EL1 (3, 0, 12, 12, 7)

def Gic.icc_one(+cpu: U32, rs: List<&2, U32>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      []
    case Con{r, t}:
      List.append(&2, U32, Gic.keep(Gic.cpu(), 8, cpu, r), Gic.icc_one(cpu, t))

def Gic.iccs(n: Nat, +cpu: U32) -> List<&2, U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      List.append(&2, U32, Gic.icc_one(cpu, Gic.icc()), Gic.iccs(p, (cpu + 1 : U32)))

# The replay for a VM of cpus vCPUs and nirqs interrupts (a multiple of 32).
def Gic.plan(+cpus: U32, +nirqs: U32) -> List<&2, U32>:
  List.concat(&2, U32, [
    Gic.keep(Gic.dist(), 4, 0, 0),
    Gic.redists(U32.to_nat(cpus), 0),
    Gic.spis(nirqs),
    Gic.iccs(U32.to_nat(cpus), 0)])
