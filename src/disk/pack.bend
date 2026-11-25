import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./store.bend as S

# A pack (laws/pack.bend): one read-only virtio-blk device whose content is a
# concatenation of host files, extended while the VM runs (bend-vk8s: one
# squashfs image per container image layer, loop-mounted from the pack at
# its offset; a virtio-blk read is a large request where a 9p share's are
# 4 KiB pages).
#
# Each file added takes a slot at the pack's end: its offset is where the
# last slot ended (Pack.next), and its slot is its length rounded up to 1 MiB
# (at least 1 MiB). Slots tile [0, next) in order and never move. Dropping an
# entry marks it dead and keeps its slot: an offset is never handed out
# twice, so the guest's cache of the device can never show one file's bytes
# for another. The capacity is next and only grows.
#
# A read of the device is split by slot (Pack.split): an entry's bytes come
# from its file, the rest of its slot reads as zeros, a dead slot and
# anything past the end fail (IOERR).
#
# Files are opened on demand into a small cache of host descriptors: entry n
# always uses slot n mod Pack.slots() (direct-mapped: the choice needs no
# state). The host answers a read with the bytes it moved, or a miss when
# the slot holds another entry (or none); on a miss the file is opened again
# and must still be the file that was added (Pack.same: device, inode, size
# and modification time), else the read fails and the slot is let go.

# Where a file sits on the host: what fstat says when it is opened.
type PackId is Data:
  PackId{dev: U.U64, ino: U.U64, size: U.U64, mtime: U.U64, mnsec: U32}

# An entry: its number (in order of adding), offset in the pack, length (the
# file's), host path and identity, and whether it is still live.
type PackEntry is Data:
  PackEntry{n: U32, off: U.U64, len: U.U64, path: String, id: PackId, live: Bool}

# A pack: its name (the device's serial), entries in offset order, the end
# of the last slot, and how many entries were ever added.
type Pack is Data:
  Pack{name: String, entries: +List<PackEntry>, next: U.U64, count: U32}

# A part of a read: n bytes of an entry's file from offset foff, n bytes of
# zeros, n bytes of a dead slot, n bytes past the end.
type Piece is Data:
  PFile{entry: PackEntry, foff: U.U64, n: U32}
  PZero{n: U32}
  PDead{n: U32}
  PPast{n: U32}

# What follows a host read of want bytes that answered got.
type ReadNext is Data:
  RDone{}
  ROpen{}
  RFail{}

# 1 MiB: every slot starts at a multiple of it.
def Pack.align_bits() -> Nat:
  20n

def Pack.align() -> U.U64:
  U.U64{0, 1048576}

# The host's descriptor slots (src/net/fds.bend keeps a spare for them).
def Pack.slots() -> U32:
  64

# A host read's answer: the slot holds another entry (or none).
def Pack.miss() -> U32:
  4294967295

# The longest name: virtio-blk's id string is 20 bytes.
def Pack.max_name() -> Nat:
  20n

def Pack.new(name: String) -> Pack:
  Pack{name, [], U.U64.zero(), 0}

def Pack.name(p: Pack) -> String:
  match p:
    case Pack{nm, es, nx, c}:
      nm

def Pack.entries(p: Pack) -> +List<PackEntry>:
  match p:
    case Pack{nm, es, nx, c}:
      es

# The end of the last slot: where the next file goes.
def Pack.next(p: Pack) -> U.U64:
  match p:
    case Pack{nm, es, nx, c}:
      nx

def Pack.count(p: Pack) -> U32:
  match p:
    case Pack{nm, es, nx, c}:
      c

# The device's capacity in 512-byte sectors.
def Pack.sectors(p: Pack) -> U.U64:
  U.U64.shr(9n, Pack.next(p))

# A file of len bytes takes this much of the pack: len rounded up to 1 MiB,
# and 1 MiB for an empty file (a slot is never empty: offsets stay apart).
def Pack.slot_len(+len: U.U64) -> U.U64:
  +a = U.U64.align_up(Pack.align_bits(), len)
  Bool.pick(U.U64, U.U64.is_zero(a), Pack.align(), a)

def PackId.size(i: PackId) -> U.U64:
  match i:
    case PackId{d, ino, sz, mt, ns}:
      sz

def PackEntry.n(e: PackEntry) -> U32:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      n

def PackEntry.off(e: PackEntry) -> U.U64:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      off

def PackEntry.len(e: PackEntry) -> U.U64:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      len

