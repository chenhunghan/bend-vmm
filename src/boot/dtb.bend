import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../fdt/fdt.bend as F

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

type DtbCfg is Data:
  DtbCfg{ncpus: Nat, ram_size: U.U64, bootargs: String, initrd: Maybe<&2, Initrd>, virtio_slots: Nat}

# Lowercase hex without a 0x prefix or leading zeros: the unit address of a node.
def Dtb.unit(a: U.U64) -> String:
  String.drop(U.U64.show_hex(a), 2n)

def Dtb.tree(cfg: DtbCfg) -> F.Node:
  ?TODO

def Dtb.build(cfg: DtbCfg) -> +List<U32>:
  F.Fdt.build(Dtb.tree(cfg), 0)
