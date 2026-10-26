import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/fs/p9wire.bend as W
import ./t.bend as T

# Tests of the 9P2000.L codec. Message bytes and expected R-message bytes come
# from an independent encoder (Python struct) of the layouts in
# src/fs/p9wire.bend.

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def w(x: U32) -> U.U64:
  U.U64{0, x}

def u64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      [h, l]

# A string as its length then its bytes.
def str(+s: +List<U32>) -> +List<U32>:
  U32.from_nat(List.length(&2, U32, s)) <> s

def strs(ss: +List<+List<U32>>) -> +List<U32>:
  match ss:
    case Nil{}:
      []
    case Con{s, rest}:
      cat(str(s), strs(rest))

# A request flattened to its type number then its fields (a U64 as hi, lo;
# a string as length, bytes; Twalk names as their count then each string).
def req(r: W.P9Req) -> +List<U32>:
  match r:
    case W.Tstatfs{fid}:
      [8, fid]
    case W.Tlopen{fid, flags}:
      [12, fid, flags]
    case W.Tlcreate{fid, name, flags, mode, gid}:
      cat([14, fid], cat(str(name), [flags, mode, gid]))
    case W.Tsymlink{fid, name, target, gid}:
      cat([16, fid], cat(str(name), cat(str(target), [gid])))
    case W.Treadlink{fid}:
      [22, fid]
    case W.Tgetattr{fid, mask}:
      cat([24, fid], u64(mask))
    case W.Tsetattr{fid, valid, mode, uid, gid, size}:
      cat([26, fid, valid, mode, uid, gid], u64(size))
    case W.Txattrwalk{fid, newfid, name}:
      cat([30, fid, newfid], str(name))
    case W.Treaddir{fid, offset, count}:
      cat([40, fid], cat(u64(offset), [count]))
    case W.Tfsync{fid}:
      [50, fid]
    case W.Tmkdir{dfid, name, mode, gid}:
      cat([72, dfid], cat(str(name), [mode, gid]))
    case W.Trenameat{olddir, oldname, newdir, newname}:
      cat([74, olddir], cat(str(oldname), cat([newdir], str(newname))))
    case W.Tunlinkat{dir, name, flags}:
      cat([76, dir], cat(str(name), [flags]))
    case W.Tversion{msize, version}:
      cat([100, msize], str(version))
    case W.Tattach{fid, afid, uname, aname, n_uname}:
      cat([104, fid, afid], cat(str(uname), cat(str(aname), [n_uname])))
    case W.Tflush{oldtag}:
      [108, oldtag]
    case W.Twalk{fid, newfid, +names}:
      cat([110, fid, newfid, U32.from_nat(List.length(&2, +List<U32>, names))], strs(names))
    case W.Tread{fid, offset, count}:
      cat([116, fid], cat(u64(offset), [count]))
    case W.Twrite{fid, offset, data}:
      cat([118, fid], cat(u64(offset), str(data)))
    case W.Tclunk{fid}:
      [120, fid]
    case W.Tunknown{kind}:
      [kind]

# A parse result flattened: the tag then the request; None is [999].
def flat(m: Maybe<&2, W.P9Msg>) -> +List<U32>:
  match m:
    case None{}:
      [999]
    case Some{W.P9Msg{tag, r}}:
      tag <> req(r)

def none(m: Maybe<&2, W.P9Msg>) -> Bool:
  Bool.not(Maybe.is_some(&2, W.P9Msg, m))

# The bytes of a Twrite's data (or [999]).
def wdata(m: Maybe<&2, W.P9Msg>) -> +List<U32>:
  match m:
    case Some{W.P9Msg{tag, W.Twrite{fid, offset, data}}}:
      data
    case _:
      [999]

# A message of type k from its fields: the header is computed.
def msg(k: U32, tag: U32, +body: +List<U32>) -> +List<U32>:
  cat(B.Bytes.le32((7 + U32.from_nat(List.length(&2, U32, body)) : U32)), cat([k], cat(B.Bytes.le16(tag), body)))

# The message less its last byte, with the size field patched to agree: the
# fields then run past the message.
def trunc(+bs: +List<U32>) -> +List<U32>:
  +n = Nat.sub(List.length(&2, U32, bs), 1n)
  cat(B.Bytes.le32(U32.from_nat(n)), List.take(&2, U32, List.drop(&2, U32, bs, 4n), Nat.sub(n, 4n)))

