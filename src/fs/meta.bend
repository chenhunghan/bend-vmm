import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V

# Linux metadata for a share's files (laws/meta.bend), asked by bend-vk8s
# for container image layers kept on a macOS host: `--share DIR,meta`.
#
# Each directory of such a share may hold `.bend-meta`, text, one record a
# line after the first line `bend-meta 1`. A record is space-separated
# key=value tokens; unknown keys are ignored, so the format can grow:
#   name=NAME      the entry's name in the guest (percent-encoded; needed)
#   host=NAME      its name on the host (percent-encoded; default: name)
#   type=f|d|l|c|b|p   regular, directory, symlink, char or block device,
#                  FIFO (default: what the host has)
#   mode=OCTAL     permission bits with setuid, setgid and sticky
#   uid=N gid=N    owner
#   rdev=MAJ,MIN   a device's numbers
#   mtime=S[.NS]   modification time, seconds and nanoseconds
#   ino=N nlink=N  inode number and link count (hard links)
#   xattr.NAME=HEX an extended attribute (NAME percent-encoded)
# A directory with records lists exactly its records, by their names, and
# looks names up among them alone; the host's names never show. No IO here.

type Xattr is Data:
  Xattr{name: String, value: +List<U32>}

# has: which keys a record gave (1 type, 2 mode, 4 uid, 8 gid, 16 rdev,
# 32 mtime, 64 ino, 128 nlink, 256 host). kind: 1 f, 2 d, 3 l, 4 c, 5 b, 6 p.
type Rec is Data:
  Rec{name: String, host: String, kind: U32, mode: U32, uid: U32, gid: U32, major: U32, minor: U32, mtime: U.U64, mnsec: U32, ino: U.U64, nlink: U32, has: U32, xattrs: List<&2, Xattr>}

def Meta.file() -> String:
  ".bend-meta"

def Meta.header() -> String:
  "bend-meta 1"

def Meta.empty() -> Rec:
  Rec{"", "", 0, 0, 0, 0, 0, 0, U.U64.zero(), 0, U.U64.zero(), 0, 0, []}

# Hex and percent decoding.
def Meta.hexval(+c: U32) -> U32:
  Bool.pick(U32, U32.is_ge(c, 48) && U32.is_le(c, 57), (c - 48 : U32),
  Bool.pick(U32, U32.is_ge(c, 97) && U32.is_le(c, 102), (c - 87 : U32),
  Bool.pick(U32, U32.is_ge(c, 65) && U32.is_le(c, 70), (c - 55 : U32), 16)))

def Meta.hex(s: String) -> +List<U32>:
  match s:
    case SNil{}:
      []
    case SCon{a, SNil{}}:
      []
    case SCon{a, SCon{b, rest}}:
      Con{((Meta.hexval(Char.to_u32(a)) << 4n : U32) .|. Meta.hexval(Char.to_u32(b)) : U32), Meta.hex(rest)}

# "%41" is "A"; any other character is itself (a name's bytes as chars).
def Meta.pct(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, rest}:
      match rest:
        case SCon{+a, SCon{+b, +more}}:
          Bool.pick(String, U32.is_eq(Char.to_u32(c), 37) && U32.is_lt(Meta.hexval(Char.to_u32(a)), 16) && U32.is_lt(Meta.hexval(Char.to_u32(b)), 16),
            SCon{Char.from_u32(((Meta.hexval(Char.to_u32(a)) << 4n : U32) .|. Meta.hexval(Char.to_u32(b)) : U32)), Meta.pct(more)},
            SCon{c, Meta.pct(SCon{a, SCon{b, more}})})
        case _:
          SCon{c, Meta.pct(rest)}

# Numbers: decimal (U32 and U64) and octal.
def Meta.dec.go(s: String, +acc: U32, +ok: Bool) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      Bool.pick(Maybe<&2, U32>, ok, Some{acc}, None{})
    case SCon{c, rest}:
      +d : U32 = (Char.to_u32(c) - 48 : U32)
      Bool.pick(Maybe<&2, U32>, U32.is_lt(d, 10), Meta.dec.go(rest, ((acc * 10 : U32) + d : U32), True{}), None{})