def PackEntry.path(e: PackEntry) -> String:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      path

def PackEntry.id(e: PackEntry) -> PackId:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      id

def PackEntry.live(e: PackEntry) -> Bool:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      live

# The end of an entry's slot.
def PackEntry.end(e: PackEntry) -> U.U64:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      U.U64.add(off, Pack.slot_len(len))

# Adds the file at path (identity id, which says its length): it takes the
# slot at Pack.next.
def Pack.add(p: Pack, path: String, +id: PackId) -> Pack:
  match p:
    case Pack{nm, es, +nx, +c}:
      +len = PackId.size(id)
      Pack{nm, List.append(&2, PackEntry, es, [PackEntry{c, nx, len, path, id, True{}}]), U.U64.add(nx, Pack.slot_len(len)), (c + 1 : U32)}

# The entries with the one at offset off dead (the others as they were).
def Pack.kill(es: +List<PackEntry>, +off: U.U64) -> +List<PackEntry>:
  match es:
    case Nil{}:
      []
    case PackEntry{n, +o, len, path, id, +live} <> t:
      PackEntry{n, o, len, path, id, live && Bool.not(U.U64.is_eq(o, off))} <> Pack.kill(t, off)

# Drops the entry at offset off: it is dead from now on, and its slot is
# never given again (next does not move).
def Pack.drop(p: Pack, off: U.U64) -> Pack:
  match p:
    case Pack{nm, es, nx, c}:
      Pack{nm, Pack.kill(es, off), nx, c}

# Whether a live entry starts at offset off (what pack drop may drop).
def Pack.has_live(es: +List<PackEntry>, +off: U.U64) -> Bool:
  match es:
    case Nil{}:
      False{}
    case PackEntry{n, o, len, path, id, live} <> t:
      (live && U.U64.is_eq(o, off)) || Pack.has_live(t, off)

def Pack.can_drop(p: Pack, off: U.U64) -> Bool:
  Pack.has_live(Pack.entries(p), off)

# The end of the last slot (at when there is none).
def Pack.ends(es: +List<PackEntry>, at: U.U64) -> U.U64:
  match es:
    case Nil{}:
      at
    case +e <> t:
      Pack.ends(t, PackEntry.end(e))

# Whether the entries tile from offset at on: each starts where the last
# slot ended (no two overlap, none is left out).
def Pack.tiles.go(es: +List<PackEntry>, +at: U.U64) -> Bool:
  match es:
    case Nil{}:
      True{}
    case +e <> t:
      U.U64.is_eq(PackEntry.off(e), at) && Pack.tiles.go(t, PackEntry.end(e))

# Whether the pack's slots tile [0, next).
def Pack.tiles(p: Pack) -> Bool:
  match p:
    case Pack{nm, +es, nx, c}:
      Pack.tiles.go(es, U.U64.zero()) && U.U64.is_eq(Pack.ends(es, U.U64.zero()), nx)

# The entry whose slot holds offset x.
def Pack.find(es: +List<PackEntry>, +x: U.U64) -> Maybe<&2, PackEntry>:
  match es:
    case Nil{}:
      None{}
    case +e <> t:
      Bool.pick(Maybe<&2, PackEntry>, U.U64.is_le(PackEntry.off(e), x) && U.U64.is_lt(x, PackEntry.end(e)), Some{e}, Pack.find(t, x))

# min(r, d) for a U64 distance d.
def Pack.min(+r: U32, d: U.U64) -> U32:
  match d:
    case U.U64{h, +l}:
      Bool.pick(U32, U32.is_ne(h, 0) || U32.is_le(r, l), r, l)

def Piece.len(p: Piece) -> U32:
  match p:
    case PFile{e, o, n}:
      n
    case PZero{n}:
      n
    case PDead{n}:
      n
    case PPast{n}:
      n

# The piece at x (at most r bytes) inside entry e's slot.
def Pack.piece.of(live: Bool, +e: PackEntry, +x: U.U64, +r: U32) -> Piece:
  match live:
    case False{}:
      PDead{Pack.min(r, U.U64.sub(PackEntry.end(e), x))}
    case True{}:
      +fend = U.U64.add(PackEntry.off(e), PackEntry.len(e))
      Bool.pick(Piece, U.U64.is_lt(x, fend), PFile{e, U.U64.sub(x, PackEntry.off(e)), Pack.min(r, U.U64.sub(fend, x))},
        PZero{Pack.min(r, U.U64.sub(PackEntry.end(e), x))})

