import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../fdt/fdt.bend as F
import ../vmm/layout.bend as Lay

# The device tree this VMM hands to Linux: the machine of src/vmm/layout.bend
# as a DTB. The tree, in this exact order (node unit addresses are lowercase
# hex without leading zeros; numbers below are hex like dtc prints them):
#
# / {
#   compatible = "linux,dummy-virt"; model = "bend-vmm";
#   #address-cells = <2>; #size-cells = <2>; interrupt-parent = <1>;
#   chosen {
#     bootargs = "<bootargs>"; stdout-path = "/pl011@9000000";
#     linux,initrd-start = <u64 start>; linux,initrd-end = <u64 end>;   (only with an initrd)
#   };
#   memory@40000000 { device_type = "memory"; reg = <0 0x40000000> <u64 ram_size>; };
#   cpus {
#     #address-cells = <1>; #size-cells = <0>;
#     cpu@<n> { device_type = "cpu"; compatible = "arm,arm-v8"; reg = <n>; enable-method = "psci"; };
#     ... for n in 0 .. ncpus-1
#   };
#   psci { compatible = "arm,psci-1.0", "arm,psci-0.2"; method = "hvc"; };
#   timer { compatible = "arm,armv8-timer"; interrupts = <1 13 4 1 14 4 1 11 4 1 10 4>; always-on; };
#   intc@8000000 {
#     compatible = "arm,gic-v3"; #interrupt-cells = <3>; interrupt-controller;
#     reg = <0 0x8000000 0 0x10000 0 0xc000000 0 0x2000000>; phandle = <1>;
#   };
#   apb-pclk {
#     compatible = "fixed-clock"; #clock-cells = <0>; clock-frequency = <24000000>;
#     clock-output-names = "clk24mhz"; phandle = <2>;
#   };
#   pl011@9000000 {
#     compatible = "arm,pl011", "arm,primecell"; reg = <0 0x9000000 0 0x1000>;
#     interrupts = <0 1 4>; clocks = <2 2>; clock-names = "uartclk", "apb_pclk";
#   };
#   pl031@9010000 {
#     compatible = "arm,pl031", "arm,primecell"; reg = <0 0x9010000 0 0x1000>;
#     interrupts = <0 2 4>; clocks = <2>; clock-names = "apb_pclk";
#   };
#   framebuffer@10000000 {                              (only with a display)
#     compatible = "simple-framebuffer"; reg = <0 0x10000000 0 0x1000000>;
#     width = <w>; height = <h>; stride = <4 w>; format = "a8r8g8b8";
#   };
#   virtio_mmio@<a000000 + 0x200 n> {
#     compatible = "virtio,mmio"; reg = <0 (0xa000000 + 0x200 n) 0 0x200>;
#     interrupts = <0 (16 + n) 1>; dma-coherent;
#   };
#   ... for n in 0 .. virtio_slots-1
# };
#
# The DTB is serialized with F.Fdt.build and boot CPU 0.

type Initrd is Data:
  Initrd{start: U.U64, end: U.U64}

# A framebuffer of width x height 32-bit pixels (a8r8g8b8).
type Display is Data:
  Display{width: U32, height: U32}

type DtbCfg is Data:
  DtbCfg{ncpus: Nat, ram_size: U.U64, bootargs: String, initrd: Maybe<&2, Initrd>, virtio_slots: Nat, display: Maybe<&2, Display>, flash: Bool}

# Lowercase hex without a 0x prefix or leading zeros: the unit address of a node.
def Dtb.unit(a: U.U64) -> String:
  String.drop(U.U64.show_hex(a), 2n)

# reg = <u64 ram_base> <u64 ram_size>, RAM at 0x4000_0000.
def Dtb.memory(ram_size: U.U64) -> F.Node:
  +base = Lay.Layout.ram_base()
  +reg = List.append(&2, U32, B.Bytes.be64(base), B.Bytes.be64(ram_size))
  F.Node{"memory@" ++ Dtb.unit(base), [F.Prop.str("device_type", "memory"), F.Prop{"reg", reg}], []}

def Dtb.initrd(m: Maybe<&2, Initrd>) -> +List<F.Prop>:
  match m:
    case None{}:
      []
    case Some{Initrd{start, end}}:
      [F.Prop.u64("linux,initrd-start", start), F.Prop.u64("linux,initrd-end", end)]