def Meta.dec(s: String) -> Maybe<&2, U32>:
  Meta.dec.go(s, 0, False{})

def Meta.oct.go(s: String, +acc: U32, +ok: Bool) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      Bool.pick(Maybe<&2, U32>, ok, Some{acc}, None{})
    case SCon{c, rest}:
      +d : U32 = (Char.to_u32(c) - 48 : U32)
      Bool.pick(Maybe<&2, U32>, U32.is_lt(d, 8), Meta.oct.go(rest, ((acc << 3n : U32) .|. d : U32), True{}), None{})

def Meta.oct(s: String) -> Maybe<&2, U32>:
  Meta.oct.go(s, 0, False{})

# acc * 10 + d in 64 bits (10x is 8x + 2x).
def Meta.dec64.step(+acc: U.U64, +d: U32) -> U.U64:
  U.U64.add_u32(U.U64.add(U.U64.shl(3n, acc), U.U64.shl1(acc)), d)

def Meta.dec64.go(s: String, +acc: U.U64, +ok: Bool) -> Maybe<&2, U.U64>:
  match s:
    case SNil{}:
      Bool.pick(Maybe<&2, U.U64>, ok, Some{acc}, None{})
    case SCon{c, rest}:
      +d : U32 = (Char.to_u32(c) - 48 : U32)
      Bool.pick(Maybe<&2, U.U64>, U32.is_lt(d, 10), Meta.dec64.go(rest, Meta.dec64.step(acc, d), True{}), None{})

def Meta.dec64(s: String) -> Maybe<&2, U.U64>:
  Meta.dec64.go(s, U.U64.zero(), False{})

# A string split at its first c: the part before and the part after ("",
# when there is no c: then the whole is before).
type Cut is Data:
  Cut{before: String, after: String}

def Cut.before(k: Cut) -> String:
  match k:
    case Cut{b, a}:
      b

def Cut.after(k: Cut) -> String:
  match k:
    case Cut{b, a}:
      a

def Meta.cut.add(+c: Char, k: Cut) -> Cut:
  match k:
    case Cut{b, a}:
      Cut{SCon{c, b}, a}

def Meta.cut(s: String, +c: Char) -> Cut:
  match s:
    case SNil{}:
      Cut{"", ""}
    case SCon{+x, +rest}:
      Bool.pick(Cut, U32.is_eq(Char.to_u32(x), Char.to_u32(c)), Cut{"", rest}, Meta.cut.add(x, Meta.cut(rest, c)))

def Meta.kind(+v: String) -> U32:
  Bool.pick(U32, String.eq(v, "f"), 1,
  Bool.pick(U32, String.eq(v, "d"), 2,
  Bool.pick(U32, String.eq(v, "l"), 3,
  Bool.pick(U32, String.eq(v, "c"), 4,
  Bool.pick(U32, String.eq(v, "b"), 5,
  Bool.pick(U32, String.eq(v, "p"), 6, 0))))))

def Meta.num(m: Maybe<&2, U32>) -> U32:
  Maybe.default(&2, U32, m, 0)

