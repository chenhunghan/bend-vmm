import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The 9P2000.L wire format (the protocol Linux's v9fs speaks over virtio).
# A message is size[4] type[1] tag[2] then its fields, all little-endian;
# size counts the whole message. A string s is len[2] then its bytes; a qid
# is type[1] version[4] path[8]. Message types and fields (decimal):
#   Tstatfs 8 fid[4]              Rstatfs 9 type[4] bsize[4] blocks[8] bfree[8]
#                                    bavail[8] files[8] ffree[8] fsid[8] namelen[4]
#   Tlopen 12 fid[4] flags[4]     Rlopen 13 qid iounit[4]
#   Tlcreate 14 fid[4] name[s] flags[4] mode[4] gid[4]   Rlcreate 15 qid iounit[4]
#   Tsymlink 16 fid[4] name[s] symtgt[s] gid[4]          Rsymlink 17 qid
#   Treadlink 22 fid[4]           Rreadlink 23 target[s]
#   Tgetattr 24 fid[4] request_mask[8]
#                                 Rgetattr 25 valid[8] qid mode[4] uid[4] gid[4]
#                                    nlink[8] rdev[8] size[8] blksize[8] blocks[8]
#                                    atime_sec[8] atime_nsec[8] mtime_sec[8]
#                                    mtime_nsec[8] ctime_sec[8] ctime_nsec[8]
#                                    btime_sec[8] btime_nsec[8] gen[8] data_version[8]
#   Tsetattr 26 fid[4] valid[4] mode[4] uid[4] gid[4] size[8] atime_sec[8]
#                 atime_nsec[8] mtime_sec[8] mtime_nsec[8]   Rsetattr 27
#   Txattrwalk 30 fid[4] newfid[4] name[s]   (answered with Rlerror)
#   Treaddir 40 fid[4] offset[8] count[4]
#                                 Rreaddir 41 count[4] then count bytes of
#                                    entries: qid offset[8] type[1] name[s]
#   Tfsync 50 fid[4] datasync[4]  Rfsync 51
#   Tmkdir 72 dfid[4] name[s] mode[4] gid[4]             Rmkdir 73 qid
#   Trenameat 74 olddirfid[4] oldname[s] newdirfid[4] newname[s]  Rrenameat 75
#   Tunlinkat 76 dirfd[4] name[s] flags[4]               Runlinkat 77
#   Tversion 100 msize[4] version[s]                     Rversion 101 msize[4] version[s]
#   Tattach 104 fid[4] afid[4] uname[s] aname[s] n_uname[4]   Rattach 105 qid
#   Tflush 108 oldtag[2]          Rflush 109
#   Twalk 110 fid[4] newfid[4] nwname[2] wname[s]*nwname
#                                 Rwalk 111 nwqid[2] qid*nwqid
#   Tread 116 fid[4] offset[8] count[4]                  Rread 117 count[4] data
#   Twrite 118 fid[4] offset[8] count[4] data            Rwrite 119 count[4]
#   Tclunk 120 fid[4]             Rclunk 121
#   Rlerror 7 ecode[4] (a Linux errno)
# Strings are byte strings here (+List<U32>), not decoded text.

type Qid is Data:
  Qid{kind: U32, version: U32, path: U.U64}

type P9Req is Data:
  Tstatfs{fid: U32}
  Tlopen{fid: U32, flags: U32}
  Tlcreate{fid: U32, name: +List<U32>, flags: U32, mode: U32, gid: U32}
  Tsymlink{fid: U32, name: +List<U32>, target: +List<U32>, gid: U32}
  Treadlink{fid: U32}
  Tgetattr{fid: U32, mask: U.U64}
  Tsetattr{fid: U32, valid: U32, mode: U32, uid: U32, gid: U32, size: U.U64}
  Txattrwalk{fid: U32, newfid: U32, name: +List<U32>}
  Treaddir{fid: U32, offset: U.U64, count: U32}
  Tfsync{fid: U32}
  Tmkdir{dfid: U32, name: +List<U32>, mode: U32, gid: U32}
  Trenameat{olddir: U32, oldname: +List<U32>, newdir: U32, newname: +List<U32>}
  Tunlinkat{dir: U32, name: +List<U32>, flags: U32}
  Tversion{msize: U32, version: +List<U32>}
  Tattach{fid: U32, afid: U32, uname: +List<U32>, aname: +List<U32>, n_uname: U32}
  Tflush{oldtag: U32}
  Twalk{fid: U32, newfid: U32, names: +List<+List<U32>>}
  Tread{fid: U32, offset: U.U64, count: U32}
  Twrite{fid: U32, offset: U.U64, data: +List<U32>}
  Tclunk{fid: U32}
  # A message type this server does not know.
  Tunknown{kind: U32}

# Rgetattr carries the full stat; the fields not listed (rdev, the nsec
# parts, btime, gen, data_version) are written as zero, valid as 2047
# (P9_GETATTR_BASIC), blksize as 4096.
type P9Stat is Data:
  P9Stat{qid: Qid, mode: U32, uid: U32, gid: U32, nlink: U.U64, size: U.U64, blocks: U.U64, atime: U.U64, mtime: U.U64, ctime: U.U64}

# A directory entry in an Rreaddir: qid, the offset of the next entry, the
# type (DT_* value), the name.
type P9Dirent is Data:
  P9Dirent{qid: Qid, next: U.U64, kind: U32, name: +List<U32>}

type P9Resp is Data:
  Rlerror{ecode: U32}
  Rstatfs{bsize: U32, blocks: U.U64, bfree: U.U64, bavail: U.U64, files: U.U64, ffree: U.U64}
  Rlopen{qid: Qid, iounit: U32}
  Rlcreate{qid: Qid, iounit: U32}
  Rsymlink{qid: Qid}
  Rreadlink{target: +List<U32>}
  Rgetattr{stat: P9Stat}
  Rsetattr{}
  Rreaddir{entries: +List<P9Dirent>}
  Rfsync{}
  Rmkdir{qid: Qid}
  Rrenameat{}
  Runlinkat{}
  Rversion{msize: U32, version: +List<U32>}
  Rattach{qid: Qid}
  Rflush{}
  Rwalk{qids: +List<Qid>}
  Rread{data: +List<U32>}
  Rwrite{count: U32}
  Rclunk{}

# A request: its tag and the decoded message. None when the bytes are not a
# whole message (short, size field disagreeing, or fields running past it).
# Rstatfs writes type 0x01021997 (V9FS_MAGIC), fsid 0 and namelen 255.
type P9Msg is Data:
  P9Msg{tag: U32, req: P9Req}

# Decoding. A message is checked whole first (size[4] equal to the byte count,
# at least the 7 header bytes), then its fields are read from the body (the
# bytes after the header). Reads past the end read as zero or come short, so
# every field reader is total; each decoder also reports where its fields end,
# and the message is refused when that is past the body.

# The little-endian field of n bytes (n <= 4) at off.
def P9.le(n: Nat, b: +List<U32>, off: Nat) -> U32:
  B.Bytes.read_le(n, List.drop(&2, U32, b, off))

def P9.u16(b: +List<U32>, off: Nat) -> U32:
  P9.le(2n, b, off)

def P9.u32(b: +List<U32>, off: Nat) -> U32:
  P9.le(4n, b, off)

def P9.u64(b: +List<U32>, off: Nat) -> U.U64:
  B.Bytes.read_le64(List.drop(&2, U32, b, off))

# The length of the string at off.
def P9.slen(b: +List<U32>, off: Nat) -> Nat:
  U32.to_nat(P9.u16(b, off))

# The bytes of the string at off.
def P9.str(+b: +List<U32>, +off: Nat) -> +List<U32>:
  B.Bytes.slice(b, Nat.add(off, 2n), P9.slen(b, off))

# The offset just past the string at off.
def P9.after(+b: +List<U32>, +off: Nat) -> Nat:
  Nat.add(Nat.add(off, 2n), P9.slen(b, off))

# A decoded request and the offset where its fields end.
type P9Got is Data:
  P9Got{req: P9Req, end: Nat}

# The names of a Twalk and the offset where they end.
type P9Names is Data:
  P9Names{names: +List<+List<U32>>, end: Nat}

def P9.names.cons(name: +List<U32>, rest: P9Names) -> P9Names:
  match rest:
    case P9Names{names, end}:
      P9Names{name <> names, end}

# n strings from off on.
def P9.names(n: Nat, +b: +List<U32>, +off: Nat) -> P9Names:
  match n:
    case 0n:
      P9Names{[], off}
    case 1n+p:
      P9.names.cons(P9.str(b, off), P9.names(p, b, P9.after(b, off)))

def P9.walk.got(fid: U32, newfid: U32, ns: P9Names) -> P9Got:
  match ns:
    case P9Names{names, end}:
      P9Got{Twalk{fid, newfid, names}, end}

# A Twalk names at most 16 elements (MAXWELEM); more is refused by an end
# past any body.
def P9.walk(ok: Bool, +b: +List<U32>, +n: Nat) -> P9Got:
  match ok:
    case True{}:
      P9.walk.got(P9.u32(b, 0n), P9.u32(b, 4n), P9.names(n, b, 10n))
    case False{}:
      P9Got{Tunknown{110}, Nat.add(List.length(&2, U32, b), 1n)}

# The fields of a message of type k, read from its body b.
def P9.fields(k: U32, +b: +List<U32>) -> P9Got:
  match k:
    case 8:
      P9Got{Tstatfs{P9.u32(b, 0n)}, 4n}
    case 12:
      P9Got{Tlopen{P9.u32(b, 0n), P9.u32(b, 4n)}, 8n}
    case 14:
      +o = P9.after(b, 4n)
      P9Got{Tlcreate{P9.u32(b, 0n), P9.str(b, 4n), P9.u32(b, o), P9.u32(b, Nat.add(o, 4n)), P9.u32(b, Nat.add(o, 8n))}, Nat.add(o, 12n)}
    case 16:
      +o1 = P9.after(b, 4n)
      +o2 = P9.after(b, o1)
      P9Got{Tsymlink{P9.u32(b, 0n), P9.str(b, 4n), P9.str(b, o1), P9.u32(b, o2)}, Nat.add(o2, 4n)}
    case 22:
      P9Got{Treadlink{P9.u32(b, 0n)}, 4n}
    case 24:
      P9Got{Tgetattr{P9.u32(b, 0n), P9.u64(b, 4n)}, 12n}
    case 26:
      P9Got{Tsetattr{P9.u32(b, 0n), P9.u32(b, 4n), P9.u32(b, 8n), P9.u32(b, 12n), P9.u32(b, 16n), P9.u64(b, 20n)}, 60n}
    case 30:
      P9Got{Txattrwalk{P9.u32(b, 0n), P9.u32(b, 4n), P9.str(b, 8n)}, P9.after(b, 8n)}
    case 40:
      P9Got{Treaddir{P9.u32(b, 0n), P9.u64(b, 4n), P9.u32(b, 12n)}, 16n}
    case 50:
      P9Got{Tfsync{P9.u32(b, 0n)}, 8n}
    case 72:
      +o = P9.after(b, 4n)
      P9Got{Tmkdir{P9.u32(b, 0n), P9.str(b, 4n), P9.u32(b, o), P9.u32(b, Nat.add(o, 4n))}, Nat.add(o, 8n)}
    case 74:
      +o = P9.after(b, 4n)
      +o4 = Nat.add(o, 4n)
      P9Got{Trenameat{P9.u32(b, 0n), P9.str(b, 4n), P9.u32(b, o), P9.str(b, o4)}, P9.after(b, o4)}
    case 76:
      +o = P9.after(b, 4n)
      P9Got{Tunlinkat{P9.u32(b, 0n), P9.str(b, 4n), P9.u32(b, o)}, Nat.add(o, 4n)}
    case 100:
      P9Got{Tversion{P9.u32(b, 0n), P9.str(b, 4n)}, P9.after(b, 4n)}
    case 104:
      +o1 = P9.after(b, 8n)
      +o2 = P9.after(b, o1)
      P9Got{Tattach{P9.u32(b, 0n), P9.u32(b, 4n), P9.str(b, 8n), P9.str(b, o1), P9.u32(b, o2)}, Nat.add(o2, 4n)}
    case 108:
      P9Got{Tflush{P9.u16(b, 0n)}, 2n}
    case 110:
      +n = U32.to_nat(P9.u16(b, 8n))
      P9.walk(Nat.is_le(n, 16n), b, n)
    case 116:
      P9Got{Tread{P9.u32(b, 0n), P9.u64(b, 4n), P9.u32(b, 12n)}, 16n}
    case 118:
      +n = U32.to_nat(P9.u32(b, 12n))
      P9Got{Twrite{P9.u32(b, 0n), P9.u64(b, 4n), B.Bytes.slice(b, 16n, n)}, Nat.add(16n, n)}
    case 120:
      P9Got{Tclunk{P9.u32(b, 0n)}, 4n}
    case _:
      P9Got{Tunknown{k}, 0n}

def P9.when(ok: Bool, m: P9Msg) -> Maybe<&2, P9Msg>:
  match ok:
    case True{}:
      Some{m}
    case False{}:
      None{}

# Some message when its fields end inside the body.
def P9.check(tag: U32, +len: Nat, g: P9Got) -> Maybe<&2, P9Msg>:
  match g:
    case P9Got{req, end}:
      P9.when(Nat.is_le(end, len), P9Msg{tag, req})

def P9.decode(ok: Bool, +bs: +List<U32>, +len: Nat) -> Maybe<&2, P9Msg>:
  match ok:
    case True{}:
      +b = List.drop(&2, U32, bs, 7n)
      P9.check(P9.u16(bs, 5n), Nat.sub(len, 7n), P9.fields(P9.le(1n, bs, 4n), b))
    case False{}:
      None{}

def P9.parse(bs: +List<U32>) -> Maybe<&2, P9Msg>:
  +bs = bs
  +len = List.length(&2, U32, bs)
  ok = Nat.is_le(7n, len) && Nat.is_eq(U32.to_nat(P9.u32(bs, 0n)), len)
  P9.decode(ok, bs, len)

# Encoding.

def P9.cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def P9.byte(x: U32) -> +List<U32>:
  [(x .&. 255 : U32)]

# A string: len[2] then its bytes.
def P9.bstr(+s: +List<U32>) -> +List<U32>:
  P9.cat(B.Bytes.le16(U32.from_nat(List.length(&2, U32, s))), s)

def P9.bqid(q: Qid) -> +List<U32>:
  match q:
    case Qid{kind, version, path}:
      P9.cat(P9.byte(kind), P9.cat(B.Bytes.le32(version), B.Bytes.le64(path)))

def P9.bqids(qs: +List<Qid>) -> +List<U32>:
  match qs:
    case Nil{}:
      []
    case Con{q, rest}:
      P9.cat(P9.bqid(q), P9.bqids(rest))

def P9.bdirent(d: P9Dirent) -> +List<U32>:
  match d:
    case P9Dirent{qid, next, kind, name}:
      P9.cat(P9.bqid(qid), P9.cat(B.Bytes.le64(next), P9.cat(P9.byte(kind), P9.bstr(name))))

def P9.bdirents.seq(ds: +List<P9Dirent>) -> +List<U32>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      P9.cat(P9.bdirent(d), P9.bdirents.seq(rest))

# Lists up to this many entries are encoded sequentially.
def P9.leaf() -> Nat:
  16n

def P9.small(+n: Nat) -> Bool:
  Nat.is_le(n, P9.leaf())

# The entries of an Rreaddir (n of them), encoded as two halves in parallel
# when the list is long; d bounds the depth.
def P9.bdirents(d: Nat, small: Bool, +n: Nat, +ds: +List<P9Dirent>) -> +List<U32>:
  match d small:
    case 0n _:
      P9.bdirents.seq(ds)
    case 1n+p True{}:
      P9.bdirents.seq(ds)
    case 1n+(+p) False{}:
      +h = Nat.div(n, 2n)
      +m = Nat.sub(n, h)
      +l = List.take(&2, P9Dirent, ds, h)
      +r = List.drop(&2, P9Dirent, ds, h)
      +sl = P9.small(h)
      +sr = P9.small(m)
      a b = P9.bdirents(p, sl, h, l) P9.bdirents(p, sr, m, r)
      P9.cat(a, b)

def P9.zero64() -> +List<U32>:
  B.Bytes.zeros(8n)

def P9.bstat(st: P9Stat) -> +List<U32>:
  match st:
    case P9Stat{qid, mode, uid, gid, nlink, size, blocks, atime, mtime, ctime}:
      +z = P9.zero64()
      head = P9.cat(B.Bytes.le64(U.U64{0, 2047}), P9.cat(P9.bqid(qid), P9.cat(B.Bytes.le32(mode), P9.cat(B.Bytes.le32(uid), B.Bytes.le32(gid)))))
      sizes = P9.cat(B.Bytes.le64(nlink), P9.cat(z, P9.cat(B.Bytes.le64(size), P9.cat(B.Bytes.le64(U.U64{0, 4096}), B.Bytes.le64(blocks)))))
      times = P9.cat(B.Bytes.le64(atime), P9.cat(z, P9.cat(B.Bytes.le64(mtime), P9.cat(z, P9.cat(B.Bytes.le64(ctime), z)))))
      P9.cat(head, P9.cat(sizes, P9.cat(times, B.Bytes.zeros(32n))))

# A response's type and the bytes after its tag.
type P9Out is Data:
  P9Out{kind: U32, body: +List<U32>}

def P9.out(r: P9Resp) -> P9Out:
  match r:
    case Rlerror{ecode}:
      P9Out{7, B.Bytes.le32(ecode)}
    case Rstatfs{bsize, blocks, bfree, bavail, files, ffree}:
      # type 0x01021997 (V9FS_MAGIC)
      head = P9.cat(B.Bytes.le32(16914839), P9.cat(B.Bytes.le32(bsize), B.Bytes.le64(blocks)))
      counts = P9.cat(B.Bytes.le64(bfree), P9.cat(B.Bytes.le64(bavail), P9.cat(B.Bytes.le64(files), B.Bytes.le64(ffree))))
      P9Out{9, P9.cat(head, P9.cat(counts, P9.cat(P9.zero64(), B.Bytes.le32(255))))}
    case Rlopen{qid, iounit}:
      P9Out{13, P9.cat(P9.bqid(qid), B.Bytes.le32(iounit))}
    case Rlcreate{qid, iounit}:
      P9Out{15, P9.cat(P9.bqid(qid), B.Bytes.le32(iounit))}
    case Rsymlink{qid}:
      P9Out{17, P9.bqid(qid)}
    case Rreadlink{target}:
      P9Out{23, P9.bstr(target)}
    case Rgetattr{stat}:
      P9Out{25, P9.bstat(stat)}
    case Rsetattr{}:
      P9Out{27, []}
    case Rreaddir{entries}:
      +entries = entries
      +n = List.length(&2, P9Dirent, entries)
      +es = P9.bdirents(32n, P9.small(n), n, entries)
      P9Out{41, P9.cat(B.Bytes.le32(U32.from_nat(List.length(&2, U32, es))), es)}
    case Rfsync{}:
      P9Out{51, []}
    case Rmkdir{qid}:
      P9Out{73, P9.bqid(qid)}
    case Rrenameat{}:
      P9Out{75, []}
    case Runlinkat{}:
      P9Out{77, []}
    case Rversion{msize, version}:
      P9Out{101, P9.cat(B.Bytes.le32(msize), P9.bstr(version))}
    case Rattach{qid}:
      P9Out{105, P9.bqid(qid)}
    case Rflush{}:
      P9Out{109, []}
    case Rwalk{qids}:
      +qids = qids
      P9Out{111, P9.cat(B.Bytes.le16(U32.from_nat(List.length(&2, Qid, qids))), P9.bqids(qids))}
    case Rread{data}:
      +data = data
      P9Out{117, P9.cat(B.Bytes.le32(U32.from_nat(List.length(&2, U32, data))), data)}
    case Rwrite{count}:
      P9Out{119, B.Bytes.le32(count)}
    case Rclunk{}:
      P9Out{121, []}

def P9.frame(tag: U32, o: P9Out) -> +List<U32>:
  match o:
    case P9Out{kind, +body}:
      +size = (7 + U32.from_nat(List.length(&2, U32, body)) : U32)
      P9.cat(B.Bytes.le32(size), P9.cat(P9.byte(kind), P9.cat(B.Bytes.le16(tag), body)))

def P9.build(tag: U32, r: P9Resp) -> +List<U32>:
  P9.frame(tag, P9.out(r))
