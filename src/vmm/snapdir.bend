import Base

# Snapshots as users see them (laws/snapdir.bend): each one a folder of its
# VM, named, with its own metadata, listed, pruned, and undoable. This
# module is pure: the names, the layout, the metadata's text, the order of a
# listing, which snapshots a prune removes, the undo snapshot a restore
# takes first, and which VM a command means. The host and the library
# (Vmm.*) act on it; the CLI only prints.
#
#   VM/snapshots/NAME/memory    the machine (src/vmm/snapfile.bend's file)
#   VM/snapshots/NAME/disk<i>   each writable disk, cloned (disksnap)
#   VM/snapshots/NAME/info      this module's metadata (Sdir.info.text)
# A snapshot is written into VM/snapshots/.NAME.tmp and renamed into place,
# so a folder that exists is whole.

# Names
# =====

# A snapshot's name: 1 to 64 of A-Z a-z 0-9 . _ -, not starting with "."
# (so never ".", "..", or a temporary folder), so it is one path component
# on every host.
def Sname.char_ok(+c: U32) -> Bool:
  (U32.is_le(48, c) && U32.is_le(c, 57)) || (U32.is_le(65, c) && U32.is_le(c, 90)) || (U32.is_le(97, c) && U32.is_le(c, 122))
    || U32.is_eq(c, 46) || U32.is_eq(c, 95) || U32.is_eq(c, 45)

def Sname.chars_ok(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      Sname.char_ok(Char.to_u32(c)) && Sname.chars_ok(rest)

def Sname.valid(+s: String) -> Bool:
  +n = String.length(s)
  Nat.is_lt(0n, n) && Nat.is_le(n, 64n) && Bool.not(String.starts_with(s, ".")) && Sname.chars_ok(s)

# Two digits, zero-padded.
def Sname.two(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "0" ++ U32.show(x), U32.show(x))

# The civil date of a day count since 1970-01-01 (Howard Hinnant's
# days_from_civil inverse), as year, month, day.
type Date is Data:
  Date{year: U32, month: U32, day: U32}

def Sname.date(+days: U32) -> Date:
  +z = (days + 719468 : U32)
  +era = (z / 146097 : U32)
  +doe = (z - (era * 146097 : U32) : U32)
  +yoe = (((doe - (doe / 1460 : U32) : U32) + (doe / 36524 : U32) - (doe / 146096 : U32) : U32) / 365 : U32)
  +doy = (doe - ((365 * yoe : U32) + (yoe / 4 : U32) - (yoe / 100 : U32) : U32) : U32)
  +mp = (((5 * doy : U32) + 2 : U32) / 153 : U32)
  +d = ((doy - ((((153 * mp : U32) + 2 : U32) / 5 : U32)) : U32) + 1 : U32)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), (mp + 3 : U32), (mp - 9 : U32))
  Date{((yoe + (era * 400 : U32) : U32) + Bool.to_u32(U32.is_le(m, 2)) : U32), m, d}

# The default name of a snapshot taken at a time (seconds since 1970, UTC):
# YYYY-MM-DD-HHMMSS, so names sort as times do.
def Sname.of_date(dt: Date, +t: U32) -> String:
  match dt:
    case Date{y, m, d}:
      U32.show(y) ++ "-" ++ Sname.two(m) ++ "-" ++ Sname.two(d) ++ "-" ++ Sname.two((t / 3600 : U32)) ++ Sname.two(((t / 60 : U32) % 60 : U32)) ++ Sname.two((t % 60 : U32))

def Sname.of_time(+secs: U32) -> String:
  Sname.of_date(Sname.date((secs / 86400 : U32)), (secs % 86400 : U32))

# The snapshot a restore takes first, so that the restore can be undone.
def Sname.undo(+secs: U32) -> String:
  "before-restore-" ++ Sname.of_time(secs)

