import Base
import ../src/disk/pack.bend as P
import ../src/lib/u64.bend as U

# A pack disk for image layers (src/disk/pack.bend; bend-vk8s; approved by
# the owner 2026-11-25).
#
# The fixture: a pack "layers"; a (5 MiB + 3 bytes) at 0, its slot 6 MiB;
# b (empty) at 6 MiB, its slot 1 MiB; a dropped; c (1 MiB) at 7 MiB.

def pk.id(+sz: U32) -> P.PackId:
  P.PackId{U.U64{0, 1}, U.U64{0, sz}, U.U64{0, sz}, U.U64{0, 100}, 7}

def pk.a() -> P.Pack:
  P.Pack.add(P.Pack.new("layers"), "/l/a.sqfs", pk.id(5242883))

def pk.b() -> P.Pack:
  P.Pack.add(pk.a(), "/l/b.sqfs", pk.id(0))

def pk.d() -> P.Pack:
  P.Pack.drop(pk.b(), U.U64{0, 0})

def pk.c() -> P.Pack:
  P.Pack.add(pk.d(), "/l/c.sqfs", pk.id(1048576))

def pk.ea(live: Bool) -> P.PackEntry:
  P.PackEntry{0, U.U64{0, 0}, U.U64{0, 5242883}, "/l/a.sqfs", pk.id(5242883), live}

def pk.ec() -> P.PackEntry:
  P.PackEntry{2, U.U64{0, 7340032}, U.U64{0, 1048576}, "/l/c.sqfs", pk.id(1048576), True{}}

# Adding moves the end by the new slot, whatever the pack holds.
law pack.add_next:
  for p: P.Pack
  for path: String
  for id: P.PackId
  {P.Pack.next(P.Pack.add(p, path, id)) == U.U64.add(P.Pack.next(p), P.Pack.slot_len(P.PackId.size(id))) : U.U64}

# Dropping never moves the end: a dropped slot is never handed out again
# (every add takes the slot at the end).
law pack.drop_next:
  for p: P.Pack
  for off: U.U64
  {P.Pack.next(P.Pack.drop(p, off)) == P.Pack.next(p) : U.U64}

law pack.drop_count:
  for p: P.Pack
  for off: U.U64
  {P.Pack.count(P.Pack.drop(p, off)) == P.Pack.count(p) : U32}

# Slots: a file's length up to 1 MiB, an empty file 1 MiB.
law pack.slot_up:
  {P.Pack.slot_len(U.U64{0, 5242883}) == U.U64{0, 6291456} : U.U64}

law pack.slot_exact:
  {P.Pack.slot_len(U.U64{0, 1048576}) == U.U64{0, 1048576} : U.U64}

law pack.slot_empty:
  {P.Pack.slot_len(U.U64{0, 0}) == U.U64{0, 1048576} : U.U64}

law pack.slot_big:
  {P.Pack.slot_len(U.U64{2, 1}) == U.U64{2, 1048576} : U.U64}

# The fixture's entries: c goes after b, not into a's dropped slot.
law pack.entries:
  {P.Pack.entries(pk.c()) == [pk.ea(False{}), P.PackEntry{1, U.U64{0, 6291456}, U.U64{0, 0}, "/l/b.sqfs", pk.id(0), True{}}, pk.ec()] : List<&2, P.PackEntry>}

law pack.no_reuse:
  {P.Pack.next(pk.d()) == U.U64{0, 7340032} : U.U64}

# The slots tile the pack: no two overlap, none is left out.
law pack.tiles:
  {P.Pack.tiles(pk.c()) == True{} : Bool}

law pack.tiles_overlap:
  {P.Pack.tiles(P.Pack{"x", [pk.ea(True{}), P.PackEntry{1, U.U64{0, 5242880}, U.U64{0, 3}, "/b", pk.id(3), True{}}], U.U64{0, 7340032}, 2}) == False{} : Bool}

law pack.sectors:
  {P.Pack.sectors(pk.c()) == U.U64{0, 16384} : U.U64}

# Only a live entry's offset can be dropped.
law pack.can_drop:
  {P.Pack.can_drop(pk.c(), U.U64{0, 6291456}) == True{} : Bool}

law pack.can_drop_dead:
  {P.Pack.can_drop(pk.c(), U.U64{0, 0}) == False{} : Bool}

law pack.can_drop_inside:
  {P.Pack.can_drop(pk.c(), U.U64{0, 4096}) == False{} : Bool}

# Reads. Across a's file end, its zero tail, and the empty b.
law pack.split_tail:
  {P.Pack.split(pk.b(), U.U64{0, 5242880}, 2097152) == [P.PFile{pk.ea(True{}), U.U64{0, 5242880}, 3}, P.PZero{1048573}, P.PZero{1048576}] : List<&2, P.Piece>}

