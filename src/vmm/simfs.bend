import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ./abi.bend as V

# A pure in-memory filesystem: the stand-in for a host shared directory in
# tests (src/vmm/sim.bend answers VmFs with it). It holds files, directories
# and symlinks, each a node named by its full path relative to the share root
# ("" is the root), with an inode number, st_mode and its bytes (a file's
# contents, a symlink's target; empty for a directory). Nodes keep creation
# order, so a directory lists in a stable order. Errors are macOS errnos, as
# the real host answers them. Symlinks are never followed, and times are 0.

type Node is Data:
  Node{path: String, ino: U32, mode: U32, data: +List<U32>}

# next is the inode the next new node gets.
type SimFs is Data:
  SimFs{next: U32, nodes: +List<Node>}

# st_mode type bits (decimal): S_IFMT 0o170000, S_IFDIR 0o040000,
# S_IFREG 0o100000, S_IFLNK 0o120000.
def SimFs.s_ifmt() -> U32:
  61440

def SimFs.s_ifdir() -> U32:
  16384

def SimFs.s_ifreg() -> U32:
  32768

def SimFs.s_iflnk() -> U32:
  40960

# macOS errnos.
def SimFs.eperm() -> U32:
  1

def SimFs.enoent() -> U32:
  2

def SimFs.ebusy() -> U32:
  16

def SimFs.eexist() -> U32:
  17

def SimFs.enotdir() -> U32:
  20

def SimFs.eisdir() -> U32:
  21

def SimFs.einval() -> U32:
  22

def SimFs.eloop() -> U32:
  62

def SimFs.enotempty() -> U32:
  66

# An empty share: the root directory (inode 2, mode 0o40755).
def SimFs.new() -> SimFs:
  SimFs{3, [Node{"", 2, 16877, []}]}

def Node.path(n: Node) -> String:
  match n:
    case Node{p, i, m, d}:
      p

# 0 directory, 1 regular file (or anything else), 2 symlink.
def SimFs.kind_of(+mode: U32) -> Nat:
  +t = (mode .&. SimFs.s_ifmt() : U32)
  Bool.pick(Nat, U32.is_eq(t, SimFs.s_ifdir()), 0n, Bool.pick(Nat, U32.is_eq(t, SimFs.s_iflnk()), 2n, 1n))

def Node.kind(n: Node) -> Nat:
  match n:
    case Node{p, i, m, d}:
      SimFs.kind_of(m)

def SimFs.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case b <> t:
      SCon{Char.from_u32(b), SimFs.chars(t)}

# Drops a reversed path's last name and the '/' before it.
def SimFs.drop_name(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, +t}:
      Bool.pick(String, U32.is_eq(Char.to_u32(c), 47), t, SimFs.drop_name(t))

# The directory holding path ("" for a name at the root).
def SimFs.parent(p: String) -> String:
  String.reverse(SimFs.drop_name(String.reverse(p)))

# A reversed path's last name.
def SimFs.take_name(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, +t}:
      Bool.pick(String, U32.is_eq(Char.to_u32(c), 47), SNil{}, SCon{c, SimFs.take_name(t)})

# The last name of a path.
def SimFs.name(p: String) -> String:
  String.reverse(SimFs.take_name(String.reverse(p)))

# The rest of s after prefix, if s starts with it.
def SimFs.strip(prefix: String, s: String) -> Maybe<&2, String>:
  match prefix s:
    case SNil{} s:
      Some{s}
    case SCon{c, pt} SNil{}:
      None{}
    case SCon{c, pt} SCon{d, st}:
      Bool.pick(Maybe<&2, String>, Char.is_eq(c, d), SimFs.strip(pt, st), None{})