# The message less its last byte, size field unchanged.
def short(+bs: +List<U32>) -> +List<U32>:
  List.take(&2, U32, bs, Nat.sub(List.length(&2, U32, bs), 1n))

def m_statfs() -> +List<U32>:
  [11, 0, 0, 0, 8, 1, 0, 3, 0, 0, 0]

def m_lopen() -> +List<U32>:
  [15, 0, 0, 0, 12, 2, 0, 4, 0, 0, 0, 0, 128, 0, 0]

def m_lcreate() -> +List<U32>:
  [32, 0, 0, 0, 14, 3, 0, 5, 0, 0, 0, 7, 0, 110, 101, 119, 46, 116, 120, 116, 66, 2, 0, 0, 164, 1, 0, 0, 232, 3, 0, 0]

def m_symlink() -> +List<U32>:
  [31, 0, 0, 0, 16, 4, 0, 6, 0, 0, 0, 2, 0, 108, 110, 10, 0, 47, 101, 116, 99, 47, 104, 111, 115, 116, 115, 20, 0, 0, 0]

def m_readlink() -> +List<U32>:
  [11, 0, 0, 0, 22, 5, 0, 7, 0, 0, 0]

def m_getattr() -> +List<U32>:
  [19, 0, 0, 0, 24, 6, 0, 8, 0, 0, 0, 255, 63, 0, 0, 0, 0, 0, 0]

def m_setattr() -> +List<U32>:
  [67, 0, 0, 0, 26, 7, 0, 9, 0, 0, 0, 127, 0, 0, 0, 164, 129, 0, 0, 245, 1, 0, 0, 20, 0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]

def m_xattrwalk() -> +List<U32>:
  [36, 0, 0, 0, 30, 8, 0, 10, 0, 0, 0, 11, 0, 0, 0, 19, 0, 115, 101, 99, 117, 114, 105, 116, 121, 46, 99, 97, 112, 97, 98, 105, 108, 105, 116, 121]

def m_readdir() -> +List<U32>:
  [23, 0, 0, 0, 40, 9, 0, 12, 0, 0, 0, 7, 0, 0, 0, 2, 0, 0, 0, 232, 31, 0, 0]

def m_fsync() -> +List<U32>:
  [15, 0, 0, 0, 50, 10, 0, 13, 0, 0, 0, 1, 0, 0, 0]

def m_mkdir() -> +List<U32>:
  [22, 0, 0, 0, 72, 11, 0, 14, 0, 0, 0, 1, 0, 100, 237, 1, 0, 0, 20, 0, 0, 0]

def m_renameat() -> +List<U32>:
  [22, 0, 0, 0, 74, 12, 0, 15, 0, 0, 0, 1, 0, 97, 16, 0, 0, 0, 2, 0, 98, 99]

def m_unlinkat() -> +List<U32>:
  [18, 0, 0, 0, 76, 13, 0, 17, 0, 0, 0, 1, 0, 120, 0, 2, 0, 0]

def m_version() -> +List<U32>:
  [21, 0, 0, 0, 100, 255, 255, 0, 208, 7, 0, 8, 0, 57, 80, 50, 48, 48, 48, 46, 76]

def m_attach() -> +List<U32>:
  [27, 0, 0, 0, 104, 14, 0, 0, 0, 0, 0, 255, 255, 255, 255, 4, 0, 114, 111, 111, 116, 0, 0, 0, 0, 0, 0]

def m_flush() -> +List<U32>:
  [9, 0, 0, 0, 108, 15, 0, 14, 0]

def m_walk0() -> +List<U32>:
  [17, 0, 0, 0, 110, 16, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0]

def m_walk2() -> +List<U32>:
  [27, 0, 0, 0, 110, 17, 0, 1, 0, 0, 0, 3, 0, 0, 0, 2, 0, 3, 0, 117, 115, 114, 3, 0, 98, 105, 110]

def m_read() -> +List<U32>:
  [23, 0, 0, 0, 116, 18, 0, 19, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 16, 0, 0]

def m_write() -> +List<U32>:
  [26, 0, 0, 0, 118, 19, 0, 20, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 104, 105, 10]

def m_clunk() -> +List<U32>:
  [11, 0, 0, 0, 120, 20, 0, 21, 0, 0, 0]

def m_unknown() -> +List<U32>:
  [19, 0, 0, 0, 6, 21, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]

