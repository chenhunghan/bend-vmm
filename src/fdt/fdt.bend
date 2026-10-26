import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# Flattened Devicetree (DTB) serialization, Devicetree Specification v0.4
# chapter 5. Blob layout: a 40-byte header, an empty memory reservation map
# (16 zero bytes), the structure block, then the strings block.
# Header fields, all big-endian U32: magic 0xd00dfeed (3490578157), totalsize,
# off_dt_struct, off_dt_strings, off_mem_rsvmap, version 17, last_comp_version
# 16, boot_cpuid_phys, size_dt_strings, size_dt_struct.
# Structure tokens: FDT_BEGIN_NODE 1 (name, NUL, pad to 4), FDT_END_NODE 2,
# FDT_PROP 3 (len, nameoff, value, pad to 4), FDT_END 9.
# Property names are stored once each in the strings block, in order of first
# appearance in a depth-first walk, each NUL-terminated.

type Prop is Data:
  Prop{name: String, value: +List<U32>}

type Node is Data:
  Node{name: String, props: +List<Prop>, children: +List<Node>}

def Prop.empty(name: String) -> Prop:
  Prop{name, []}

def Prop.u32(name: String, v: U32) -> Prop:
  Prop{name, B.Bytes.be32(v)}

def Prop.u64(name: String, v: U.U64) -> Prop:
  Prop{name, B.Bytes.be64(v)}

# A list of 32-bit cells.
def Prop.cells(name: String, vs: +List<U32>) -> Prop:
  ?TODO

def Prop.str(name: String, s: String) -> Prop:
  Prop{name, B.Bytes.of_cstring(s)}

# A string list: each string NUL-terminated, concatenated.
def Prop.strs(name: String, ss: +List<String>) -> Prop:
  ?TODO

# The strings block for a tree: each distinct property name once, NUL-terminated,
# in depth-first order of first appearance.
def Fdt.strings(root: Node) -> +List<U32>:
  ?TODO

# The complete DTB blob.
def Fdt.build(root: Node, boot_cpuid: U32) -> +List<U32>:
  ?TODO
