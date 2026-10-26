import Base
import ../src/lib/u64.bend as U
import ../src/fdt/fdt.bend as F
import ../src/boot/dtb.bend as D
import ./t.bend as T

# Tests for src/boot/dtb.bend beyond its laws: unit addresses, node counts
# and order, and the initrd properties of /chosen.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def cfg(ncpus: Nat, slots: Nat) -> D.DtbCfg:
  D.DtbCfg{ncpus, w(134217728), "", None{}, slots, None{}}

def with_initrd() -> D.DtbCfg:
  D.DtbCfg{1n, w(134217728), "quiet", Some{D.Initrd{w(1109393408), w(1110441984)}}, 1n, None{}}

# Nodes in the whole tree.
def count(c: D.DtbCfg) -> U32:
  U32.from_nat(F.Fdt.size([D.Dtb.tree(c)]))

def names(ns: +List<F.Node>) -> String:
  match ns:
    case Nil{}:
      ""
    case Con{F.Node{n, ps, kids}, rest}:
      n ++ " " ++ names(rest)

def kids(n: F.Node) -> +List<F.Node>:
  match n:
    case F.Node{nm, ps, ks}:
      ks

# Names of the root's children.
def top(c: D.DtbCfg) -> String:
  names(kids(D.Dtb.tree(c)))

def nth(ns: +List<F.Node>, i: Nat) -> F.Node:
  Maybe.default(&2, F.Node, List.head(&2, F.Node, List.drop(&2, F.Node, ns, i)), F.Node{"none", [], []})

# Names of the children of the root's child i.
def under(c: D.DtbCfg, i: Nat) -> String:
  names(kids(nth(kids(D.Dtb.tree(c)), i)))

def pnames(ps: +List<F.Prop>) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{F.Prop{n, v}, rest}:
      n ++ " " ++ pnames(rest)

# Property names of /chosen.
def props(n: F.Node) -> +List<F.Prop>:
  match n:
    case F.Node{nm, ps, ks}:
      ps

def chosen(c: D.DtbCfg) -> String:
  pnames(props(nth(kids(D.Dtb.tree(c)), 0n)))

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("unit zero", D.Dtb.unit(w(0)), "0")
    T.eq_str("unit uart", D.Dtb.unit(w(150994944)), "9000000")
    T.eq_str("unit ram", D.Dtb.unit(w(1073741824)), "40000000")
    T.eq_str("unit high word", D.Dtb.unit(U.U64{1, 255}), "1000000ff")
    T.eq_str("unit lowercase", D.Dtb.unit(w(171)), "ab")
    T.eq_u32("nodes 1 cpu 0 slots", count(cfg(1n, 0n)), 11)
    T.eq_u32("nodes 2 cpus 2 slots", count(cfg(2n, 2n)), 14)
    T.eq_u32("nodes 0 cpus 0 slots", count(cfg(0n, 0n)), 10)
    T.eq_u32("nodes 3 cpus 5 slots", count(cfg(3n, 5n)), 18)
    T.eq_u32("nodes 8 cpus 32 slots", count(cfg(8n, 32n)), 50)
    T.eq_str("top order", top(cfg(1n, 3n)), "chosen memory@40000000 cpus psci timer intc@8000000 apb-pclk pl011@9000000 pl031@9010000 virtio_mmio@a000000 virtio_mmio@a000200 virtio_mmio@a000400 ")
    T.eq_str("cpu order", under(cfg(12n, 0n), 2n), "cpu@0 cpu@1 cpu@2 cpu@3 cpu@4 cpu@5 cpu@6 cpu@7 cpu@8 cpu@9 cpu@a cpu@b ")
    T.eq_str("no cpus", under(cfg(0n, 0n), 2n), "")
    T.eq_str("last virtio slot", names(List.drop(&2, F.Node, kids(D.Dtb.tree(cfg(1n, 32n))), 40n)), "virtio_mmio@a003e00 ")
    T.eq_str("chosen with initrd", chosen(with_initrd()), "bootargs stdout-path linux,initrd-start linux,initrd-end ")
    T.eq_str("chosen without initrd", chosen(cfg(1n, 0n)), "bootargs stdout-path ")