# Inside one file.
law pack.split_inside:
  {P.Pack.split(pk.c(), U.U64{0, 7340132}, 4096) == [P.PFile{pk.ec(), U.U64{0, 100}, 4096}] : List<&2, P.Piece>}

# A dead slot fails, also where a read moves on into the next slot.
law pack.split_dead:
  {P.Pack.split(pk.d(), U.U64{0, 4096}, 512) == [P.PDead{512}] : List<&2, P.Piece>}

law pack.split_dead_next:
  {P.Pack.split(pk.c(), U.U64{0, 6290944}, 1024) == [P.PDead{512}, P.PZero{512}] : List<&2, P.Piece>}

# Past the end.
law pack.split_past:
  {P.Pack.split(pk.c(), U.U64{0, 8388096}, 1024) == [P.PFile{pk.ec(), U.U64{0, 1048064}, 512}, P.PPast{512}] : List<&2, P.Piece>}

law pack.split_empty_pack:
  {P.Pack.split(P.Pack.new("x"), U.U64{0, 0}, 512) == [P.PPast{512}] : List<&2, P.Piece>}

law pack.split_none:
  {P.Pack.split(pk.c(), U.U64{0, 0}, 0) == [] : List<&2, P.Piece>}

# The descriptor cache: entry n in slot n mod 32, as key n + 1.
law pack.slot_of:
  {P.Pack.slot_of(65) == 1 : U32}

law pack.key_of:
  {P.Pack.key_of(0) == 1 : U32}

law pack.read_done:
  {P.Pack.on_read(4096, 4096) == P.RDone{} : P.ReadNext}

law pack.read_miss:
  {P.Pack.on_read(4294967295, 4096) == P.ROpen{} : P.ReadNext}

law pack.read_short:
  {P.Pack.on_read(100, 4096) == P.RFail{} : P.ReadNext}

# A reopened file must be the one added: device, inode, size, mtime.
law pack.same:
  {P.Pack.same(pk.id(5), P.Pack.facts([0, 0, 1, 0, 5, 0, 5, 0, 100, 7])) == True{} : Bool}

law pack.same_changed:
  {P.Pack.same(pk.id(5), P.Pack.facts([0, 0, 1, 0, 5, 0, 6, 0, 100, 7])) == False{} : Bool}

law pack.same_touched:
  {P.Pack.same(pk.id(5), P.Pack.facts([0, 0, 1, 0, 5, 0, 5, 0, 100, 8])) == False{} : Bool}

law pack.same_gone:
  {P.Pack.same(pk.id(5), P.Pack.facts([2])) == False{} : Bool}

law pack.errno:
  {P.Pack.errno([2]) == 2 : U32}

# Numbers.
law pack.dec:
  {P.Pack.dec(U.U64{1, 0}) == "4294967296" : String}

law pack.dec_zero:
  {P.Pack.dec(U.U64{0, 0}) == "0" : String}

law pack.dec_max:
  {P.Pack.dec(U.U64{4294967295, 4294967295}) == "18446744073709551615" : String}

law pack.parse:
  {P.Pack.parse("7340032") == Some{U.U64{0, 7340032}} : Maybe<&2, U.U64>}

law pack.parse_big:
  {P.Pack.parse("4294967296") == Some{U.U64{1, 0}} : Maybe<&2, U.U64>}

law pack.parse_empty:
  {P.Pack.parse("") == None{} : Maybe<&2, U.U64>}

law pack.parse_junk:
  {P.Pack.parse("12a") == None{} : Maybe<&2, U.U64>}

law pack.parse_long:
  {P.Pack.parse("12345678901234567890") == None{} : Maybe<&2, U.U64>}

# Names (the device's serial).
law pack.name:
  {P.Pack.name_ok("layers-1.x_y") == True{} : Bool}

law pack.name_empty:
  {P.Pack.name_ok("") == False{} : Bool}

law pack.name_slash:
  {P.Pack.name_ok("a/b") == False{} : Bool}

law pack.name_long:
  {P.Pack.name_ok("abcdefghijklmnopqrstu") == False{} : Bool}

# status json.
law pack.json:
  {P.Pack.json(pk.d()) == "{\"name\":\"layers\",\"size\":7340032,\"entries\":[{\"offset\":0,\"length\":5242883,\"path\":\"/l/a.sqfs\",\"live\":false},{\"offset\":6291456,\"length\":0,\"path\":\"/l/b.sqfs\",\"live\":true}]}" : String}

law pack.json_str:
  {P.Pack.json_str("a\"b\\c") == "\"a\\\"b\\\\c\"" : String}
