import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/fdt/fdt.bend as F
import ./t.bend as T

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def leaf(name: String) -> F.Node:
  F.Node{name, [], []}

def blob_len(bs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

# Header word i (big-endian) of a blob.
def word(i: Nat, bs: +List<U32>) -> U32:
  B.Bytes.read_be32(B.Bytes.slice(bs, Nat.mul(i, 4n), 4n))

def prop_value(p: F.Prop) -> +List<U32>:
  match p:
    case F.Prop{n, v}:
      v

# Four sibling leaves, so the halving split runs more than once.
def wide() -> F.Node:
  F.Node{"", [F.Prop.empty("ranges")], [leaf("a"), leaf("b"), leaf("c"), leaf("d")]}

# A deep chain: a { b { c { d {} } } }, each with a prop "p".
def deep() -> F.Node:
  F.Node{"", [], [F.Node{"a", [F.Prop.empty("p")], [F.Node{"b", [F.Prop.empty("p")], [F.Node{"c", [F.Prop.empty("p")], [F.Node{"d", [F.Prop.empty("p")], []}]}]}]}]}

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("cells one", show(prop_value(F.Prop.cells("x", [4294967295]))), "[255, 255, 255, 255]")
    T.eq_str("strs empty", show(prop_value(F.Prop.strs("x", []))), "[]")
    T.eq_str("strs empty string", show(prop_value(F.Prop.strs("x", [""]))), "[0]")
    T.eq_str("u64 prop", show(prop_value(F.Prop.u64("x", U.U64{1, 2}))), "[0, 0, 0, 1, 0, 0, 0, 2]")
    T.eq_str("strings none", show(F.Fdt.strings(leaf(""))), "[]")
    T.eq_str("strings children only", show(F.Fdt.strings(F.Node{"", [], [F.Node{"n", [F.Prop.empty("p")], []}]})), "[112, 0]")
    T.eq_str("strings deep dedup", show(F.Fdt.strings(deep())), "[112, 0]")
    T.eq_str("strings order", show(F.Fdt.strings(F.Node{"", [F.Prop.empty("b")], [F.Node{"n", [F.Prop.empty("a"), F.Prop.empty("b")], []}]})), "[98, 0, 97, 0]")
    # Empty prop: FDT_PROP, len 0, nameoff 0, no value bytes.
    T.eq_str("empty prop struct", show(B.Bytes.slice(F.Fdt.build(F.Node{"", [F.Prop.empty("p")], []}, 0), 56n, 24n)), "[0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]")
    # A 4-char name pads to 8 bytes (NUL plus 3 zeros), then FDT_END_NODE.
    T.eq_str("name pad", show(B.Bytes.slice(F.Fdt.build(F.Node{"", [], [leaf("abcd")]}, 0), 64n, 16n)), "[0, 0, 0, 1, 97, 98, 99, 100, 0, 0, 0, 0, 0, 0, 0, 2]")
    # Second distinct name gets nameoff 2 ("a\0b\0").
    T.eq_u32("nameoff second", word(21n, F.Fdt.build(F.Node{"", [F.Prop.empty("a"), F.Prop.empty("b")], []}, 0)), 2)
    T.eq_u32("wide totalsize", word(1n, F.Fdt.build(wide(), 0)), blob_len(F.Fdt.build(wide(), 0)))
    # struct: root begin 8 + prop 12 + 4 leaves of 12 + end 4 + FDT_END 4 = 76
    T.eq_u32("wide size_dt_struct", word(9n, F.Fdt.build(wide(), 0)), 76)
    T.eq_u32("wide off_dt_strings", word(3n, F.Fdt.build(wide(), 0)), 132)
    T.eq_u32("wide size_dt_strings", word(8n, F.Fdt.build(wide(), 0)), 7)
    T.eq_str("wide leaf order", show(B.Bytes.slice(F.Fdt.build(wide(), 0), 76n, 48n)), "[0, 0, 0, 1, 97, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 98, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 99, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 100, 0, 0, 0, 0, 0, 0, 2]")
    # deep: begin 8 + 4 * (begin 8 + prop 12 + end 4) + end 4 + FDT_END 4 = 112
    T.eq_u32("deep size_dt_struct", word(9n, F.Fdt.build(deep(), 0)), 112)
    T.eq_u32("deep totalsize", word(1n, F.Fdt.build(deep(), 0)), 170)
    T.eq_u32("deep ends with FDT_END", word(41n, F.Fdt.build(deep(), 0)), 9)
    T.eq_u32("boot cpuid large", word(7n, F.Fdt.build(leaf(""), 4294967295)), 4294967295)
    T.eq_u32("magic", word(0n, F.Fdt.build(leaf(""), 0)), 3490578157)