def Meta.got(m: Maybe<&2, U32>, +bit: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      bit

def Meta.got64(m: Maybe<&2, U.U64>, +bit: U32) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      bit

def Meta.num64(m: Maybe<&2, U.U64>) -> U.U64:
  Maybe.default(&2, U.U64, m, U.U64.zero())

# One key=value token on a record.
def Meta.token.kv(r: Rec, +k: String, +v: String) -> Rec:
  match r:
    case Rec{+n, +h, +t, +m, +u, +g, +ma, +mi, +mt, +ns, +ino, +nl, +has, +xs}:
      +rd : Cut = Meta.cut(v, ',')
      +ts : Cut = Meta.cut(v, '.')
      Bool.pick(Rec, String.eq(k, "name"), Rec{Meta.pct(v), h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs},
      Bool.pick(Rec, String.eq(k, "host"), Rec{n, Meta.pct(v), t, m, u, g, ma, mi, mt, ns, ino, nl, (has .|. 256 : U32), xs},
      Bool.pick(Rec, String.eq(k, "type"), Rec{n, h, Meta.kind(v), m, u, g, ma, mi, mt, ns, ino, nl, (has .|. Bool.pick(U32, U32.is_zero(Meta.kind(v)), 0, 1) : U32), xs},
      Bool.pick(Rec, String.eq(k, "mode"), Rec{n, h, t, (Meta.num(Meta.oct(v)) .&. 4095 : U32), u, g, ma, mi, mt, ns, ino, nl, (has .|. Meta.got(Meta.oct(v), 2) : U32), xs},
      Bool.pick(Rec, String.eq(k, "uid"), Rec{n, h, t, m, Meta.num(Meta.dec(v)), g, ma, mi, mt, ns, ino, nl, (has .|. Meta.got(Meta.dec(v), 4) : U32), xs},
      Bool.pick(Rec, String.eq(k, "gid"), Rec{n, h, t, m, u, Meta.num(Meta.dec(v)), ma, mi, mt, ns, ino, nl, (has .|. Meta.got(Meta.dec(v), 8) : U32), xs},
      Bool.pick(Rec, String.eq(k, "rdev"), Rec{n, h, t, m, u, g, Meta.num(Meta.dec(Cut.before(rd))), Meta.num(Meta.dec(Cut.after(rd))), mt, ns, ino, nl, (has .|. 16 : U32), xs},
      Bool.pick(Rec, String.eq(k, "mtime"), Rec{n, h, t, m, u, g, ma, mi, Meta.num64(Meta.dec64(Cut.before(ts))), Meta.num(Meta.dec(Cut.after(ts))), ino, nl, (has .|. Meta.got64(Meta.dec64(Cut.before(ts)), 32) : U32), xs},
      Bool.pick(Rec, String.eq(k, "ino"), Rec{n, h, t, m, u, g, ma, mi, mt, ns, Meta.num64(Meta.dec64(v)), nl, (has .|. Meta.got64(Meta.dec64(v), 64) : U32), xs},
      Bool.pick(Rec, String.eq(k, "nlink"), Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, Meta.num(Meta.dec(v)), (has .|. Meta.got(Meta.dec(v), 128) : U32), xs},
      Bool.pick(Rec, String.starts_with(k, "xattr."), Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, List.append(&2, Xattr, xs, [Xattr{Meta.pct(String.drop(k, 6n)), Meta.hex(v)}])},
        Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs})))))))))))

def Meta.token.cut(r: Rec, k: Cut) -> Rec:
  match k:
    case Cut{+key, +v}:
      Meta.token.kv(r, key, v)

def Meta.token(r: Rec, tok: String) -> Rec:
  Meta.token.cut(r, Meta.cut(tok, '='))

def Meta.tokens(ts: List<&2, String>, r: Rec) -> Rec:
  match ts:
    case Nil{}:
      r
    case Con{t, rest}:
      Meta.tokens(rest, Meta.token(r, t))

def Rec.name(r: Rec) -> String:
  match r:
    case Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs}:
      n

def Rec.has(r: Rec) -> U32:
  match r:
    case Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs}:
      has

# A record's host name defaults to its name.
def Meta.hosted(r: Rec) -> Rec:
  match r:
    case Rec{+n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, +has, xs}:
      Rec{n, Bool.pick(String, U32.is_zero((has .&. 256 : U32)), n, h), t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs}

# One line: a record, or none (a blank line, or one with no name).
def Meta.line.of(+r: Rec) -> Maybe<&2, Rec>:
  Bool.pick(Maybe<&2, Rec>, String.is_empty(Rec.name(r)), None{}, Some{Meta.hosted(r)})

def Meta.line(+l: String) -> Maybe<&2, Rec>:
  Meta.line.of(Meta.tokens(String.split(l, ' '), Meta.empty()))

def Meta.lines.add(m: Maybe<&2, Rec>, rest: List<&2, Rec>) -> List<&2, Rec>:
  match m:
    case None{}:
      rest
    case Some{r}:
      Con{r, rest}

def Meta.lines(ls: List<&2, String>) -> List<&2, Rec>:
  match ls:
    case Nil{}:
      []
    case Con{l, rest}:
      Meta.lines.add(Meta.line(l), Meta.lines(rest))