# The piece at x (at most r bytes): past the end when no slot holds x.
def Pack.piece(m: Maybe<&2, PackEntry>, +x: U.U64, +r: U32) -> Piece:
  match m:
    case None{}:
      PPast{r}
    case Some{+e}:
      Pack.piece.of(PackEntry.live(e), e, x, r)

# The pieces of r bytes from x on. Each piece ends at the read's end or at a
# slot's or a file's end, so 2 per entry and one more suffice (fuel).
def Pack.split.go(fuel: Nat, done: Bool, +es: +List<PackEntry>, +x: U.U64, +r: U32) -> +List<Piece>:
  match fuel:
    case 0n:
      Bool.pick(+List<Piece>, U32.is_zero(r), [], [PPast{r}])
    case 1n+f:
      match done:
        case True{}:
          []
        case False{}:
          +pc = Pack.piece(Pack.find(es, x), x, r)
          +n = Piece.len(pc)
          pc <> Pack.split.go(f, U32.is_eq(n, r), es, U.U64.add_u32(x, n), (r - n : U32))

# A read of len bytes at byte offset off, as pieces in order; their lengths
# add up to len.
def Pack.split(p: Pack, +off: U.U64, +len: U32) -> +List<Piece>:
  match p:
    case Pack{nm, +es, nx, c}:
      Pack.split.go(Nat.add(Nat.mul(2n, List.length(&2, PackEntry, es)), 2n), U32.is_zero(len), es, off, len)

# The descriptor slot of entry n, and its key there (0: an empty slot).
def Pack.slot_of(n: U32) -> U32:
  (n % Pack.slots() : U32)

def Pack.key_of(n: U32) -> U32:
  (n + 1 : U32)

# After a host read of want bytes answered got: done when it moved them all,
# open the file again on a miss, else fail (an error, or a short read: the
# file changed).
def Pack.on_read(+got: U32, +want: U32) -> ReadNext:
  Bool.pick(ReadNext, U32.is_eq(got, want), RDone{}, Bool.pick(ReadNext, U32.is_eq(got, Pack.miss()), ROpen{}, RFail{}))

# The identity in what the host answered an open: [0, dev hi, lo, ino hi, lo,
# size hi, lo, mtime hi, lo, mtime ns]; anything else (an errno) is none.
def Pack.w(+ws: +List<U32>, i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, i), 0)

def Pack.facts(+ws: +List<U32>) -> Maybe<&2, PackId>:
  Bool.pick(Maybe<&2, PackId>, Nat.is_eq(List.length(&2, U32, ws), 10n) && U32.is_zero(Pack.w(ws, 0n)),
    Some{PackId{U.U64{Pack.w(ws, 1n), Pack.w(ws, 2n)}, U.U64{Pack.w(ws, 3n), Pack.w(ws, 4n)}, U.U64{Pack.w(ws, 5n), Pack.w(ws, 6n)}, U.U64{Pack.w(ws, 7n), Pack.w(ws, 8n)}, Pack.w(ws, 9n)}},
    None{})

# The errno in what the host answered an open (0: it opened).
def Pack.errno(+ws: +List<U32>) -> U32:
  Bool.pick(U32, Nat.is_eq(List.length(&2, U32, ws), 1n), Pack.w(ws, 0n), 0)

def PackId.is_eq(a: PackId, b: PackId) -> Bool:
  match a:
    case PackId{d1, i1, s1, m1, n1}:
      match b:
        case PackId{d2, i2, s2, m2, n2}:
          U.U64.is_eq(d1, d2) && U.U64.is_eq(i1, i2) && U.U64.is_eq(s1, s2) && U.U64.is_eq(m1, m2) && U32.is_eq(n1, n2)

