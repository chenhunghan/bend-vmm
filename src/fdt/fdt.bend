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

def Fdt.cells(vs: +List<U32>) -> +List<U32>:
  match vs:
    case Nil{}:
      []
    case Con{v, rest}:
      List.append(&2, U32, B.Bytes.be32(v), Fdt.cells(rest))

# A list of 32-bit cells.
def Prop.cells(name: String, vs: +List<U32>) -> Prop:
  Prop{name, Fdt.cells(vs)}

def Prop.str(name: String, s: String) -> Prop:
  Prop{name, B.Bytes.of_cstring(s)}

def Fdt.cstrings(ss: +List<String>) -> +List<U32>:
  match ss:
    case Nil{}:
      []
    case Con{s, rest}:
      List.append(&2, U32, B.Bytes.of_cstring(s), Fdt.cstrings(rest))

# A string list: each string NUL-terminated, concatenated.
def Prop.strs(name: String, ss: +List<String>) -> Prop:
  Prop{name, Fdt.cstrings(ss)}

def Fdt.prop_names(ps: +List<Prop>) -> +List<String>:
  match ps:
    case Nil{}:
      []
    case Con{Prop{n, v}, rest}:
      n <> Fdt.prop_names(rest)

# Every property name of a forest, depth first (a node's props, then its
# children, then its siblings), duplicates kept.
def Fdt.names(ns: +List<Node>) -> +List<String>:
  match ns:
    case Nil{}:
      []
    case Con{Node{n, ps, kids}, rest}:
      List.append(&2, String, Fdt.prop_names(ps), List.append(&2, String, Fdt.names(kids), Fdt.names(rest)))

def Fdt.has(ss: +List<String>, +s: String) -> Bool:
  match ss:
    case Nil{}:
      False{}
    case Con{h, rest}:
      String.eq(h, s) || Fdt.has(rest, s)

def Fdt.dedup.add(seen: Bool, n: String, acc: +List<String>) -> +List<String>:
  match seen:
    case True{}:
      acc
    case False{}:
      List.append(&2, String, acc, [n])

# Each name once, at its first appearance (acc holds the names kept so far).
def Fdt.dedup(ss: +List<String>, +acc: +List<String>) -> +List<String>:
  match ss:
    case Nil{}:
      acc
    case Con{+n, rest}:
      Fdt.dedup(rest, Fdt.dedup.add(Fdt.has(acc, n), n, acc))

# The names of the strings block, in order.
def Fdt.table(root: Node) -> +List<String>:
  Fdt.dedup(Fdt.names([root]), [])

# The strings block for a tree: each distinct property name once, NUL-terminated,
# in depth-first order of first appearance.
def Fdt.strings(root: Node) -> +List<U32>:
  Fdt.cstrings(Fdt.table(root))

def Fdt.word(x: U32) -> +List<U32>:
  B.Bytes.be32(x)

def Fdt.len(bs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

def Fdt.offset.fin(hit: Bool, here: U32, later: U32) -> U32:
  match hit:
    case True{}:
      0
    case False{}:
      (here + later : U32)

# The offset of name s in the strings block of table ss.
def Fdt.offset(ss: +List<String>, +s: String) -> U32:
  match ss:
    case Nil{}:
      0
    case Con{+h, rest}:
      Fdt.offset.fin(String.eq(h, s), (U32.from_nat(String.length(h)) + 1 : U32), Fdt.offset(rest, s))

# FDT_PROP: token, value length, name offset, value padded to 4.
def Fdt.prop(+tab: +List<String>, p: Prop) -> +List<U32>:
  match p:
    case Prop{n, +v}:
      +head = List.append(&2, U32, Fdt.word(3), List.append(&2, U32, Fdt.word(Fdt.len(v)), Fdt.word(Fdt.offset(tab, n))))
      List.append(&2, U32, head, B.Bytes.pad(2n, v))

def Fdt.props(+tab: +List<String>, ps: +List<Prop>) -> +List<U32>:
  match ps:
    case Nil{}:
      []
    case Con{p, rest}:
      List.append(&2, U32, Fdt.prop(tab, p), Fdt.props(tab, rest))

# Nodes in a forest.
def Fdt.size(ns: +List<Node>) -> Nat:
  match ns:
    case Nil{}:
      0n
    case Con{Node{n, ps, kids}, rest}:
      1n+Nat.add(Fdt.size(kids), Fdt.size(rest))

# The structure block of a forest. A single node is FDT_BEGIN_NODE, its name
# padded to 4, its props, its children, FDT_END_NODE. Two or more siblings
# split in halves that serialize in parallel: name offsets come from the
# finished strings table, so no half depends on the other. Each call spends one
# unit of fuel; 2 * Fdt.size(ns) always suffices (a forest of k nodes needs at
# most 2k - 1).
def Fdt.ser(fuel: Nat, +tab: +List<String>, ns: +List<Node>) -> +List<U32>:
  match fuel:
    case 0n:
      []
    case 1n+p:
      match ns:
        case Nil{}:
          []
        case Con{Node{n, ps, kids}, Nil{}}:
          +p = p
          +begin = List.append(&2, U32, Fdt.word(1), B.Bytes.pad(2n, B.Bytes.of_cstring(n)))
          +body = List.append(&2, U32, Fdt.props(tab, ps), Fdt.ser(p, tab, kids))
          List.append(&2, U32, begin, List.append(&2, U32, body, Fdt.word(2)))
        case Con{a, Con{b, rest}}:
          +p = p
          +all = {a <> b <> rest : +List<Node>}
          +half = Nat.div(List.length(&2, Node, all), 2n)
          l r = Fdt.ser(p, tab, List.take(&2, Node, all, half)) Fdt.ser(p, tab, List.drop(&2, Node, all, half))
          List.append(&2, U32, l, r)

def Fdt.header(+total: U32, +off_strings: U32, cpu: U32, size_strings: U32, size_struct: U32) -> +List<U32>:
  # magic 0xd00dfeed, off_dt_struct 56, off_mem_rsvmap 40, version 17, last_comp 16
  Fdt.cells([3490578157, total, 56, off_strings, 40, 17, 16, cpu, size_strings, size_struct])

# The complete DTB blob.
def Fdt.build(root: Node, boot_cpuid: U32) -> +List<U32>:
  +root = root
  +tab = Fdt.table(root)
  st strs = Fdt.ser(Nat.mul(2n, Fdt.size([root])), tab, [root]) Fdt.cstrings(tab)
  +st = List.append(&2, U32, st, Fdt.word(9))
  +strs = strs
  +off_strings = (56 + Fdt.len(st) : U32)
  +header = Fdt.header((off_strings + Fdt.len(strs) : U32), off_strings, boot_cpuid, Fdt.len(strs), Fdt.len(st))
  List.append(&2, U32, header, List.append(&2, U32, B.Bytes.zeros(16n), List.append(&2, U32, st, strs)))