def Meta.parse.go(ls: List<&2, String>) -> Maybe<&2, List<&2, Rec>>:
  match ls:
    case Nil{}:
      None{}
    case Con{+first, rest}:
      Bool.pick(Maybe<&2, List<&2, Rec>>, String.eq(first, Meta.header()), Some{Meta.lines(rest)}, None{})

# A `.bend-meta` file's records, or none when its first line is not
# `bend-meta 1` (another version, or not one at all).
def Meta.parse(text: String) -> Maybe<&2, List<&2, Rec>>:
  Meta.parse.go(String.split(text, '\n'))

# 64-bit FNV-1a of a path's bytes: offset 0xcbf29ce484222325, prime
# 0x100000001b3 (2^40 + 435; 435 = 256 + 128 + 32 + 16 + 2 + 1), each byte
# XORed in, then the product kept to 64 bits.
def Meta.fnv.mul(+h: U.U64) -> U.U64:
  U.U64.add(U.U64.shl(40n, h), U.U64.add(U.U64.add(U.U64.shl(8n, h), U.U64.shl(7n, h)), U.U64.add(U.U64.add(U.U64.shl(5n, h), U.U64.shl(4n, h)), U.U64.add(U.U64.shl1(h), h))))

def Meta.fnv.go(s: String, +h: U.U64) -> U.U64:
  match s:
    case SNil{}:
      h
    case SCon{c, rest}:
      Meta.fnv.go(rest, Meta.fnv.mul(U.U64.xor(h, U.U64.from_u32((Char.to_u32(c) .&. 255 : U32)))))

def Meta.fnv(s: String) -> U.U64:
  Meta.fnv.go(s, U.U64{3421674724, 2216829733})

# The file type bits of st_mode for a kind (0: none given).
def Meta.type_bits(+kind: U32) -> U32:
  Bool.pick(U32, U32.is_eq(kind, 1), 32768,
  Bool.pick(U32, U32.is_eq(kind, 2), 16384,
  Bool.pick(U32, U32.is_eq(kind, 3), 40960,
  Bool.pick(U32, U32.is_eq(kind, 4), 8192,
  Bool.pick(U32, U32.is_eq(kind, 5), 24576,
  Bool.pick(U32, U32.is_eq(kind, 6), 4096, 0))))))

# A directory entry's type (DT_*) for st_mode's type bits.
def Meta.dtype(+mode: U32) -> U32:
  ((mode >> 12n : U32) .&. 15 : U32)

def Meta.bit(+has: U32, +b: U32) -> Bool:
  U32.is_ne((has .&. b : U32), 0)

# What the guest sees of a path: the host's attributes (h), with what its
# record gives in their place; its inode is the record's, else the FNV-1a
# hash of its share-relative path; a device or FIFO is 0 bytes long.
def Meta.attr(r: Rec, h: V.FsAttr, +path: String) -> V.FsResult:
  match r:
    case Rec{n, hn, +t, +m, u, g, ma, mi, mt, ns, ino, nl, +has, xs}:
      match h:
        case V.FsAttr{+hm, hu, hg, hnl, hs, hino, hb, at, hmt, ct}:
          +tb : U32 = Bool.pick(U32, Meta.bit(has, 1), Meta.type_bits(t), (hm .&. 61440 : U32))
          +pm : U32 = Bool.pick(U32, Meta.bit(has, 2), m, (hm .&. 4095 : U32))
          +dev : Bool = U32.is_eq(tb, 8192) || U32.is_eq(tb, 24576) || U32.is_eq(tb, 4096)
          V.FsGotMeta{V.FsAttr{(tb .|. pm : U32),
            Bool.pick(U32, Meta.bit(has, 4), u, hu), Bool.pick(U32, Meta.bit(has, 8), g, hg),
            Bool.pick(U32, Meta.bit(has, 128), nl, hnl),
            Bool.pick(U.U64, dev, U.U64.zero(), hs),
            Bool.pick(U.U64, Meta.bit(has, 64), ino, Meta.fnv(path)),
            Bool.pick(U.U64, dev, U.U64.zero(), hb), at,
            Bool.pick(U.U64, Meta.bit(has, 32), mt, hmt), ct},
            ma, mi, Bool.pick(U32, Meta.bit(has, 32), ns, 0)}

# A share marked meta carries Meta.bit() in its number (as Ro.bit(),
# src/fs/readonly.bend; a meta share is read-only too).
def Meta.bit_meta() -> U32:
  512