def Dtb.chosen(bootargs: String, m: Maybe<&2, Initrd>) -> F.Node:
  +head = {[F.Prop.str("bootargs", bootargs), F.Prop.str("stdout-path", "/pl011@" ++ Dtb.unit(Lay.Layout.uart_base()))] : +List<F.Prop>}
  F.Node{"chosen", List.append(&2, F.Prop, head, Dtb.initrd(m)), []}

def Dtb.cpu(+n: U32) -> F.Node:
  +props = {[F.Prop.str("device_type", "cpu"), F.Prop.str("compatible", "arm,arm-v8"), F.Prop.u32("reg", n), F.Prop.str("enable-method", "psci")] : +List<F.Prop>}
  F.Node{"cpu@" ++ Dtb.unit(U.U64{0, n}), props, []}

# virtio-mmio slot n: 512 bytes at Layout.virtio_slot(n), SPI 16 + n, edge.
def Dtb.virtio(+n: U32) -> F.Node:
  +a = Lay.Layout.virtio_slot(n)
  +props = {[F.Prop.str("compatible", "virtio,mmio"), F.Prop.cells("reg", [U.U64.hi(a), U.U64.lo(a), 0, Lay.Layout.virtio_slot_size()]), F.Prop.cells("interrupts", [0, (16 + n : U32), 1]), F.Prop.empty("dma-coherent")] : +List<F.Prop>}
  F.Node{"virtio_mmio@" ++ Dtb.unit(a), props, []}

# The nodes mk(lo) .. mk(lo + n - 1), in order. A range of two or more splits
# in halves built in parallel. Each call spends one unit of fuel; n suffices.
def Dtb.range(~mk: U32 -> F.Node, fuel: Nat, +lo: U32, n: Nat) -> +List<F.Node>:
  match fuel:
    case 0n:
      []
    case 1n+p:
      match n:
        case 0n:
          []
        case 1n+q:
          match q:
            case 0n:
              [mk(lo)]
            case 1n+r:
              +p = p
              +all = {2n+r : Nat}
              +half = Nat.div(all, 2n)
              l h = Dtb.range(~mk, p, lo, half) Dtb.range(~mk, p, (lo + U32.from_nat(half) : U32), Nat.sub(all, half))
              List.append(&2, F.Node, l, h)

def Dtb.cpus(+ncpus: Nat) -> F.Node:
  +props = {[F.Prop.u32("#address-cells", 1), F.Prop.u32("#size-cells", 0)] : +List<F.Prop>}
  F.Node{"cpus", props, Dtb.range(~(n => Dtb.cpu(n)), ncpus, 0, ncpus)}

def Dtb.psci() -> F.Node:
  F.Node{"psci", [F.Prop.strs("compatible", ["arm,psci-1.0", "arm,psci-0.2"]), F.Prop.str("method", "hvc")], []}

# Secure, non-secure, virtual and hypervisor timer PPIs, level-high.
def Dtb.timer() -> F.Node:
  +irqs = {[1, 13, 4, 1, 14, 4, 1, 11, 4, 1, 10, 4] : +List<U32>}
  F.Node{"timer", [F.Prop.str("compatible", "arm,armv8-timer"), F.Prop.cells("interrupts", irqs), F.Prop.empty("always-on")], []}

def Dtb.intc() -> F.Node:
  +d = Lay.Layout.gicd_base()
  +r = Lay.Layout.gicr_base()
  +s = Lay.Layout.gicr_region_size()
  # GICD 64 KiB (65536), then the redistributor region.
  +reg = List.append(&2, U32, F.Fdt.cells([U.U64.hi(d), U.U64.lo(d), 0, 65536]), List.append(&2, U32, B.Bytes.be64(r), B.Bytes.be64(s)))
  +props = {[F.Prop.str("compatible", "arm,gic-v3"), F.Prop.u32("#interrupt-cells", 3), F.Prop.empty("interrupt-controller"), F.Prop{"reg", reg}, F.Prop.u32("phandle", 1)] : +List<F.Prop>}
  F.Node{"intc@" ++ Dtb.unit(d), props, []}

def Dtb.clock() -> F.Node:
  +props = {[F.Prop.str("compatible", "fixed-clock"), F.Prop.u32("#clock-cells", 0), F.Prop.u32("clock-frequency", 24000000), F.Prop.str("clock-output-names", "clk24mhz"), F.Prop.u32("phandle", 2)] : +List<F.Prop>}
  F.Node{"apb-pclk", props, []}

