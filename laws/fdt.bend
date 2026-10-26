import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/fdt/fdt.bend as F

# Frozen spec for src/fdt/fdt.bend. The expected blobs were produced by an
# independent encoder and accepted by `dtc -I dtb -O dts`:
#   / { #address-cells = <2>; model = "bend";
#       chosen { bootargs = "x"; model = "y"; }; };

def sample() -> F.Node:
  F.Node{"", [F.Prop.u32("#address-cells", 2), F.Prop.str("model", "bend")], [F.Node{"chosen", [F.Prop.str("bootargs", "x"), F.Prop.str("model", "y")], []}]}

law fdt.cells:
  {F.Prop.cells("reg", [1, 256]) == F.Prop{"reg", [0, 0, 0, 1, 0, 0, 1, 0]} : F.Prop}

law fdt.cells_empty:
  {F.Prop.cells("reg", []) == F.Prop{"reg", []} : F.Prop}

law fdt.strs:
  {F.Prop.strs("compatible", ["a", "bc"]) == F.Prop{"compatible", [97, 0, 98, 99, 0]} : F.Prop}

law fdt.strings_dedup:
  # "#address-cells\0model\0bootargs\0": model appears once.
  {F.Fdt.strings(sample()) == [35, 97, 100, 100, 114, 101, 115, 115, 45, 99, 101, 108, 108, 115, 0, 109, 111, 100, 101, 108, 0, 98, 111, 111, 116, 97, 114, 103, 115, 0] : +List<U32>}

law fdt.empty_root:
  {F.Fdt.build(F.Node{"", [], []}, 0) == [208, 13, 254, 237, 0, 0, 0, 72, 0, 0, 0, 56, 0, 0, 0, 72, 0, 0, 0, 40, 0, 0, 0, 17, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 9] : +List<U32>}

law fdt.sample:
  {F.Fdt.build(sample(), 0) == [208, 13, 254, 237, 0, 0, 0, 186, 0, 0, 0, 56, 0, 0, 0, 156, 0, 0, 0, 40, 0, 0, 0, 17, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 5, 0, 0, 0, 15, 98, 101, 110, 100, 0, 0, 0, 0, 0, 0, 0, 1, 99, 104, 111, 115, 101, 110, 0, 0, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 21, 120, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 15, 121, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 9, 35, 97, 100, 100, 114, 101, 115, 115, 45, 99, 101, 108, 108, 115, 0, 109, 111, 100, 101, 108, 0, 98, 111, 111, 116, 97, 114, 103, 115, 0] : +List<U32>}

law fdt.boot_cpuid:
  # boot_cpuid_phys is header word 7 (bytes 28..31).
  {B.Bytes.slice(F.Fdt.build(F.Node{"", [], []}, 3), 28n, 4n) == [0, 0, 0, 3] : +List<U32>}

# General: every blob starts with the DTB magic 0xd00dfeed. (An earlier
# law claimed every blob is word-aligned; it was false: the strings block is
# not padded, as fdt.sample's 186-byte blob shows.)
law fdt.magic:
  for root: F.Node
  for cpu: U32
  {B.Bytes.slice(F.Fdt.build(root, cpu), 0n, 4n) == [208, 13, 254, 237] : +List<U32>}

# Proposed: the frozen fdt.sample blob is 186 bytes long, so a blob need not be
# a whole number of 4-byte words (dtc does not pad the strings block).
law fdt.sample_not_word_aligned:
  {Nat.mod(List.length(&2, U32, F.Fdt.build(sample(), 0)), 4n) == 2n : Nat}