def Meta.is_meta(+share: U32) -> Bool:
  U32.is_ne((share .&. Meta.bit_meta() : U32), 0)

def Meta.bytes(s: String) -> +List<U32>:
  match s:
    case SNil{}:
      []
    case SCon{c, rest}:
      Con{(Char.to_u32(c) .&. 255 : U32), Meta.bytes(rest)}

def Meta.wstr(+s: String) -> +List<U32>:
  +bs : +List<U32> = Meta.bytes(s)
  Con{U32.from_nat(List.length(&2, U32, bs)), bs}

# A host name stays inside its directory: not empty, ".", "..", nor holding
# "/" or a 0 byte; a record naming another is left out.
def Meta.name_ok.chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, rest}:
      U32.is_ne(Char.to_u32(c), 47) && U32.is_ne(Char.to_u32(c), 0) && Meta.name_ok.chars(rest)

def Meta.name_ok(+s: String) -> Bool:
  Bool.not(String.is_empty(s) || String.eq(s, ".") || String.eq(s, "..")) && Meta.name_ok.chars(s)

def Rec.host(r: Rec) -> String:
  match r:
    case Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, xs}:
      h

# A table: how many records, and their words (guest name, host name, the
# line itself, each a length and its bytes).
type Table is Data:
  Table{n: U32, words: +List<U32>}

def Meta.table.put(t: Table, +l: String, +r: Rec) -> Table:
  match t:
    case Table{+n, +ws}:
      Bool.pick(Table, Meta.name_ok(Rec.name(r)) && Meta.name_ok(Rec.host(r)),
        Table{(n + 1 : U32), List.append(&2, U32, Meta.wstr(Rec.name(r)), List.append(&2, U32, Meta.wstr(Rec.host(r)), List.append(&2, U32, Meta.wstr(l), ws)))},
        Table{n, ws})

def Meta.table.add(t: Table, +l: String, m: Maybe<&2, Rec>) -> Table:
  match m:
    case None{}:
      t
    case Some{+r}:
      Meta.table.put(t, l, r)

def Meta.table.go(ls: List<&2, String>) -> Table:
  match ls:
    case Nil{}:
      Table{0, []}
    case Con{+l, rest}:
      Meta.table.add(Meta.table.go(rest), l, Meta.line(l))

def Meta.table.words(t: Table) -> +List<U32>:
  match t:
    case Table{n, ws}:
      Con{0, Con{n, ws}}

def Meta.table.of(m: Maybe<&2, List<&2, String>>) -> +List<U32>:
  match m:
    case None{}:
      [1, 0]
    case Some{ls}:
      Meta.table.words(Meta.table.go(ls))

def Meta.table.lines(ls: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match ls:
    case Nil{}:
      None{}
    case Con{+first, rest}:
      Bool.pick(Maybe<&2, List<&2, String>>, String.eq(first, Meta.header()), Some{rest}, None{})

# The words Hvf.meta_load takes for a directory: [1, 0] (plain: no
# .bend-meta, or not version 1), else [0, n, records].
def Meta.table(text: String) -> +List<U32>:
  Meta.table.of(Meta.table.lines(String.split(text, '\n')))

def Meta.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, rest}:
      SCon{Char.from_u32(b), Meta.chars(rest)}

def Meta.at(+ws: +List<U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, i), 0)

# A length-prefixed string at word i (its length, then its bytes).
def Meta.str_at(+ws: +List<U32>, +i: Nat) -> String:
  Meta.chars(List.take(&2, U32, List.drop(&2, U32, ws, Nat.add(i, 1n)), U32.to_nat(Meta.at(ws, i))))

# What Hvf.meta_resolve answered.
type Found is Data:
  # the host path, and its record's line when it has one
  Resolved{host: String, line: Maybe<&2, String>}
  # the directory of the path's first k parts has no table; its host path
  NeedTable{k: U32, hostdir: String}
  Missing{}

def Meta.found.line(+ws: +List<U32>, +at: Nat) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, U32.is_eq(Meta.at(ws, at), 4294967295), None{}, Some{Meta.str_at(ws, at)})