# Whether path lies strictly inside directory dir.
def SimFs.is_some(m: Maybe<&2, String>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{r}:
      True{}

def SimFs.is_under(+dir: String, path: String) -> Bool:
  SimFs.is_some(SimFs.strip(dir ++ "/", path))

def SimFs.find(nodes: +List<Node>, +path: String) -> Maybe<&2, Node>:
  match nodes:
    case Nil{}:
      None{}
    case +n <> +t:
      Bool.pick(Maybe<&2, Node>, String.eq(Node.path(n), path), Some{n}, SimFs.find(t, path))

# Whether node n sits directly in directory dir.
def Node.in_dir(n: Node, +dir: String) -> Bool:
  match n:
    case Node{+p, i, m, d}:
      Bool.not(String.is_empty(p)) && String.eq(SimFs.parent(p), dir)

# The nodes directly in directory dir, in creation order.
def SimFs.children(nodes: +List<Node>, +dir: String) -> +List<Node>:
  match nodes:
    case Nil{}:
      []
    case +n <> +t:
      Bool.pick(+List<Node>, Node.in_dir(n, dir), n <> SimFs.children(t, dir), SimFs.children(t, dir))

def SimFs.without(nodes: +List<Node>, +path: String) -> +List<Node>:
  match nodes:
    case Nil{}:
      []
    case +n <> +t:
      Bool.pick(+List<Node>, String.eq(Node.path(n), path), SimFs.without(t, path), n <> SimFs.without(t, path))

# Replaces the node at new's path with new.
def SimFs.replace(nodes: +List<Node>, +new: Node) -> +List<Node>:
  match nodes:
    case Nil{}:
      []
    case +n <> +t:
      Bool.pick(+List<Node>, String.eq(Node.path(n), Node.path(new)), new <> t, n <> SimFs.replace(t, new))

# The errno for a node that must be of kind want (0 dir, 1 file, 2 symlink),
# 0 when it is.
def SimFs.need.kind(want: Nat, k: Nat) -> U32:
  match want k:
    case 0n 0n:
      0
    case 0n k:
      SimFs.enotdir()
    case 1n 0n:
      SimFs.eisdir()
    case 1n 2n:
      SimFs.eloop()
    case 1n k:
      0
    case want 2n:
      0
    case want k:
      SimFs.einval()

def SimFs.need(m: Maybe<&2, Node>, want: Nat) -> U32:
  match m:
    case None{}:
      SimFs.enoent()
    case Some{n}:
      SimFs.need.kind(want, Node.kind(n))

# The first nonzero errno of two.
def SimFs.first(+a: U32, b: U32) -> U32:
  Bool.pick(U32, U32.is_zero(a), b, a)

def SimFs.exists(m: Maybe<&2, Node>) -> U32:
  match m:
    case None{}:
      0
    case Some{n}:
      SimFs.eexist()

def SimFs.attr(n: Node) -> V.FsAttr:
  match n:
    case Node{p, ino, +mode, +data}:
      +size = U32.from_nat(List.length(&2, U32, data))
      nlink = Bool.pick(U32, Nat.is_eq(SimFs.kind_of(mode), 0n), 2, 1)
      blocks = U32.div((size + 511 : U32), 512)
      +z = U.U64.zero()
      V.FsAttr{mode, 0, 0, nlink, U.U64{0, size}, U.U64{0, ino}, U.U64{0, blocks}, z, z, z}

def SimFs.entry(n: Node) -> V.FsEntry:
  match n:
    case Node{p, ino, +mode, d}:
      kind = Bool.pick(U32, Nat.is_eq(SimFs.kind_of(mode), 0n), 4, Bool.pick(U32, Nat.is_eq(SimFs.kind_of(mode), 2n), 10, 8))
      V.FsEntry{SimFs.name(p), U.U64{0, ino}, kind}

def SimFs.entries(ns: +List<Node>) -> +List<V.FsEntry>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      SimFs.entry(n) <> SimFs.entries(t)

def SimFs.ret(fs: SimFs, r: V.FsResult) -> SimFs & V.FsResult:
  (fs, r)

def SimFs.err(fs: SimFs, e: U32) -> SimFs & V.FsResult:
  (fs, V.FsErr{e})

# Answers ok when errno e is 0, else e (on the unchanged fs).
def SimFs.guard(fs: SimFs, +e: U32, ok: SimFs & V.FsResult) -> SimFs & V.FsResult:
  Bool.pick(SimFs & V.FsResult, U32.is_zero(e), ok, SimFs.err(fs, e))

# A node's bytes (empty when absent).
def SimFs.data(m: Maybe<&2, Node>) -> +List<U32>:
  match m:
    case None{}:
      []
    case Some{Node{p, i, m2, d}}:
      d

def SimFs.mode(m: Maybe<&2, Node>) -> U32:
  match m:
    case None{}:
      0
    case Some{Node{p, i, m2, d}}:
      m2

def SimFs.ino(m: Maybe<&2, Node>) -> U32:
  match m:
    case None{}:
      0
    case Some{Node{p, i, m2, d}}:
      i

# Nat of a 64-bit offset; None past 4 GiB.
def SimFs.off(o: U.U64) -> Maybe<&2, Nat>:
  match o:
    case U.U64{h, l}:
      Bool.pick(Maybe<&2, Nat>, U32.is_zero(h), Some{U32.to_nat(l)}, None{})

def SimFs.stat.of(fs: SimFs, m: Maybe<&2, Node>) -> SimFs & V.FsResult:
  match m:
    case None{}:
      SimFs.err(fs, SimFs.enoent())
    case Some{n}:
      SimFs.ret(fs, V.FsGotAttr{SimFs.attr(n)})

def SimFs.stat(fs: SimFs, path: String) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      SimFs.stat.of(SimFs{nx, ns}, SimFs.find(ns, path))

def SimFs.list(fs: SimFs, +path: String, from: U32, max: U32) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +e = SimFs.need(SimFs.find(ns, path), 0n)
      +es = List.take(&2, Node, List.drop(&2, Node, SimFs.children(ns, path), U32.to_nat(from)), U32.to_nat(max))
      SimFs.guard(SimFs{nx, ns}, e, (SimFs{nx, ns}, V.FsEntries{SimFs.entries(es)}))

def SimFs.read.at(+data: +List<U32>, off: Maybe<&2, Nat>, len: U32) -> +List<U32>:
  match off:
    case None{}:
      []
    case Some{o}:
      B.Bytes.slice(data, o, U32.to_nat(len))

def SimFs.read(fs: SimFs, +path: String, offset: U.U64, len: U32) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +m = SimFs.find(ns, path)
      bs = SimFs.read.at(SimFs.data(m), SimFs.off(offset), len)
      SimFs.guard(SimFs{nx, ns}, SimFs.need(m, 1n), (SimFs{nx, ns}, V.FsBytes{bs}))

# data with bytes written at o, zero-filling any gap.
def SimFs.splice(+data: +List<U32>, +o: Nat, +bytes: +List<U32>) -> +List<U32>:
  +gap = Nat.sub(o, List.length(&2, U32, data))
  head = List.append(&2, U32, List.take(&2, U32, data, o), B.Bytes.zeros(gap))
  tail = List.drop(&2, U32, data, Nat.add(o, List.length(&2, U32, bytes)))
  List.append(&2, U32, head, List.append(&2, U32, bytes, tail))

def SimFs.write.at(off: Maybe<&2, Nat>, fs: SimFs, +path: String, +m: Maybe<&2, Node>, +bytes: +List<U32>) -> SimFs & V.FsResult:
  match off:
    case None{}:
      SimFs.err(fs, SimFs.einval())
    case Some{+o}:
      match fs:
        case SimFs{+nx, +ns}:
          +new = {Node{path, SimFs.ino(m), SimFs.mode(m), SimFs.splice(SimFs.data(m), o, bytes)} : Node}
          +n = U32.from_nat(List.length(&2, U32, bytes))
          SimFs.guard(SimFs{nx, ns}, SimFs.need(m, 1n), (SimFs{nx, SimFs.replace(ns, new)}, V.FsCount{n}))

def SimFs.write(fs: SimFs, +path: String, offset: U.U64, bytes: +List<U32>) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      SimFs.write.at(SimFs.off(offset), SimFs{nx, ns}, path, SimFs.find(ns, path), bytes)

# Adds a node of the given full mode at path: its parent must be a directory
# and the path must be free.
def SimFs.add(fs: SimFs, +path: String, mode: U32, data: +List<U32>) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +e = SimFs.first(SimFs.need(SimFs.find(ns, SimFs.parent(path)), 0n), SimFs.exists(SimFs.find(ns, path)))
      +new = {Node{path, nx, mode, data} : Node}
      SimFs.guard(SimFs{nx, ns}, e, (SimFs{(nx + 1 : U32), List.append(&2, Node, ns, [new])}, V.FsOk{}))

def SimFs.perm(mode: U32) -> U32:
  (mode .&. 4095 : U32)

def SimFs.remove.check(dir: Bool, m: Maybe<&2, Node>, +ns: +List<Node>, +path: String) -> U32:
  match dir:
    case True{}:
      +e = SimFs.need(m, 0n)
      SimFs.first(e, Bool.pick(U32, List.is_empty(&2, Node, SimFs.children(ns, path)), 0, SimFs.enotempty()))
    case False{}:
      match m:
        case None{}:
          SimFs.enoent()
        case Some{n}:
          Bool.pick(U32, Nat.is_eq(Node.kind(n), 0n), SimFs.eperm(), 0)

def SimFs.remove(fs: SimFs, +path: String, dir: Bool) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +e = SimFs.first(Bool.pick(U32, String.is_empty(path), SimFs.ebusy(), 0), SimFs.remove.check(dir, SimFs.find(ns, path), ns, path))
      SimFs.guard(SimFs{nx, ns}, e, (SimFs{nx, SimFs.without(ns, path)}, V.FsOk{}))

# A path renamed: from itself, or anything under it, moves to `to`.
def SimFs.moved.under(+to: String, path: String, r: Maybe<&2, String>) -> String:
  match r:
    case None{}:
      path
    case Some{rest}:
      to ++ "/" ++ rest

def SimFs.moved(+from: String, +to: String, +path: String) -> String:
  Bool.pick(String, String.eq(path, from), to, SimFs.moved.under(to, path, SimFs.strip(from ++ "/", path)))

def SimFs.move_all(nodes: +List<Node>, +from: String, +to: String) -> +List<Node>:
  match nodes:
    case Nil{}:
      []
    case Node{+p, i, m, d} <> t:
      Node{SimFs.moved(from, to, p), i, m, d} <> SimFs.move_all(t, from, to)

# The errno for replacing dst (if any) by a node of kind src.
def SimFs.rename.dst(+ns: +List<Node>, +src: Nat, d: Maybe<&2, Node>) -> U32:
  match d:
    case None{}:
      0
    case Some{+n}:
      +dk = Node.kind(n)
      +both = Nat.is_eq(src, 0n) && Nat.is_eq(dk, 0n)
      Bool.pick(U32, Nat.is_eq(src, 0n) && Bool.not(Nat.is_eq(dk, 0n)), SimFs.enotdir(),
        Bool.pick(U32, Bool.not(Nat.is_eq(src, 0n)) && Nat.is_eq(dk, 0n), SimFs.eisdir(),
          Bool.pick(U32, both && Bool.not(List.is_empty(&2, Node, SimFs.children(ns, Node.path(n)))), SimFs.enotempty(), 0)))

def SimFs.rename.src(m: Maybe<&2, Node>) -> Nat:
  match m:
    case None{}:
      1n
    case Some{n}:
      Node.kind(n)

def SimFs.rename(fs: SimFs, +from: String, +to: String) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +sm = SimFs.find(ns, from)
      +e0 = Bool.pick(U32, String.is_empty(from) || String.is_empty(to), SimFs.ebusy(), 0)
      +e1 = SimFs.need(sm, 1n)
      +e1 = Bool.pick(U32, U32.is_eq(e1, SimFs.enoent()), e1, 0)
      +e2 = SimFs.need(SimFs.find(ns, SimFs.parent(to)), 0n)
      +e3 = Bool.pick(U32, SimFs.is_under(from, to), SimFs.einval(), 0)
      +same = String.eq(from, to)
      +e4 = Bool.pick(U32, same, 0, SimFs.rename.dst(ns, SimFs.rename.src(sm), SimFs.find(ns, to)))
      +e = SimFs.first(e0, SimFs.first(e1, SimFs.first(e2, SimFs.first(e3, e4))))
      +moved = SimFs.move_all(SimFs.without(ns, to), from, to)
      SimFs.guard(SimFs{nx, ns}, e, (SimFs{nx, Bool.pick(+List<Node>, same, ns, moved)}, V.FsOk{}))

def SimFs.truncate.at(size: Maybe<&2, Nat>, fs: SimFs, +path: String, +m: Maybe<&2, Node>) -> SimFs & V.FsResult:
  match size:
    case None{}:
      SimFs.err(fs, SimFs.einval())
    case Some{+n}:
      match fs:
        case SimFs{+nx, +ns}:
          +data = List.take(&2, U32, List.append(&2, U32, SimFs.data(m), B.Bytes.zeros(n)), n)
          SimFs.guard(SimFs{nx, ns}, SimFs.need(m, 1n), (SimFs{nx, SimFs.replace(ns, Node{path, SimFs.ino(m), SimFs.mode(m), data})}, V.FsOk{}))

def SimFs.truncate(fs: SimFs, +path: String, size: U.U64) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      SimFs.truncate.at(SimFs.off(size), SimFs{nx, ns}, path, SimFs.find(ns, path))

def SimFs.chmod(fs: SimFs, +path: String, mode: U32) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +m = SimFs.find(ns, path)
      +e = Bool.pick(U32, U32.is_eq(SimFs.need(m, 2n), SimFs.enoent()), SimFs.enoent(), 0)
      new_mode = ((SimFs.mode(m) .&. SimFs.s_ifmt() : U32) .|. SimFs.perm(mode) : U32)
      SimFs.guard(SimFs{nx, ns}, e, (SimFs{nx, SimFs.replace(ns, Node{path, SimFs.ino(m), new_mode, SimFs.data(m)})}, V.FsOk{}))

def SimFs.readlink(fs: SimFs, path: String) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      +m = SimFs.find(ns, path)
      SimFs.guard(SimFs{nx, ns}, SimFs.need(m, 2n), (SimFs{nx, ns}, V.FsLink{SimFs.chars(SimFs.data(m))}))

# statfs: 4096-byte blocks, 1024 of them with 1000 free; 1024 inodes.
def SimFs.statfs(fs: SimFs) -> SimFs & V.FsResult:
  match fs:
    case SimFs{+nx, +ns}:
      used = U32.from_nat(List.length(&2, Node, ns))
      SimFs.ret(SimFs{nx, ns}, V.FsStatfsOk{4096, U.U64{0, 1024}, U.U64{0, 1000}, U.U64{0, 1000}, U.U64{0, 1024}, U.U64{0, (1024 - used : U32)}})

# Applies one filesystem operation: the new filesystem and the answer.
def SimFs.apply(fs: SimFs, op: V.FsOp) -> SimFs & V.FsResult:
  match op:
    case V.FsStat{p}:
      SimFs.stat(fs, p)
    case V.FsList{p, from, max}:
      SimFs.list(fs, p, from, max)
    case V.FsRead{p, off, len}:
      SimFs.read(fs, p, off, len)
    case V.FsWrite{p, off, bs}:
      SimFs.write(fs, p, off, bs)
    case V.FsCreate{p, mode}:
      SimFs.add(fs, p, (SimFs.s_ifreg() .|. SimFs.perm(mode) : U32), [])
    case V.FsMkdir{p, mode}:
      SimFs.add(fs, p, (SimFs.s_ifdir() .|. SimFs.perm(mode) : U32), [])
    case V.FsRemove{p, dir}:
      SimFs.remove(fs, p, dir)
    case V.FsRename{from, to}:
      SimFs.rename(fs, from, to)
    case V.FsTruncate{p, size}:
      SimFs.truncate(fs, p, size)
    case V.FsChmod{p, mode}:
      SimFs.chmod(fs, p, mode)
    case V.FsSymlink{p, target}:
      SimFs.add(fs, p, 41471, B.Bytes.of_string(target))
    case V.FsReadlink{p}:
      SimFs.readlink(fs, p)
    case V.FsStatfs{}:
      SimFs.statfs(fs)
    # Guest memory is the simulator's (Sim.fs_apply turns these into
    # FsRead and FsWrite); here they are not supported: ENOSYS.
    case V.FsReadRam{p, off, iovs}:
      SimFs.ret(fs, V.FsErr{78})
    case V.FsWriteRam{p, off, iovs}:
      SimFs.ret(fs, V.FsErr{78})

def SimFs.fst(r: SimFs & V.FsResult) -> SimFs:
  match r:
    case (f, x):
      f

# Test setup: a file with the given contents (mode 0o644), ignoring errors.
def SimFs.with_file(fs: SimFs, +path: String, data: +List<U32>) -> SimFs:
  SimFs.fst(SimFs.add(fs, path, 33188, data))

# Test setup: a directory (mode 0o755), ignoring errors.
def SimFs.with_dir(fs: SimFs, +path: String) -> SimFs:
  SimFs.fst(SimFs.add(fs, path, 16877, []))

# Test setup: a symlink to target, ignoring errors.
def SimFs.with_link(fs: SimFs, +path: String, target: String) -> SimFs:
  SimFs.fst(SimFs.add(fs, path, 41471, B.Bytes.of_string(target)))

# The bytes of the node at path (empty when absent).
def SimFs.contents(fs: SimFs, +path: String) -> +List<U32>:
  match fs:
    case SimFs{nx, ns}:
      SimFs.data(SimFs.find(ns, path))

# Whether a node exists at path.
def SimFs.has(fs: SimFs, +path: String) -> Bool:
  match fs:
    case SimFs{nx, ns}:
      Bool.not(U32.is_eq(SimFs.need(SimFs.find(ns, path), 1n), SimFs.enoent()))