def m_walk16() -> +List<U32>:
  [65, 0, 0, 0, 110, 22, 0, 1, 0, 0, 0, 4, 0, 0, 0, 16, 0, 1, 0, 97, 1, 0, 98, 1, 0, 99, 1, 0, 100, 1, 0, 101, 1, 0, 102, 1, 0, 103, 1, 0, 104, 1, 0, 105, 1, 0, 106, 1, 0, 107, 1, 0, 108, 1, 0, 109, 1, 0, 110, 1, 0, 111, 1, 0, 112]

def m_walk17() -> +List<U32>:
  [68, 0, 0, 0, 110, 23, 0, 1, 0, 0, 0, 4, 0, 0, 0, 17, 0, 1, 0, 97, 1, 0, 98, 1, 0, 99, 1, 0, 100, 1, 0, 101, 1, 0, 102, 1, 0, 103, 1, 0, 104, 1, 0, 105, 1, 0, 106, 1, 0, 107, 1, 0, 108, 1, 0, 109, 1, 0, 110, 1, 0, 111, 1, 0, 112, 1, 0, 113]

# A Twrite of 16 KiB (the JS lane runs out of stack on lists much longer).
def big() -> +List<U32>:
  msg(118, 4, cat([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0], B.Bytes.zeros(16384n)))

# Entries i, i+1 .. n-1 of a long directory: qid path i, next i+1, a file,
# named "a" then the character 48+i.
def ents(n: Nat, +i: U32) -> +List<W.P9Dirent>:
  match n:
    case 0n:
      []
    case 1n+p:
      W.P9Dirent{W.Qid{0, 0, w(i)}, w((i + 1 : U32)), 8, [97, (48 + i : U32)]} <> ents(p, (i + 1 : U32))

