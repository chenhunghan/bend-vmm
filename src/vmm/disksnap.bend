import Base
import ../lib/bytes.bend as B
import ./snapfile.bend as Sf

# Disk snapshots (laws/disksnap.bend): a snapshot also keeps each writable
# disk as it was, so restoring any snapshot puts memory and disks back
# together, as often as wanted and in any order.
#
# Taking snapshot SNAP (the VM paused, its images flushed):
#   1. each writable --disk image i is cloned to SNAP.GEN.disk<i>, through a
#      temporary name (the host clones copy-on-write where the file system
#      can: APFS, btrfs, XFS; else it copies, Dsnap.copy_fallback);
#   2. the snapshot is written to its temporary file, its saved command line
#      tagged --disk-snapshot GEN;
#   3. the copies are renamed into place, then the snapshot over SNAP;
#   4. the copies of the snapshot SNAP held before (its own GEN), if any,
#      are removed.
# A VMM that stops anywhere leaves SNAP whole: the old one with its copies,
# or the new one with its copies (renamed before it).
# Restoring SNAP tagged GEN: each copy is cloned over its disk (a temporary
# name, then renamed), so the copies are never written and SNAP can be
# restored again. A snapshot without the tag (taken before disk snapshots,
# or with no writable disk) leaves the disks as they are.
# A :ro disk needs no copy: the guest cannot change it.

def Dsnap.flag() -> String:
  "--disk-snapshot"

# When the file system cannot clone, the host copies the image.
def Dsnap.copy_fallback() -> Bool:
  True{}

# A writable disk and its place in the --disk list.
type DiskAt is Data:
  DiskAt{i: U32, path: String}

def Dsnap.keep(skip: Bool, d: DiskAt, more: List<DiskAt>) -> List<DiskAt>:
  match skip:
    case True{}:
      more
    case False{}:
      Con{d, more}

def Dsnap.writable.go(specs: List<&2, String>, +i: U32) -> List<DiskAt>:
  match specs:
    case Nil{}:
      []
    case Con{+s, rest}:
      Dsnap.keep(String.ends_with(s, ":ro") || String.is_empty(s), DiskAt{i, s}, Dsnap.writable.go(rest, (i + 1 : U32)))

# The writable disks of a --disk value ("a.img,b.img:ro").
def Dsnap.writable(+spec: String) -> List<DiskAt>:
  Bool.pick(List<DiskAt>, String.is_empty(spec), [], Dsnap.writable.go(String.split(spec, ','), 0))

def Dsnap.copy(+snap: String, +gen: String, +i: U32) -> String:
  snap ++ "." ++ gen ++ ".disk" ++ U32.show(i)

def Dsnap.tmp(+path: String) -> String:
  path ++ ".bend-vmm-tmp"

# The saved command line, tagged with the copies' GEN.
def Dsnap.tagged(args: List<String>, +gen: String) -> List<String>:
  List.append(&1, String, args, [Dsnap.flag(), gen])

# The GEN a saved command line is tagged with ("" when none; the last tag
# wins).
def Dsnap.gen_of.go(args: List<String>, +found: String) -> String:
  match args:
    case Nil{}:
      found
    case Con{+a, rest}:
      match rest:
        case Nil{}:
          found
        case Con{+v, more}:
          Dsnap.gen_of.go(Con{v, more}, Bool.pick(String, String.eq(a, Dsnap.flag()), v, found))

def Dsnap.gen_of(args: List<String>) -> String:
  Dsnap.gen_of.go(args, "")

# What the host does, step by step.
type Step is Data:
  DClone{from: String, to: String}
  DRename{from: String, to: String}
  DRemove{path: String}

def Dsnap.save.go(ds: List<DiskAt>, +snap: String, +gen: String) -> List<Step>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case DiskAt{+i, +p}:
          Con{DClone{p, Dsnap.tmp(Dsnap.copy(snap, gen, i))}, Dsnap.save.go(rest, snap, gen)}

# 1: each writable disk cloned to its copy's temporary name.
def Dsnap.save(+snap: String, +gen: String, ds: List<DiskAt>) -> List<Step>:
  Dsnap.save.go(ds, snap, gen)

def Dsnap.place.go(ds: List<DiskAt>, +snap: String, +gen: String) -> List<Step>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case DiskAt{+i, p}:
          +c = Dsnap.copy(snap, gen, i)
          Con{DRename{Dsnap.tmp(c), c}, Dsnap.place.go(rest, snap, gen)}