# A generated name (the time's, an undo's) that is taken gets -2, -3, ...
# (names given by the user are refused instead). fuel: the most tried.
def Sname.taken(xs: List<&2, String>, +n: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      String.eq(x, n) || Sname.taken(rest, n)

def Sname.unique.go(fuel: Nat, +xs: List<&2, String>, +base: String, +k: U32) -> String:
  match fuel:
    case 0n:
      base ++ "-" ++ U32.show(k)
    case 1n+f:
      +n = Bool.pick(String, U32.is_lt(k, 2), base, base ++ "-" ++ U32.show(k))
      Bool.pick(String, Sname.taken(xs, n), Sname.unique.go(f, xs, base, (k + 1 : U32)), n)

def Sname.unique(+base: String, +xs: List<&2, String>) -> String:
  Sname.unique.go(100n, xs, base, 1)

# Layout
# ======

def Sdir.root(+vm: String) -> String:
  vm ++ "/snapshots"

def Sdir.dir(+vm: String, +name: String) -> String:
  Sdir.root(vm) ++ "/" ++ name

def Sdir.tmp(+vm: String, +name: String) -> String:
  Sdir.root(vm) ++ "/." ++ name ++ ".tmp"

def Sdir.memory(+dir: String) -> String:
  dir ++ "/memory"

def Sdir.disk(+dir: String, +i: U32) -> String:
  dir ++ "/disk" ++ U32.show(i)

def Sdir.info(+dir: String) -> String:
  dir ++ "/info"

# Metadata
# ========

# A snapshot as listed: its name, when it was taken (seconds since 1970),
# the snapshot it came from ("" when none: a VM booted fresh), its memory
# and its disks' own blocks (KiB), and a note.
type Info is Data:
  Info{name: String, time: U32, parent: String, mem_kib: U32, disk_kib: U32, note: String}

# A note is one line: its line breaks become spaces.
def Sdir.one_line(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, rest}:
      +x = Char.to_u32(c)
      SCon{Char.from_u32(Bool.pick(U32, U32.is_eq(x, 10) || U32.is_eq(x, 13), 32, x)), Sdir.one_line(rest)}

# The info file: one "key=value" line each.
def Sdir.info.text(i: Info) -> String:
  match i:
    case Info{n, t, p, m, d, note}:
      "name=" ++ n ++ "\ntime=" ++ U32.show(t) ++ "\nparent=" ++ p ++ "\nmemory_kib=" ++ U32.show(m) ++ "\ndisk_kib=" ++ U32.show(d) ++ "\nnote=" ++ Sdir.one_line(note) ++ "\n"

# A value after "key=" on its line, "" when the key is missing.
def Sdir.field(lines: List<&2, String>, +key: String) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{+l, rest}:
      Bool.pick(String, String.starts_with(l, key ++ "="), String.drop(l, Nat.add(String.length(key), 1n)), Sdir.field(rest, key))

def Sdir.num(+s: String) -> U32:
  Maybe.default(&2, U32, U32.read(s), 0)

def Sdir.info.parse(+text: String) -> Info:
  +ls = String.split(text, '\n')
  Info{Sdir.field(ls, "name"), Sdir.num(Sdir.field(ls, "time")), Sdir.field(ls, "parent"),
    Sdir.num(Sdir.field(ls, "memory_kib")), Sdir.num(Sdir.field(ls, "disk_kib")), Sdir.field(ls, "note")}

# Listing and pruning
# ===================

def Sdir.time(i: Info) -> U32:
  match i:
    case Info{n, t, p, m, d, note}:
      t

def Sdir.name(i: Info) -> String:
  match i:
    case Info{n, t, p, m, d, note}:
      n

def Sdir.cmp_of(r: (String & String) & Cmp) -> Cmp:
  match r:
    case (p, c):
      c

def Sdir.parent(i: Info) -> String:
  match i:
    case Info{n, t, p, m, d, note}:
      p

# a before b: older first; in the same second, a snapshot before the one
# taken from it, then by name.
def Sdir.before(+a: Info, +b: Info) -> Bool:
  +same = U32.is_eq(Sdir.time(a), Sdir.time(b))
  +a_first = String.eq(Sdir.parent(b), Sdir.name(a))
  +b_first = String.eq(Sdir.parent(a), Sdir.name(b))
  U32.is_lt(Sdir.time(a), Sdir.time(b))
    || (same && a_first)
    || (same && Bool.not(b_first) && Cmp.is_lt(Sdir.cmp_of(String.cmp(Sdir.name(a), Sdir.name(b)))))

def Sdir.insert(xs: List<&2, Info>, +x: Info) -> List<&2, Info>:
  match xs:
    case Nil{}:
      [x]
    case Con{+y, +rest}:
      Bool.pick(List<&2, Info>, Sdir.before(x, y), Con{x, Con{y, rest}}, Con{y, Sdir.insert(rest, x)})

# A listing, oldest first (a parent before its child in the same second).
def Sdir.sorted(xs: List<&2, Info>, +acc: List<&2, Info>) -> List<&2, Info>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      Sdir.sorted(rest, Sdir.insert(acc, x))

def Sdir.names(xs: List<&2, Info>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, rest}:
      Con{Sdir.name(x), Sdir.names(rest)}

# prune --keep N: the snapshots it removes, the oldest past the newest N.
def Sdir.prune(+xs: List<&2, Info>, +keep: U32) -> List<&2, String>:
  +all = Sdir.sorted(xs, [])
  +n = List.length(&2, Info, all)
  Sdir.names(List.take(&2, Info, all, Nat.sub(n, U32.to_nat(keep))))

# Which VM
# ========

# What a command means by its VM: the one named, else the only one running.
type Pick is Data:
  PVm{vm: String}
  PNone{}
  PMany{count: U32}

def Vmsel.pick(+given: String, +running: List<&2, String>) -> Pick:
  +n = U32.from_nat(List.length(&2, String, running))
  Bool.pick(Pick, Bool.not(String.is_empty(given)), PVm{given},
    Bool.pick(Pick, U32.is_eq(n, 0), PNone{},
      Bool.pick(Pick, U32.is_eq(n, 1), PVm{Maybe.default(&2, String, List.head(&2, String, running), "")}, PMany{n})))

def Vmsel.why(p: Pick) -> String:
  match p:
    case PVm{v}:
      ""
    case PNone{}:
      "no VM is running here"
    case PMany{n}:
      U32.show(n) ++ " VMs are running: name one"