def qids(n: Nat, +i: U32) -> +List<W.Qid>:
  match n:
    case 0n:
      []
    case 1n+p:
      W.Qid{128, 0, w(i)} <> qids(p, (i + 1 : U32))

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("parse statfs", show(flat(W.P9.parse(m_statfs()))), show([1, 8, 3]))
    T.eq_str("parse lopen", show(flat(W.P9.parse(m_lopen()))), show([2, 12, 4, 32768]))
    T.eq_str("parse lcreate", show(flat(W.P9.parse(m_lcreate()))), show([3, 14, 5, 7, 110, 101, 119, 46, 116, 120, 116, 578, 420, 1000]))
    T.eq_str("parse symlink", show(flat(W.P9.parse(m_symlink()))), show([4, 16, 6, 2, 108, 110, 10, 47, 101, 116, 99, 47, 104, 111, 115, 116, 115, 20]))
    T.eq_str("parse readlink", show(flat(W.P9.parse(m_readlink()))), show([5, 22, 7]))
    T.eq_str("parse getattr", show(flat(W.P9.parse(m_getattr()))), show([6, 24, 8, 0, 16383]))
    T.eq_str("parse setattr", show(flat(W.P9.parse(m_setattr()))), show([7, 26, 9, 127, 33188, 501, 20, 1, 5]))
    T.eq_str("parse xattrwalk", show(flat(W.P9.parse(m_xattrwalk()))), show([8, 30, 10, 11, 19, 115, 101, 99, 117, 114, 105, 116, 121, 46, 99, 97, 112, 97, 98, 105, 108, 105, 116, 121]))
    T.eq_str("parse readdir", show(flat(W.P9.parse(m_readdir()))), show([9, 40, 12, 2, 7, 8168]))
    T.eq_str("parse fsync", show(flat(W.P9.parse(m_fsync()))), show([10, 50, 13]))
    T.eq_str("parse mkdir", show(flat(W.P9.parse(m_mkdir()))), show([11, 72, 14, 1, 100, 493, 20]))
    T.eq_str("parse renameat", show(flat(W.P9.parse(m_renameat()))), show([12, 74, 15, 1, 97, 16, 2, 98, 99]))
    T.eq_str("parse unlinkat", show(flat(W.P9.parse(m_unlinkat()))), show([13, 76, 17, 1, 120, 512]))
    T.eq_str("parse version", show(flat(W.P9.parse(m_version()))), show([65535, 100, 512000, 8, 57, 80, 50, 48, 48, 48, 46, 76]))
    T.eq_str("parse attach", show(flat(W.P9.parse(m_attach()))), show([14, 104, 0, 4294967295, 4, 114, 111, 111, 116, 0, 0]))
    T.eq_str("parse flush", show(flat(W.P9.parse(m_flush()))), show([15, 108, 14]))
    T.eq_str("parse walk0", show(flat(W.P9.parse(m_walk0()))), show([16, 110, 1, 2, 0]))
    T.eq_str("parse walk2", show(flat(W.P9.parse(m_walk2()))), show([17, 110, 1, 3, 2, 3, 117, 115, 114, 3, 98, 105, 110]))
    T.eq_str("parse read", show(flat(W.P9.parse(m_read()))), show([18, 116, 19, 1, 0, 4096]))
    T.eq_str("parse write", show(flat(W.P9.parse(m_write()))), show([19, 118, 20, 0, 10, 3, 104, 105, 10]))
    T.eq_str("parse clunk", show(flat(W.P9.parse(m_clunk()))), show([20, 120, 21]))
    T.eq_str("parse unknown", show(flat(W.P9.parse(m_unknown()))), show([21, 6]))
    T.eq_str("parse walk16", show(flat(W.P9.parse(m_walk16()))), show([22, 110, 1, 4, 16, 1, 97, 1, 98, 1, 99, 1, 100, 1, 101, 1, 102, 1, 103, 1, 104, 1, 105, 1, 106, 1, 107, 1, 108, 1, 109, 1, 110, 1, 111, 1, 112]))
    T.ok("truncated statfs", none(W.P9.parse(trunc(m_statfs()))))
    T.ok("truncated lopen", none(W.P9.parse(trunc(m_lopen()))))
    T.ok("truncated lcreate", none(W.P9.parse(trunc(m_lcreate()))))
    T.ok("truncated symlink", none(W.P9.parse(trunc(m_symlink()))))
    T.ok("truncated readlink", none(W.P9.parse(trunc(m_readlink()))))
    T.ok("truncated getattr", none(W.P9.parse(trunc(m_getattr()))))
    T.ok("truncated setattr", none(W.P9.parse(trunc(m_setattr()))))
    T.ok("truncated xattrwalk", none(W.P9.parse(trunc(m_xattrwalk()))))
    T.ok("truncated readdir", none(W.P9.parse(trunc(m_readdir()))))
    T.ok("truncated fsync", none(W.P9.parse(trunc(m_fsync()))))
    T.ok("truncated mkdir", none(W.P9.parse(trunc(m_mkdir()))))
    T.ok("truncated renameat", none(W.P9.parse(trunc(m_renameat()))))
    T.ok("truncated unlinkat", none(W.P9.parse(trunc(m_unlinkat()))))
    T.ok("truncated version", none(W.P9.parse(trunc(m_version()))))
    T.ok("truncated attach", none(W.P9.parse(trunc(m_attach()))))
    T.ok("truncated flush", none(W.P9.parse(trunc(m_flush()))))
    T.ok("truncated walk2", none(W.P9.parse(trunc(m_walk2()))))
    T.ok("truncated read", none(W.P9.parse(trunc(m_read()))))
    T.ok("truncated write", none(W.P9.parse(trunc(m_write()))))
    T.ok("truncated clunk", none(W.P9.parse(trunc(m_clunk()))))
    T.ok("truncated walk16", none(W.P9.parse(trunc(m_walk16()))))
    T.ok("short statfs", none(W.P9.parse(short(m_statfs()))))
    T.ok("short lopen", none(W.P9.parse(short(m_lopen()))))
    T.ok("short lcreate", none(W.P9.parse(short(m_lcreate()))))
    T.ok("short symlink", none(W.P9.parse(short(m_symlink()))))
    T.ok("short readlink", none(W.P9.parse(short(m_readlink()))))
    T.ok("short getattr", none(W.P9.parse(short(m_getattr()))))
    T.ok("short setattr", none(W.P9.parse(short(m_setattr()))))
    T.ok("short xattrwalk", none(W.P9.parse(short(m_xattrwalk()))))
    T.ok("short readdir", none(W.P9.parse(short(m_readdir()))))
    T.ok("short fsync", none(W.P9.parse(short(m_fsync()))))
    T.ok("short mkdir", none(W.P9.parse(short(m_mkdir()))))
    T.ok("short renameat", none(W.P9.parse(short(m_renameat()))))
    T.ok("short unlinkat", none(W.P9.parse(short(m_unlinkat()))))
    T.ok("short version", none(W.P9.parse(short(m_version()))))
    T.ok("short attach", none(W.P9.parse(short(m_attach()))))
    T.ok("short flush", none(W.P9.parse(short(m_flush()))))
    T.ok("short walk0", none(W.P9.parse(short(m_walk0()))))
    T.ok("short walk2", none(W.P9.parse(short(m_walk2()))))
    T.ok("short read", none(W.P9.parse(short(m_read()))))
    T.ok("short write", none(W.P9.parse(short(m_write()))))
    T.ok("short clunk", none(W.P9.parse(short(m_clunk()))))
    T.ok("short unknown", none(W.P9.parse(short(m_unknown()))))
    T.ok("short walk16", none(W.P9.parse(short(m_walk16()))))
    T.ok("walk 17 names", none(W.P9.parse(m_walk17())))
    T.ok("parse empty", none(W.P9.parse([])))
    T.ok("parse 6 bytes", none(W.P9.parse([6, 0, 0, 0, 120, 1])))
    T.ok("size below header", none(W.P9.parse([6, 0, 0, 0, 120, 1, 0])))
    T.ok("size zero", none(W.P9.parse([0, 0, 0, 0, 120, 1, 0, 1, 0, 0, 0])))
    T.ok("size past bytes", none(W.P9.parse([12, 0, 0, 0, 120, 1, 0, 1, 0, 0, 0])))
    T.ok("size before bytes end", none(W.P9.parse(cat(m_clunk(), [0]))))
    T.ok("size 4 GiB", none(W.P9.parse([255, 255, 255, 255, 120, 1, 0, 1, 0, 0, 0])))
    T.ok("string length past end", none(W.P9.parse(msg(100, 1, [0, 32, 0, 0, 255, 255, 57, 80]))))
    T.ok("twrite count past end", none(W.P9.parse(msg(118, 1, cat(B.Bytes.zeros(12n), [255, 255, 255, 255, 1, 2])))))
    T.ok("twalk nwname 65535", none(W.P9.parse(msg(110, 1, cat(B.Bytes.zeros(8n), [255, 255])))))
    T.eq_str("trailing bytes ignored", show(flat(W.P9.parse(msg(120, 2, [7, 0, 0, 0, 9, 9])))), show([2, 120, 7]))
    T.eq_str("tunknown without fields", show(flat(W.P9.parse(msg(255, 3, [])))), show([3, 255]))
    T.eq_u32("twrite 16 KiB", U32.from_nat(List.length(&2, U32, wdata(W.P9.parse(big())))), 16384)
    T.ok("twrite 16 KiB short", none(W.P9.parse(short(big()))))
    T.eq_str("build statfs", show(W.P9.build(1, W.Rstatfs{4096, w(100), w(50), w(40), w(1000), w(900)})), show([67, 0, 0, 0, 9, 1, 0, 151, 25, 2, 1, 0, 16, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 50, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 232, 3, 0, 0, 0, 0, 0, 0, 132, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0]))
    T.eq_str("build lopen", show(W.P9.build(2, W.Rlopen{W.Qid{0, 1, w(77)}, 8192})), show([24, 0, 0, 0, 13, 2, 0, 0, 1, 0, 0, 0, 77, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0]))
    T.eq_str("build lcreate", show(W.P9.build(3, W.Rlcreate{W.Qid{0, 0, w(78)}, 0})), show([24, 0, 0, 0, 15, 3, 0, 0, 0, 0, 0, 0, 78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    T.eq_str("build symlink", show(W.P9.build(4, W.Rsymlink{W.Qid{2, 0, w(79)}})), show([20, 0, 0, 0, 17, 4, 0, 2, 0, 0, 0, 0, 79, 0, 0, 0, 0, 0, 0, 0]))
    T.eq_str("build readlink", show(W.P9.build(5, W.Rreadlink{[47, 116, 109, 112]})), show([13, 0, 0, 0, 23, 5, 0, 4, 0, 47, 116, 109, 112]))
    T.eq_str("build setattr", show(W.P9.build(6, W.Rsetattr{})), show([7, 0, 0, 0, 27, 6, 0]))
    T.eq_str("build fsync", show(W.P9.build(7, W.Rfsync{})), show([7, 0, 0, 0, 51, 7, 0]))
    T.eq_str("build mkdir", show(W.P9.build(8, W.Rmkdir{W.Qid{128, 0, w(80)}})), show([20, 0, 0, 0, 73, 8, 0, 128, 0, 0, 0, 0, 80, 0, 0, 0, 0, 0, 0, 0]))
    T.eq_str("build renameat", show(W.P9.build(9, W.Rrenameat{})), show([7, 0, 0, 0, 75, 9, 0]))
    T.eq_str("build unlinkat", show(W.P9.build(10, W.Runlinkat{})), show([7, 0, 0, 0, 77, 10, 0]))
    T.eq_str("build attach", show(W.P9.build(11, W.Rattach{W.Qid{128, 0, w(1)}})), show([20, 0, 0, 0, 105, 11, 0, 128, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]))
    T.eq_str("build flush", show(W.P9.build(12, W.Rflush{})), show([7, 0, 0, 0, 109, 12, 0]))
    T.eq_str("build write", show(W.P9.build(13, W.Rwrite{4096})), show([11, 0, 0, 0, 119, 13, 0, 0, 16, 0, 0]))
    T.eq_str("build clunk", show(W.P9.build(14, W.Rclunk{})), show([7, 0, 0, 0, 121, 14, 0]))
    T.eq_str("build walk 0", show(W.P9.build(15, W.Rwalk{[]})), show([9, 0, 0, 0, 111, 15, 0, 0, 0]))
    T.eq_str("build read 0", show(W.P9.build(16, W.Rread{[]})), show([11, 0, 0, 0, 117, 16, 0, 0, 0, 0, 0]))
    T.eq_str("build readdir 0", show(W.P9.build(17, W.Rreaddir{[]})), show([11, 0, 0, 0, 41, 17, 0, 0, 0, 0, 0]))
    T.eq_str("build readdir 2", show(W.P9.build(18, W.Rreaddir{[W.P9Dirent{W.Qid{128, 0, w(5)}, w(1), 4, [46]}, W.P9Dirent{W.Qid{0, 3, U.U64{1, 2}}, w(2), 8, [97, 98]}]})), show([62, 0, 0, 0, 41, 18, 0, 51, 0, 0, 0, 128, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 46, 0, 3, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 98]))
    T.eq_str("build getattr", show(W.P9.build(19, W.Rgetattr{W.P9Stat{W.Qid{128, 7, U.U64{2, 1}}, 16877, 0, 0, w(2), w(4096), w(8), w(1), w(2), w(3)}})), show([160, 0, 0, 0, 25, 19, 0, 255, 7, 0, 0, 0, 0, 0, 0, 128, 7, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 237, 65, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    T.eq_str("build version unknown", show(W.P9.build(65535, W.Rversion{4096, [117, 110, 107, 110, 111, 119, 110]})), show([20, 0, 0, 0, 101, 255, 255, 0, 16, 0, 0, 7, 0, 117, 110, 107, 110, 111, 119, 110]))
    T.eq_str("build read 3", show(W.P9.build(20, W.Rread{[1, 2, 3]})), show([14, 0, 0, 0, 117, 20, 0, 3, 0, 0, 0, 1, 2, 3]))
    T.eq_str("build readdir 40", show(W.P9.build(30, W.Rreaddir{ents(40n, 0)})), show([27, 4, 0, 0, 41, 30, 0, 16, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 48, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 49, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 50, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 51, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 52, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 53, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 54, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 55, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 56, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 57, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 58, 0, 0, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 59, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 60, 0, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 61, 0, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 62, 0, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 63, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 64, 0, 0, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0, 18, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 65, 0, 0, 0, 0, 0, 18, 0, 0, 0, 0, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 66, 0, 0, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 67, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 21, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 68, 0, 0, 0, 0, 0, 21, 0, 0, 0, 0, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 69, 0, 0, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 70, 0, 0, 0, 0, 0, 23, 0, 0, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 71, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 0, 25, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 72, 0, 0, 0, 0, 0, 25, 0, 0, 0, 0, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 73, 0, 0, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0, 27, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 74, 0, 0, 0, 0, 0, 27, 0, 0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 75, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 76, 0, 0, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 77, 0, 0, 0, 0, 0, 30, 0, 0, 0, 0, 0, 0, 0, 31, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 78, 0, 0, 0, 0, 0, 31, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 79, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 80, 0, 0, 0, 0, 0, 33, 0, 0, 0, 0, 0, 0, 0, 34, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 81, 0, 0, 0, 0, 0, 34, 0, 0, 0, 0, 0, 0, 0, 35, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 82, 0, 0, 0, 0, 0, 35, 0, 0, 0, 0, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 83, 0, 0, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 84, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0, 0, 38, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 85, 0, 0, 0, 0, 0, 38, 0, 0, 0, 0, 0, 0, 0, 39, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 86, 0, 0, 0, 0, 0, 39, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 97, 87]))
    T.eq_str("build walk 16", show(W.P9.build(31, W.Rwalk{qids(16n, 0)})), show([217, 0, 0, 0, 111, 31, 0, 16, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0]))