def Meta.found(+ws: +List<U32>) -> Found:
  +tag : U32 = Meta.at(ws, 0n)
  Bool.pick(Found, U32.is_eq(tag, 0), Resolved{Meta.str_at(ws, 1n), Meta.found.line(ws, Nat.add(2n, U32.to_nat(Meta.at(ws, 1n))))},
  Bool.pick(Found, U32.is_eq(tag, 1), NeedTable{Meta.at(ws, 1n), Meta.str_at(ws, 2n)}, Missing{}))

# The guest path of p's first k parts ("" for none).
def Meta.prefix.go(ps: List<&2, String>, +k: Nat) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{+p, rest}:
      match k:
        case 0n:
          ""
        case 1n:
          p
        case 1n+j:
          p ++ "/" ++ Meta.prefix.go(rest, j)

def Meta.prefix(p: String, +k: U32) -> String:
  Meta.prefix.go(String.split(p, '/'), U32.to_nat(k))

def Meta.join(+dir: String, +name: String) -> String:
  Bool.pick(String, String.is_empty(dir), name, dir ++ "/" ++ name)

# A record as a directory entry: its inode (the record's, else the hash of
# its path) and its type (DT_*; 0, unknown, when the record gives none).
def Meta.entry(+dir: String, +name: String, m: Maybe<&2, Rec>) -> V.FsEntry:
  match m:
    case None{}:
      V.FsEntry{name, Meta.fnv(Meta.join(dir, name)), 0}
    case Some{Rec{n, h, +t, mo, u, g, ma, mi, mt, ns, +ino, nl, +has, xs}}:
      V.FsEntry{name, Bool.pick(U.U64, Meta.bit(has, 64), ino, Meta.fnv(Meta.join(dir, name))), Bool.pick(U32, Meta.bit(has, 1), Meta.dtype(Meta.type_bits(t)), 0)}

def Meta.entries.go(+dir: String, +n: Nat, +ws: +List<U32>) -> List<&2, V.FsEntry>:
  match n:
    case 0n:
      []
    case 1n+k:
      +nl : Nat = U32.to_nat(Meta.at(ws, 0n))
      +name : String = Meta.str_at(ws, 0n)
      +rest : +List<U32> = List.drop(&2, U32, ws, Nat.add(1n, nl))
      +ll : Nat = U32.to_nat(Meta.at(rest, 0n))
      Con{Meta.entry(dir, name, Meta.line(Meta.str_at(rest, 0n))), Meta.entries.go(dir, k, List.drop(&2, U32, rest, Nat.add(1n, ll)))}

# A directory's entries from Hvf.meta_list's words, or none when it has
# no table or a plain one (then the host lists it).
def Meta.entries(+dir: String, +ws: +List<U32>) -> Maybe<&2, List<&2, V.FsEntry>>:
  Bool.pick(Maybe<&2, List<&2, V.FsEntry>>, U32.is_eq(Meta.at(ws, 0n), 1) && U32.is_zero(Meta.at(ws, 1n)),
    Some{Meta.entries.go(dir, U32.to_nat(Meta.at(ws, 2n)), List.drop(&2, U32, ws, 3n))}, None{})

# An extended attribute of a record: its value, or none (ENODATA). Name ""
# lists every name, each followed by a 0 byte.
def Meta.xattr.find(xs: List<&2, Xattr>, +name: String) -> Maybe<&2, +List<U32>>:
  match xs:
    case Nil{}:
      None{}
    case Con{Xattr{n, v}, rest}:
      Bool.pick(Maybe<&2, +List<U32>>, String.eq(n, name), Some{v}, Meta.xattr.find(rest, name))

def Meta.xattr.names(xs: List<&2, Xattr>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{Xattr{n, v}, rest}:
      List.append(&2, U32, Meta.bytes(n), Con{0, Meta.xattr.names(rest)})

def Meta.xattr(r: Rec, +name: String) -> Maybe<&2, +List<U32>>:
  match r:
    case Rec{n, h, t, m, u, g, ma, mi, mt, ns, ino, nl, has, +xs}:
      Bool.pick(Maybe<&2, +List<U32>>, String.is_empty(name), Some{Meta.xattr.names(xs)}, Meta.xattr.find(xs, name))