def Dtb.uart() -> F.Node:
  +a = Lay.Layout.uart_base()
  # 4 KiB (4096); SPI 1 (INTID 33 - 32), level-high; clocks = apb-pclk twice.
  +props = {[F.Prop.strs("compatible", ["arm,pl011", "arm,primecell"]), F.Prop.cells("reg", [U.U64.hi(a), U.U64.lo(a), 0, 4096]), F.Prop.cells("interrupts", [0, (Lay.Layout.uart_intid() - 32 : U32), 4]), F.Prop.cells("clocks", [2, 2]), F.Prop.strs("clock-names", ["uartclk", "apb_pclk"])] : +List<F.Prop>}
  F.Node{"pl011@" ++ Dtb.unit(a), props, []}

def Dtb.root_props() -> +List<F.Prop>:
  [F.Prop.str("compatible", "linux,dummy-virt"), F.Prop.str("model", "bend-vmm"), F.Prop.u32("#address-cells", 2), F.Prop.u32("#size-cells", 2), F.Prop.u32("interrupt-parent", 1)]

def Dtb.rtc() -> F.Node:
  +a = Lay.Layout.rtc_base()
  # 4 KiB; SPI 2 (INTID 34 - 32), level-high; clocked by apb-pclk.
  +props = {[F.Prop.strs("compatible", ["arm,pl031", "arm,primecell"]), F.Prop.cells("reg", [U.U64.hi(a), U.U64.lo(a), 0, 4096]), F.Prop.cells("interrupts", [0, (Lay.Layout.rtc_intid() - 32 : U32), 4]), F.Prop.cells("clocks", [2]), F.Prop.str("clock-names", "apb_pclk")] : +List<F.Prop>}
  F.Node{"pl031@" ++ Dtb.unit(a), props, []}

def Dtb.fb(d: Display) -> F.Node:
  match d:
    case Display{+w, h}:
      +a = Lay.Layout.fb_base()
      +props = {[F.Prop.str("compatible", "simple-framebuffer"), F.Prop.cells("reg", [U.U64.hi(a), U.U64.lo(a), 0, Lay.Layout.fb_size()]), F.Prop.u32("width", w), F.Prop.u32("height", h), F.Prop.u32("stride", (w * 4 : U32)), F.Prop.str("format", "a8r8g8b8")] : +List<F.Prop>}
      F.Node{"framebuffer@" ++ Dtb.unit(a), props, []}

def Dtb.fbs(d: Maybe<&2, Display>) -> +List<F.Node>:
  match d:
    case None{}:
      []
    case Some{x}:
      [Dtb.fb(x)]

# The two UEFI flash banks (--firmware), one cfi-flash node as on QEMU's
# virt machine: bank 0 the firmware, bank 1 the variable store.
def Dtb.flash() -> F.Node:
  +a = Lay.Layout.flash1_base()
  +n = Lay.Layout.flash_size()
  +props = {[F.Prop.str("compatible", "cfi-flash"), F.Prop.cells("reg", [0, 0, 0, n, U.U64.hi(a), U.U64.lo(a), 0, n]), F.Prop.u32("bank-width", 4)] : +List<F.Prop>}
  F.Node{"flash@0", props, []}

def Dtb.flashes(on: Bool) -> +List<F.Node>:
  match on:
    case True{}:
      [Dtb.flash()]
    case False{}:
      []

def Dtb.tree(cfg: DtbCfg) -> F.Node:
  match cfg:
    case DtbCfg{ncpus, ram_size, bootargs, initrd, +slots, disp, fl}:
      +fixed = {List.append(&2, F.Node, [Dtb.chosen(bootargs, initrd), Dtb.memory(ram_size), Dtb.cpus(ncpus), Dtb.psci(), Dtb.timer(), Dtb.intc(), Dtb.clock(), Dtb.uart(), Dtb.rtc()], List.append(&2, F.Node, Dtb.flashes(fl), Dtb.fbs(disp))) : +List<F.Node>}
      F.Node{"", Dtb.root_props(), List.append(&2, F.Node, fixed, Dtb.range(~(n => Dtb.virtio(n)), slots, 0, slots))}

def Dtb.build(cfg: DtbCfg) -> +List<U32>:
  F.Fdt.build(Dtb.tree(cfg), 0)