# 3: the copies renamed into place (before the snapshot itself).
def Dsnap.place(+snap: String, +gen: String, ds: List<DiskAt>) -> List<Step>:
  Dsnap.place.go(ds, snap, gen)

def Dsnap.drop.go(ds: List<DiskAt>, +snap: String, +old: String) -> List<Step>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case DiskAt{+i, p}:
          Con{DRemove{Dsnap.copy(snap, old, i)}, Dsnap.drop.go(rest, snap, old)}

# 4: the copies of the snapshot SNAP held before (tagged old, with its own
# disks), unless they are this one's.
def Dsnap.drop(+snap: String, +old: String, +gen: String, ds: List<DiskAt>) -> List<Step>:
  Bool.pick(List<Step>, String.is_empty(old) || String.eq(old, gen), [], Dsnap.drop.go(ds, snap, old))

def Dsnap.restore.go(ds: List<DiskAt>, +snap: String, +gen: String) -> List<Step>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case DiskAt{+i, +p}:
          Con{DClone{Dsnap.copy(snap, gen, i), Dsnap.tmp(p)}, Con{DRename{Dsnap.tmp(p), p}, Dsnap.restore.go(rest, snap, gen)}}

# Restoring SNAP tagged gen: each disk set back from its copy (none when
# untagged).
def Dsnap.restore(+snap: String, +gen: String, ds: List<DiskAt>) -> List<Step>:
  Bool.pick(List<Step>, String.is_empty(gen), [], Dsnap.restore.go(ds, snap, gen))

# Reading an existing snapshot's saved command line (to find its GEN): the
# 40-byte header (src/vmm/snapfile.bend) says where it is and how long.
def Dsnap.same(xs: +List<U32>, ys: +List<U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{+x, xr} Con{+y, yr}:
      U32.is_eq(x, y) && Dsnap.same(xr, yr)
    case _ _:
      False{}

def Dsnap.args_len(+head: +List<U32>) -> U32:
  Bool.pick(U32, Dsnap.same(List.take(&2, U32, head, 8n), Sf.Snapf.magic()) && U32.is_eq(B.Bytes.read_le32(List.drop(&2, U32, head, 36n)), 0),
    U32.min(B.Bytes.read_le32(List.drop(&2, U32, head, 32n)), 1048576), 0)

def Dsnap.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, rest}:
      SCon{Char.from_u32(b), Dsnap.chars(rest)}

# NUL-separated arguments: the one being read (reversed) and those done
# (reversed).
type ArgsAt is Data:
  ArgsAt{cur: +List<U32>, done: List<&2, String>}

def Dsnap.args.byte(nul: Bool, +b: U32, +st: ArgsAt) -> ArgsAt:
  match nul st:
    case True{} ArgsAt{+cur, done}:
      ArgsAt{[], Con{Dsnap.chars(List.reverse(&2, U32, cur)), done}}
    case False{} ArgsAt{+cur, done}:
      ArgsAt{Con{b, cur}, done}

def Dsnap.args.go(bs: +List<U32>, +st: ArgsAt) -> ArgsAt:
  match bs:
    case Nil{}:
      st
    case Con{+b, rest}:
      Dsnap.args.go(rest, Dsnap.args.byte(U32.is_eq(b, 0), b, st))

def Dsnap.list1(xs: List<&2, String>, acc: List<String>) -> List<String>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      Dsnap.list1(rest, Con{x, acc})

def Dsnap.args.end(+st: ArgsAt) -> List<String>:
  match st:
    case ArgsAt{+cur, +done}:
      Dsnap.list1(Bool.pick(List<&2, String>, List.is_empty(&2, U32, cur), done, Con{Dsnap.chars(List.reverse(&2, U32, cur)), done}), [])

def Dsnap.args(+bs: +List<U32>) -> List<String>:
  Dsnap.args.end(Dsnap.args.go(bs, ArgsAt{[], []}))

# A snapshot that failed: its copies' temporary files removed.
def Dsnap.unsave.go(ds: List<DiskAt>, +snap: String, +gen: String) -> List<Step>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      match d:
        case DiskAt{+i, p}:
          Con{DRemove{Dsnap.tmp(Dsnap.copy(snap, gen, i))}, Dsnap.unsave.go(rest, snap, gen)}

def Dsnap.unsave(+snap: String, +gen: String, ds: List<DiskAt>) -> List<Step>:
  Dsnap.unsave.go(ds, snap, gen)