# Whether a reopened file is still the one that was added.
def Pack.same(+id: PackId, m: Maybe<&2, PackId>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{now}:
      PackId.is_eq(id, now)

# Reads
# =====
# Each returns virtio-blk's status: 0 OK, 1 IOERR.

def Pack.reread(-R: Type, +got: U32, +want: U32) -> V.Op<R, U32>:
  V.Op.pure(R, U32, Bool.pick(U32, U32.is_eq(got, want), 0, 1))

# After the reopen: read again when it is the same file, else let the slot go.
def Pack.read.reopened(-R: Type, same: Bool, +slot: U32, +key: U32, +foff: U.U64, +a: +List<V.Iov>) -> V.Op<R, U32>:
  match same:
    case True{}:
      do V.Op<R, U32>:
        +got : U32 <- V.Op.pack_read(R, slot, key, foff, a)
        Pack.reread(R, got, V.Iov.total(a))
    case False{}:
      do V.Op<R, U32>:
        V.Op.pack_close(R, slot, key)
        return 1

def Pack.read.next(-R: Type, nx: ReadNext, +slot: U32, +key: U32, +path: String, +id: PackId, +foff: U.U64, +a: +List<V.Iov>) -> V.Op<R, U32>:
  match nx:
    case RDone{}:
      V.Op.pure(R, U32, 0)
    case RFail{}:
      V.Op.pure(R, U32, 1)
    case ROpen{}:
      do V.Op<R, U32>:
        ws : +List<U32> <- V.Op.pack_open(R, slot, key, path)
        Pack.read.reopened(R, Pack.same(id, Pack.facts(ws)), slot, key, foff, a)

# n bytes of an entry's file from foff into the pieces of memory a.
def Pack.read.file(-R: Type, e: PackEntry, +foff: U.U64, +a: +List<V.Iov>) -> V.Op<R, U32>:
  match e:
    case PackEntry{+n, off, len, path, id, live}:
      +slot = Pack.slot_of(n)
      +key = Pack.key_of(n)
      do V.Op<R, U32>:
        +got : U32 <- V.Op.pack_read(R, slot, key, foff, a)
        Pack.read.next(R, Pack.on_read(got, V.Iov.total(a)), slot, key, path, id, foff, a)

# One piece into the memory a.
def Pack.read.piece(-R: Type, pc: Piece, +a: +List<V.Iov>) -> V.Op<R, U32>:
  match pc:
    case PFile{e, foff, n}:
      Pack.read.file(R, e, foff, a)
    case PZero{n}:
      do V.Op<R, U32>:
        V.Op.zero_ram(R, a)
        return 0
    case PDead{n}:
      V.Op.pure(R, U32, 1)
    case PPast{n}:
      V.Op.pure(R, U32, 1)

# The rest of the pieces, unless one failed.
def Pack.read.then(-R: Type, +s: U32, more: V.Op<R, U32>) -> V.Op<R, U32>:
  Bool.pick(V.Op<R, U32>, U32.is_zero(s), more, V.Op.pure(R, U32, s))

# The pieces into the memory iovs, in order; stops at the first that fails.
def Pack.read.pieces(-R: Type, pcs: +List<Piece>, +iovs: +List<V.Iov>) -> V.Op<R, U32>:
  match pcs:
    case Nil{}:
      V.Op.pure(R, U32, 0)
    case +pc <> t:
      +n = Piece.len(pc)
      do V.Op<R, U32>:
        +s : U32 <- Pack.read.piece(R, pc, S.Iov.take(iovs, n))
        Pack.read.then(R, s, Pack.read.pieces(R, t, S.Iov.drop(iovs, n)))

# A read of the device at byte offset off into the memory iovs: status 0 OK,
# 1 IOERR.
def Pack.read(-R: Type, +p: Pack, +off: U.U64, +iovs: +List<V.Iov>) -> V.Op<R, U32>:
  Pack.read.pieces(R, Pack.split(p, off, V.Iov.total(iovs)), iovs)

# Numbers and names
# =================

# x / 10 and x % 10, by long division in 16-bit steps (no U32 overflows).
def Pack.div10(x: U.U64) -> U.U64:
  match x:
    case U.U64{+h, +l}:
      +a = (((h % 10 : U32) * 65536 : U32) + (l >> 16n : U32) : U32)
      +b = (((a % 10 : U32) * 65536 : U32) + (l .&. 65535 : U32) : U32)
      U.U64{(h / 10 : U32), (((a / 10 : U32) << 16n : U32) .|. (b / 10 : U32) : U32)}

def Pack.mod10(x: U.U64) -> U32:
  match x:
    case U.U64{+h, +l}:
      +a = (((h % 10 : U32) * 65536 : U32) + (l >> 16n : U32) : U32)
      ((((a % 10 : U32) * 65536 : U32) + (l .&. 65535 : U32) : U32) % 10 : U32)

def Pack.dec.go(fuel: Nat, done: Bool, +x: U.U64, +acc: String) -> String:
  match fuel:
    case 0n:
      acc
    case 1n+f:
      match done:
        case True{}:
          acc
        case False{}:
          +q = Pack.div10(x)
          Pack.dec.go(f, U.U64.is_zero(q), q, SCon{Char.from_u32((48 + Pack.mod10(x) : U32)), acc})

# A U64 in decimal (at most 20 digits).
def Pack.dec(x: U.U64) -> String:
  Pack.dec.go(21n, False{}, x, "")

# x * 10 + d.
def Pack.times10(+x: U.U64, +d: U32) -> U.U64:
  U.U64.add_u32(U.U64.add(U.U64.shl(3n, x), U.U64.shl(1n, x)), d)

def Pack.parse.go(cs: String, +acc: U.U64, +n: Nat) -> Maybe<&2, U.U64>:
  match cs:
    case SNil{}:
      Bool.pick(Maybe<&2, U.U64>, Nat.is_eq(n, 0n), None{}, Some{acc})
    case SCon{c, t}:
      +d = (Char.to_u32(c) - 48 : U32)
      Bool.pick(Maybe<&2, U.U64>, U32.is_lt(d, 10) && Nat.is_lt(n, 19n), Pack.parse.go(t, Pack.times10(acc, d), Nat.add(n, 1n)), None{})

# A decimal number (1 to 19 digits, nothing else).
def Pack.parse(s: String) -> Maybe<&2, U.U64>:
  Pack.parse.go(s, U.U64.zero(), 0n)

def Pack.name_char(+c: U32) -> Bool:
  (U32.is_le(97, c) && U32.is_le(c, 122)) || (U32.is_le(65, c) && U32.is_le(c, 90)) || (U32.is_le(48, c) && U32.is_le(c, 57))
    || U32.is_eq(c, 46) || U32.is_eq(c, 95) || U32.is_eq(c, 45)

def Pack.name_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Pack.name_char(Char.to_u32(c)) && Pack.name_chars(t)

# A pack's name (its serial): 1 to 20 of [A-Za-z0-9._-].
def Pack.name_ok(+s: String) -> Bool:
  Nat.is_lt(0n, String.length(s)) && Nat.is_le(String.length(s), Pack.max_name()) && Pack.name_chars(s)

# JSON
# ====

def Pack.hex1(+d: U32) -> Char:
  Char.from_u32(Bool.pick(U32, U32.is_lt(d, 10), (48 + d : U32), (87 + d : U32)))

# A character of a JSON string: quote and backslash escaped, control
# characters as \u00XX.
def Pack.json_char(+c: U32, +rest: String) -> String:
  Bool.pick(String, U32.is_eq(c, 34) || U32.is_eq(c, 92), SCon{Char.from_u32(92), SCon{Char.from_u32(c), rest}},
    Bool.pick(String, U32.is_lt(c, 32), SCon{Char.from_u32(92), SCon{Char.from_u32(117), SCon{Char.from_u32(48), SCon{Char.from_u32(48), SCon{Pack.hex1((c >> 4n : U32)), SCon{Pack.hex1((c .&. 15 : U32)), rest}}}}}},
      SCon{Char.from_u32(c), rest}))

def Pack.json_chars(s: String) -> String:
  match s:
    case SNil{}:
      SCon{Char.from_u32(34), SNil{}}
    case SCon{c, t}:
      Pack.json_char(Char.to_u32(c), Pack.json_chars(t))

def Pack.json_str(s: String) -> String:
  SCon{Char.from_u32(34), Pack.json_chars(s)}

def Pack.json_entry(e: PackEntry) -> String:
  match e:
    case PackEntry{n, off, len, path, id, live}:
      "{\"offset\":" ++ Pack.dec(off) ++ ",\"length\":" ++ Pack.dec(len) ++ ",\"path\":" ++ Pack.json_str(path) ++ ",\"live\":" ++ Bool.pick(String, live, "true", "false") ++ "}"

def Pack.json_entries(es: +List<PackEntry>, +first: Bool) -> String:
  match es:
    case Nil{}:
      ""
    case e <> t:
      Bool.pick(String, first, "", ",") ++ Pack.json_entry(e) ++ Pack.json_entries(t, False{})

# The pack for status json: {"name":..,"size":bytes,"entries":[..]}.
def Pack.json(p: Pack) -> String:
  match p:
    case Pack{nm, es, nx, c}:
      "{\"name\":" ++ Pack.json_str(nm) ++ ",\"size\":" ++ Pack.dec(nx) ++ ",\"entries\":[" ++ Pack.json_entries(es, True{}) ++ "]}"
