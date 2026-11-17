import Base
import ../src/fs/meta.bend as M
import ../src/vmm/abi.bend as V
import ../src/lib/u64.bend as U
import ../src/fs/p9.bend as F

# Spec for src/fs/meta.bend: Linux metadata for a share marked meta, from
# each directory's .bend-meta (asked by bend-vk8s, for image layers).

def a() -> V.FsAttr:
  V.FsAttr{33188, 502, 20, 1, U.U64{0, 11}, U.U64{0, 77}, U.U64{0, 8}, U.U64{0, 5}, U.U64{0, 6}, U.U64{0, 7}}

def rec(l: String) -> M.Rec:
  Maybe.default(&2, M.Rec, M.Meta.line(l), M.Meta.empty())

# Decoding.
law meta.pct:
  {M.Meta.pct("a%20b%2Fc") == "a b/c" : String}

law meta.pct_short:
  {M.Meta.pct("50%") == "50%" : String}

law meta.hex:
  {M.Meta.hex("0100ff") == [1, 0, 255] : List<&2, U32>}

law meta.oct:
  {M.Meta.oct("4755") == Some{2541} : Maybe<&2, U32>}

law meta.fnv_a:
  {M.Meta.fnv("a") == U.U64{2942557260, 2248273036} : U.U64}

law meta.fnv_empty:
  {M.Meta.fnv("") == U.U64{3421674724, 2216829733} : U.U64}

# A file is version 1, else no records.
law meta.version:
  {M.Meta.parse("bend-meta 2\nname=a") == None{} : Maybe<&2, List<&2, M.Rec>>}

law meta.no_name:
  {M.Meta.line("type=f mode=644") == None{} : Maybe<&2, M.Rec>}

law meta.host_default:
  {M.Rec.host(rec("name=Makefile type=f")) == "Makefile" : String}

law meta.host_given:
  {M.Rec.host(rec("name=makefile host=makefile%7E1")) == "makefile~1" : String}

law meta.unknown_key:
  {M.Rec.has(rec("name=a future=x mode=644")) == 2 : U32}

# Attributes. The record's type and mode, owner, link count and
# times win; a device or FIFO is 0 bytes; the inode is the record's, else
# the path's FNV-1a hash.
law meta.attr_setuid:
  {M.Meta.attr(rec("name=Makefile type=f mode=4755 uid=0 gid=0 mtime=1700000000.5"), a(), "Makefile")
    == V.FsGotMeta{V.FsAttr{35309, 0, 0, 1, U.U64{0, 11}, M.Meta.fnv("Makefile"), U.U64{0, 8}, U.U64{0, 5}, U.U64{0, 1700000000}, U.U64{0, 7}}, 0, 0, 5} : V.FsResult}

law meta.attr_whiteout:
  {M.Meta.attr(rec("name=gone type=c rdev=0,0 mode=0"), a(), "gone")
    == V.FsGotMeta{V.FsAttr{8192, 502, 20, 1, U.U64{0, 0}, M.Meta.fnv("gone"), U.U64{0, 0}, U.U64{0, 5}, U.U64{0, 6}, U.U64{0, 7}}, 0, 0, 0} : V.FsResult}

law meta.attr_device:
  {M.Meta.attr(rec("name=null type=c rdev=1,3 mode=666"), a(), "dev/null")
    == V.FsGotMeta{V.FsAttr{8630, 502, 20, 1, U.U64{0, 0}, M.Meta.fnv("dev/null"), U.U64{0, 0}, U.U64{0, 5}, U.U64{0, 6}, U.U64{0, 7}}, 1, 3, 0} : V.FsResult}

law meta.attr_hardlink:
  {M.Meta.attr(rec("name=b ino=42 nlink=2"), a(), "b")
    == V.FsGotMeta{V.FsAttr{33188, 502, 20, 2, U.U64{0, 11}, U.U64{0, 42}, U.U64{0, 8}, U.U64{0, 5}, U.U64{0, 6}, U.U64{0, 7}}, 0, 0, 0} : V.FsResult}

# Extended attributes, byte-exact from the record; "" lists
# their names, each followed by a 0 byte.
law meta.xattr_value:
  {M.Meta.xattr(rec("name=sub type=d xattr.trusted.overlay.opaque=79"), "trusted.overlay.opaque") == Some{[121]} : Maybe<&2, List<&2, U32>>}

law meta.xattr_missing:
  {M.Meta.xattr(rec("name=sub type=d"), "trusted.overlay.opaque") == None{} : Maybe<&2, List<&2, U32>>}

law meta.xattr_names:
  {M.Meta.xattr(rec("name=s xattr.a=01 xattr.bc=02"), "") == Some{[97, 0, 98, 99, 0]} : Maybe<&2, List<&2, U32>>}

# A directory's table (what Hvf.meta_load takes): no .bend-meta
# (or another version) is plain; a record whose name or host name could
# leave the directory is left out.
law meta.table_plain:
  {M.Meta.table("") == [1, 0] : List<&2, U32>}

law meta.table_one:
  {M.Meta.table("bend-meta 1\nname=a host=b") == [0, 1, 1, 97, 1, 98, 13, 110, 97, 109, 101, 61, 97, 32, 104, 111, 115, 116, 61, 98] : List<&2, U32>}

law meta.table_escape:
  {M.Meta.table("bend-meta 1\nname=x host=..\nname=y host=a%2Fb\nname=.. host=z") == [0, 0] : List<&2, U32>}

# A directory's listing is its records, by their names.
law meta.entries:
  {M.Meta.entries("d", [1, 0, 1, 1, 97, 14, 110, 97, 109, 101, 61, 97, 32, 116, 121, 112, 101, 61, 100], 0, 100)
    == Some{[V.FsEntry{"a", M.Meta.fnv("d/a"), 4}]} : Maybe<&2, List<&2, V.FsEntry>>}

law meta.entries_page:
  {M.Meta.entries("", [1, 0, 3, 1, 98, 6, 110, 97, 109, 101, 61, 98], 1, 1)
    == Some{[V.FsEntry{"b", M.Meta.fnv("b"), 0}]} : Maybe<&2, List<&2, V.FsEntry>>}

law meta.entries_past_end:
  {M.Meta.entries("", [1, 0, 1], 5, 10) == Some{[]} : Maybe<&2, List<&2, V.FsEntry>>}

law meta.entries_plain:
  {M.Meta.entries("d", [1, 1, 0], 0, 100) == None{} : Maybe<&2, List<&2, V.FsEntry>>}

# A device's number as Linux packs it for 9p (new_encode_dev),
# and the path of a fid Txattrwalk binds (its name and file kept apart).
law meta.p9_rdev:
  {F.P9.rdev(1, 3) == U.U64{0, 259} : U.U64}

law meta.p9_rdev_big_minor:
  {F.P9.rdev(8, 300) == U.U64{0, 1050668} : U.U64}

law meta.p9_xpath:
  {F.P9.xsplit(F.P9.xpath("trusted.overlay.opaque", "a/sub")) == F.P9XPath{"trusted.overlay.opaque", "a/sub"} : F.P9XPath}

law meta.p9_xpath_is:
  {F.P9.is_xpath(F.P9.xpath("x", "a")) == True{} : Bool}

law meta.p9_xpath_plain:
  {F.P9.is_xpath("a/b") == False{} : Bool}
