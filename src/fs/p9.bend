import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ../virtio/queue.bend as Q
import ./p9wire.bend as W

# A 9P2000.L server over the host's shared directory (V.FsOp effects), and
# the virtio-9p request queue (Virtio 1.2 section 5.11: device id 9, feature
# VIRTIO_9P_MOUNT_TAG bit 0, config tag_len[2] tag; one queue). The guest
# mounts it with: mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt
#
# State: msize and the fid table, each fid naming a path relative to the
# share ("" is its root) and whether it was opened.
# Behaviour:
#   Tversion: msize = min(requested, 65536); version "9P2000.L" if requested
#     exactly, else "unknown". Resets the fid table.
#   Tattach: fid -> "" (root), Rattach with the root's qid (from FsStat).
#   Twalk: newfid -> fid's path extended by each name, stopping at the first
#     name that does not exist (FsStat fails): Rwalk with the qids found. If
#     the first name fails, Rlerror. newfid is bound only if all names were
#     walked (or there were none: a clone). Names "." / ".." / containing
#     "/" or NUL are refused with EINVAL (".." of the root is the root).
#   Tgetattr: FsStat -> Rgetattr. Tsetattr: mode (valid bit 0) -> FsChmod,
#     size (valid bit 3) -> FsTruncate; other bits ignored -> Rsetattr.
#   Tlopen: marks the fid open, Rlopen with its qid and iounit msize - 24.
#   Tlcreate: FsCreate(dir path + "/" + name); the fid now names the new
#     file, opened. Tmkdir, Tsymlink: FsMkdir, FsSymlink, answer the new qid.
#   Tread: FsRead (count capped to msize - 11) -> Rread.
#   Twrite: FsWrite -> Rwrite with FsCount.
#   Treaddir: FsList(path, offset, n) -> Rreaddir, as many entries as fit in
#     count bytes; offsets are entry indexes (next = index + 1).
#   Tunlinkat: FsRemove(dir + "/" + name, flags has AT_REMOVEDIR 512).
#   Trenameat: FsRename. Treadlink: FsReadlink. Tstatfs: FsStatfs.
#   Tfsync: Rfsync. Tflush: Rflush. Tclunk: drops the fid, Rclunk.
#   Txattrwalk, Tunknown: Rlerror EOPNOTSUPP (95).
#   An unknown fid: Rlerror EBADF (9). A host error: Rlerror with its macOS
#   errno translated to Linux's (P9.linux_errno).
# Qids: type 128 (QTDIR) for directories, 2 (QTSYMLINK) for symlinks, 0
# otherwise; version 0; path = inode.

type Fid is Data:
  Fid{fid: U32, path: String, open: Bool}

type P9State is Data:
  P9State{msize: U32, fids: +List<Fid>}

def P9State.new() -> P9State:
  P9State{8192, []}

# The Linux errno for a macOS errno (equal below 35; EAGAIN 35 -> 11,
# ENOTEMPTY 66 -> 39, ENAMETOOLONG 63 -> 36, ELOOP 62 -> 40, ENOSYS 78 -> 38,
# ENOTSUP 45 -> 95, others unchanged).
def P9.linux_errno(+e: U32) -> U32:
  Bool.pick(U32, U32.is_lt(e, 35), e,
    Bool.pick(U32, U32.is_eq(e, 35), 11,
      Bool.pick(U32, U32.is_eq(e, 66), 39,
        Bool.pick(U32, U32.is_eq(e, 63), 36,
          Bool.pick(U32, U32.is_eq(e, 62), 40,
            Bool.pick(U32, U32.is_eq(e, 78), 38,
              Bool.pick(U32, U32.is_eq(e, 45), 95, e)))))))

# The config space for a mount tag.
def P9.config(tag: String) -> +List<U32>:
  +bs = B.Bytes.of_string(tag)
  List.append(&2, U32, B.Bytes.le16(U32.from_nat(List.length(&2, U32, bs))), bs)

type P9Answer is Data:
  P9Answer{state: P9State, reply: +List<U32>}

# Linux errnos the server answers by itself.
def P9.eio() -> U32:
  5

def P9.ebadf() -> U32:
  9

def P9.einval() -> U32:
  22

def P9.eopnotsupp() -> U32:
  95

# The largest msize this server accepts.
def P9.max_msize() -> U32:
  65536

# a - b, or 0 when b is larger.
def P9.sub_sat(+a: U32, +b: U32) -> U32:
  Bool.pick(U32, U32.is_lt(a, b), 0, (a - b : U32))

def P9State.msize(s: P9State) -> U32:
  match s:
    case P9State{m, fs}:
      m

def P9State.fids(s: P9State) -> +List<Fid>:
  match s:
    case P9State{m, fs}:
      fs

# The I/O unit Rlopen and Rlcreate answer: msize less the Rread header.
def P9.iounit(s: P9State) -> U32:
  P9.sub_sat(P9State.msize(s), 24)

def Fid.id(f: Fid) -> U32:
  match f:
    case Fid{i, p, o}:
      i

def Fid.path(f: Fid) -> String:
  match f:
    case Fid{i, p, o}:
      p

def P9.fid_find(fids: +List<Fid>, +fid: U32) -> Maybe<&2, Fid>:
  match fids:
    case Nil{}:
      None{}
    case +f <> t:
      Bool.pick(Maybe<&2, Fid>, U32.is_eq(Fid.id(f), fid), Some{f}, P9.fid_find(t, fid))

def P9.fid_drop(fids: +List<Fid>, +fid: U32) -> +List<Fid>:
  match fids:
    case Nil{}:
      []
    case +f <> +t:
      Bool.pick(+List<Fid>, U32.is_eq(Fid.id(f), fid), P9.fid_drop(t, fid), f <> P9.fid_drop(t, fid))

# The state with fid bound to f (replacing any earlier binding).
def P9.bind(s: P9State, +f: Fid) -> P9State:
  match s:
    case P9State{m, fs}:
      P9State{m, f <> P9.fid_drop(fs, Fid.id(f))}

def P9.unbind(s: P9State, +fid: U32) -> P9State:
  match s:
    case P9State{m, fs}:
      P9State{m, P9.fid_drop(fs, fid)}

# The rest of s after prefix, if s starts with it.
def P9.strip(prefix: String, s: String) -> Maybe<&2, String>:
  match prefix s:
    case SNil{} s:
      Some{s}
    case SCon{c, pt} SNil{}:
      None{}
    case SCon{c, pt} SCon{d, st}:
      Bool.pick(Maybe<&2, String>, Char.is_eq(c, d), P9.strip(pt, st), None{})

def P9.moved.under(+to: String, path: String, r: Maybe<&2, String>) -> String:
  match r:
    case None{}:
      path
    case Some{rest}:
      to ++ "/" ++ rest

# A path after `from` was renamed to `to`: from itself and everything under
# it move.
def P9.moved(+from: String, +to: String, +path: String) -> String:
  Bool.pick(String, String.eq(path, from), to, P9.moved.under(to, path, P9.strip(from ++ "/", path)))

def P9.move_fids(fids: +List<Fid>, +from: String, +to: String) -> +List<Fid>:
  match fids:
    case Nil{}:
      []
    case Fid{i, +p, o} <> t:
      Fid{i, P9.moved(from, to, p), o} <> P9.move_fids(t, from, to)

def P9.rename_fids(s: P9State, +from: String, +to: String) -> P9State:
  match s:
    case P9State{m, fs}:
      P9State{m, P9.move_fids(fs, from, to)}

# A name as a host path component.
def P9.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case b <> t:
      SCon{Char.from_u32(b), P9.chars(t)}

def P9.no_sep(bs: +List<U32>) -> Bool:
  match bs:
    case Nil{}:
      True{}
    case +b <> t:
      U32.is_ne(b, 47) && U32.is_ne(b, 0) && P9.no_sep(t)

def P9.is_dot(bs: +List<U32>) -> Bool:
  match bs:
    case [46]:
      True{}
    case _:
      False{}

def P9.is_dotdot(bs: +List<U32>) -> Bool:
  match bs:
    case [46, 46]:
      True{}
    case _:
      False{}

def P9.bytes_eq(xs: +List<U32>, ys: +List<U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{x, xt} Con{y, yt}:
      U32.is_eq(x, y) && P9.bytes_eq(xt, yt)
    case _ _:
      False{}

# Whether a name may be one path component: not empty, ".", "..", and
# without "/" or NUL.
def P9.name_ok(+bs: +List<U32>) -> Bool:
  Bool.not(List.is_empty(&2, U32, bs)) && Bool.not(P9.is_dot(bs)) && Bool.not(P9.is_dotdot(bs)) && P9.no_sep(bs)

# A name inside directory dir ("" is the root).
def P9.join(+dir: String, +name: String) -> String:
  Bool.pick(String, String.is_empty(dir), name, dir ++ "/" ++ name)

# The qid of a file: QTDIR for a directory, QTSYMLINK for a symlink.
def P9.qid_kind(+mode: U32) -> U32:
  +t = (mode .&. 61440 : U32)
  Bool.pick(U32, U32.is_eq(t, 16384), 128, Bool.pick(U32, U32.is_eq(t, 40960), 2, 0))

def P9.qid(a: V.FsAttr) -> W.Qid:
  match a:
    case V.FsAttr{mode, uid, gid, nlink, size, ino, blocks, at, mt, ct}:
      W.Qid{P9.qid_kind(mode), 0, ino}

def P9.stat(a: V.FsAttr) -> W.P9Stat:
  match a:
    case V.FsAttr{+mode, uid, gid, nlink, size, +ino, blocks, at, mt, ct}:
      W.P9Stat{W.Qid{P9.qid_kind(mode), 0, ino}, mode, uid, gid, U.U64{0, nlink}, size, blocks, at, mt, ct}

# The qid of a directory entry, from its DT_* type.
def P9.dirent_qid(+kind: U32, ino: U.U64) -> W.Qid:
  W.Qid{Bool.pick(U32, U32.is_eq(kind, 4), 128, Bool.pick(U32, U32.is_eq(kind, 10), 2, 0)), 0, ino}

# The entries from index next on that fit in room bytes (each takes 24 bytes
# plus its name).
def P9.dirents(es: +List<V.FsEntry>, +next: U32, +room: U32) -> +List<W.P9Dirent>:
  match es:
    case Nil{}:
      []
    case V.FsEntry{name, ino, +kind} <> t:
      +nb = B.Bytes.of_string(name)
      +size = U32.from_nat(Nat.add(24n, List.length(&2, U32, nb)))
      +n1 = (next + 1 : U32)
      Bool.pick(+List<W.P9Dirent>, U32.is_le(size, room),
        W.P9Dirent{P9.dirent_qid(kind, ino), U.U64{0, n1}, kind, nb} <> P9.dirents(t, n1, (room - size : U32)),
        [])

def P9.answer(-R: Type, s: P9State, +tag: U32, r: W.P9Resp) -> V.Op<R, P9Answer>:
  V.Op.pure(R, P9Answer, P9Answer{s, W.P9.build(tag, r)})

def P9.err(-R: Type, s: P9State, +tag: U32, e: U32) -> V.Op<R, P9Answer>:
  P9.answer(R, s, tag, W.Rlerror{e})

# The Linux errno for an answer that is not the one expected.
def P9.fail(r: V.FsResult) -> U32:
  match r:
    case V.FsErr{e}:
      P9.linux_errno(e)
    case _:
      P9.eio()

# The Linux errno of an answer that should be FsOk, 0 when it is.
def P9.ok_errno(r: V.FsResult) -> U32:
  match r:
    case V.FsOk{}:
      0
    case r:
      P9.fail(r)

# The first nonzero errno of two.
def P9.first(+a: U32, b: U32) -> U32:
  Bool.pick(U32, U32.is_zero(a), b, a)

# Answers resp when errno e is 0, else Rlerror e.
def P9.done(-R: Type, s: P9State, +tag: U32, +e: U32, resp: W.P9Resp) -> V.Op<R, P9Answer>:
  P9.answer(R, s, tag, Bool.pick(W.P9Resp, U32.is_zero(e), resp, W.Rlerror{e}))

# Continues with the fid bound to `fid`, or answers EBADF.
def P9.with_fid.go(-R: Type, m: Maybe<&2, Fid>, s: P9State, +tag: U32, k: Fid -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  match m:
    case None{}:
      P9.err(R, s, tag, P9.ebadf())
    case Some{f}:
      k(f)

def P9.with_fid(-R: Type, +s: P9State, +tag: U32, +fid: U32, k: Fid -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  P9.with_fid.go(R, P9.fid_find(P9State.fids(s), fid), s, tag, k)

# Continues with the path of `name` inside the directory fid names, or
# answers EBADF (unknown fid) or EINVAL (bad name).
def P9.with_child.go(-R: Type, ok: Bool, s: P9State, +tag: U32, dir: String, name: +List<U32>, k: String -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  match ok:
    case False{}:
      P9.err(R, s, tag, P9.einval())
    case True{}:
      k(P9.join(dir, P9.chars(name)))

def P9.with_child(-R: Type, +s: P9State, +tag: U32, +fid: U32, +name: +List<U32>, k: String -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.with_child.go(R, P9.name_ok(name), s, tag, Fid.path(f), name, k))

# Continues with the attributes of a FsStat answer, or answers its error.
def P9.on_attr(-R: Type, r: V.FsResult, s: P9State, +tag: U32, k: V.FsAttr -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  match r:
    case V.FsGotAttr{a}:
      k(a)
    case r:
      P9.err(R, s, tag, P9.fail(r))

# Continues after an FsOk answer, or answers its error.
def P9.on_ok(-R: Type, r: V.FsResult, s: P9State, +tag: U32, k: Unit -> V.Op<R, P9Answer>) -> V.Op<R, P9Answer>:
  match r:
    case V.FsOk{}:
      k(Unit{})
    case r:
      P9.err(R, s, tag, P9.fail(r))

# Stats path and answers with the response its qid makes.
def P9.reply_qid(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String, mk: W.Qid -> W.P9Resp) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsStat{path})
    P9.on_attr(R, r, s, tag, a => P9.answer(R, s, tag, mk(P9.qid(a))))

# Tversion.
def P9.version(-R: Type, +tag: U32, +msize: U32, version: +List<U32>) -> V.Op<R, P9Answer>:
  +m = Bool.pick(U32, U32.is_lt(msize, P9.max_msize()), msize, P9.max_msize())
  +want = B.Bytes.of_string("9P2000.L")
  +exact = P9.bytes_eq(version, want)
  P9.answer(R, P9State{m, []}, tag, W.Rversion{m, Bool.pick(+List<U32>, exact, want, B.Bytes.of_string("unknown"))})

# Tattach: fid names the root.
def P9.attach(-R: Type, +share: U32, s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.reply_qid(R, share, P9.bind(s, Fid{fid, "", False{}}), tag, "", q => W.Rattach{q})

# The outcome of a walk: an error, or the path reached, the qids found and
# whether every name was walked.
type P9Walk is Data:
  WalkErr{errno: U32}
  WalkOk{path: String, qids: +List<W.Qid>, done: Bool}

def P9.walk.stop(+path: String, +qids: +List<W.Qid>, r: V.FsResult) -> P9Walk:
  Bool.pick(P9Walk, List.is_empty(&2, W.Qid, qids), WalkErr{P9.fail(r)}, WalkOk{path, List.reverse(&2, W.Qid, qids), False{}})

# After stating the next path: continue the walk there with k, or stop at
# path with the qids found so far (reversed).
def P9.walk.after(
  -R: Type, r: V.FsResult, +path: String, next: String, +qids: +List<W.Qid>,
  k: String -> +List<W.Qid> -> V.Op<R, P9Walk>
) -> V.Op<R, P9Walk>:
  match r:
    case V.FsGotAttr{a}:
      k(next, P9.qid(a) <> qids)
    case r:
      V.Op.pure(R, P9Walk, P9.walk.stop(path, qids, r))

# Walks names from path; qids holds the qids found so far, reversed. ".." of
# the root is the root; any other bad name refuses the whole walk.
def P9.walk.go(names: +List<+List<U32>>, -R: Type, +share: U32, +path: String, +qids: +List<W.Qid>) -> V.Op<R, P9Walk>:
  match names:
    case Nil{}:
      V.Op.pure(R, P9Walk, WalkOk{path, List.reverse(&2, W.Qid, qids), True{}})
    case +n <> t:
      +up = P9.is_dotdot(n) && String.is_empty(path)
      +next = Bool.pick(String, up, path, P9.join(path, P9.chars(n)))
      walk = do V.Op<R, P9Walk>:
        r : V.FsResult <- V.Op.fs(R, share, V.FsStat{next})
        P9.walk.after(R, r, path, next, qids, p => qs => P9.walk.go(t, R, share, p, qs))
      Bool.pick(V.Op<R, P9Walk>, up || P9.name_ok(n), walk, V.Op.pure(R, P9Walk, WalkErr{P9.einval()}))

def P9.walk.fin(-R: Type, w: P9Walk, s: P9State, +tag: U32, +newfid: U32) -> V.Op<R, P9Answer>:
  match w:
    case WalkErr{e}:
      P9.err(R, s, tag, e)
    case WalkOk{p, qids, True{}}:
      P9.answer(R, P9.bind(s, Fid{newfid, p, False{}}), tag, W.Rwalk{qids})
    case WalkOk{p, qids, False{}}:
      P9.answer(R, s, tag, W.Rwalk{qids})

# Twalk.
def P9.walk(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +newfid: U32, names: +List<+List<U32>>) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => V.Op.bind(R, P9Walk, P9Answer, P9.walk.go(names, R, share, Fid.path(f), []), w => P9.walk.fin(R, w, s, tag, newfid)))

def P9.getattr.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsStat{path})
    P9.on_attr(R, r, s, tag, a => P9.answer(R, s, tag, W.Rgetattr{P9.stat(a)}))

# Tgetattr.
def P9.getattr(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.getattr.go(R, share, s, tag, Fid.path(f)))

# Runs op when go, answering the Linux errno of its result (0 for FsOk).
def P9.maybe_op(-R: Type, go: Bool, +share: U32, op: V.FsOp) -> V.Op<R, U32>:
  match go:
    case False{}:
      V.Op.pure(R, U32, 0)
    case True{}:
      do V.Op<R, U32>:
        r : V.FsResult <- V.Op.fs(R, share, op)
        return P9.ok_errno(r)

def P9.setattr.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +path: String, +valid: U32, mode: U32, size: U.U64) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    +e1 : U32 <- P9.maybe_op(R, U32.is_ne((valid .&. 1 : U32), 0), share, V.FsChmod{path, (mode .&. 4095 : U32)})
    e2 : U32 <- P9.maybe_op(R, U32.is_zero(e1) && U32.is_ne((valid .&. 8 : U32), 0), share, V.FsTruncate{path, size})
    P9.done(R, s, tag, P9.first(e1, e2), W.Rsetattr{})

# Tsetattr: mode (valid bit 0), then size (valid bit 3); other bits ignored.
def P9.setattr(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +valid: U32, +mode: U32, +size: U.U64) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.setattr.go(R, share, s, tag, Fid.path(f), valid, mode, size))

# Binds fid to path, opened, and answers mk(qid, iounit).
def P9.open_fid(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +path: String, mk: W.Qid -> U32 -> W.P9Resp) -> V.Op<R, P9Answer>:
  +s2 = P9.bind(s, Fid{fid, path, True{}})
  P9.reply_qid(R, share, s2, tag, path, q => mk(q, P9.iounit(s2)))

def P9.lopen.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +path: String) -> V.Op<R, P9Answer>:
  P9.open_fid(R, share, s, tag, fid, path, q => n => W.Rlopen{q, n})

# Tlopen: marks the fid open.
def P9.lopen(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.lopen.go(R, share, s, tag, fid, Fid.path(f)))

def P9.lcreate.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +path: String, mode: U32) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsCreate{path, (mode .&. 4095 : U32)})
    P9.on_ok(R, r, s, tag, u => P9.open_fid(R, share, s, tag, fid, path, q => n => W.Rlcreate{q, n}))

# Tlcreate: creates name in the directory fid names; fid then names the new
# file, opened.
def P9.lcreate(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +name: +List<U32>, +mode: U32) -> V.Op<R, P9Answer>:
  P9.with_child(R, s, tag, fid, name, p => P9.lcreate.go(R, share, s, tag, fid, p, mode))

def P9.mkdir.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +path: String, mode: U32) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsMkdir{path, (mode .&. 4095 : U32)})
    P9.on_ok(R, r, s, tag, u => P9.reply_qid(R, share, s, tag, path, q => W.Rmkdir{q}))

# Tmkdir.
def P9.mkdir(-R: Type, +share: U32, +s: P9State, +tag: U32, +dfid: U32, +name: +List<U32>, +mode: U32) -> V.Op<R, P9Answer>:
  P9.with_child(R, s, tag, dfid, name, p => P9.mkdir.go(R, share, s, tag, p, mode))

def P9.symlink.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +path: String, target: +List<U32>) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsSymlink{path, P9.chars(target)})
    P9.on_ok(R, r, s, tag, u => P9.reply_qid(R, share, s, tag, path, q => W.Rsymlink{q}))

# Tsymlink.
def P9.symlink(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +name: +List<U32>, +target: +List<U32>) -> V.Op<R, P9Answer>:
  P9.with_child(R, s, tag, fid, name, p => P9.symlink.go(R, share, s, tag, p, target))

def P9.on_link(-R: Type, r: V.FsResult, s: P9State, +tag: U32) -> V.Op<R, P9Answer>:
  match r:
    case V.FsLink{t}:
      P9.answer(R, s, tag, W.Rreadlink{B.Bytes.of_string(t)})
    case r:
      P9.err(R, s, tag, P9.fail(r))

def P9.readlink.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsReadlink{path})
    P9.on_link(R, r, s, tag)

# Treadlink.
def P9.readlink(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.readlink.go(R, share, s, tag, Fid.path(f)))

def P9.on_bytes(-R: Type, r: V.FsResult, s: P9State, +tag: U32) -> V.Op<R, P9Answer>:
  match r:
    case V.FsBytes{bs}:
      P9.answer(R, s, tag, W.Rread{bs})
    case r:
      P9.err(R, s, tag, P9.fail(r))

def P9.read.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String, offset: U.U64, +count: U32) -> V.Op<R, P9Answer>:
  +cap = P9.sub_sat(P9State.msize(s), 11)
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsRead{path, offset, Bool.pick(U32, U32.is_lt(count, cap), count, cap)})
    P9.on_bytes(R, r, s, tag)

# Tread: count capped to msize - 11 (the Rread header).
def P9.read(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +offset: U.U64, +count: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.read.go(R, share, s, tag, Fid.path(f), offset, count))

def P9.on_count(-R: Type, r: V.FsResult, s: P9State, +tag: U32) -> V.Op<R, P9Answer>:
  match r:
    case V.FsCount{n}:
      P9.answer(R, s, tag, W.Rwrite{n})
    case r:
      P9.err(R, s, tag, P9.fail(r))

def P9.write.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String, offset: U.U64, data: +List<U32>) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsWrite{path, offset, data})
    P9.on_count(R, r, s, tag)

# Twrite.
def P9.write(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +offset: U.U64, +data: +List<U32>) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.write.go(R, share, s, tag, Fid.path(f), offset, data))

def P9.on_entries(-R: Type, r: V.FsResult, s: P9State, +tag: U32, +from: U32, +count: U32) -> V.Op<R, P9Answer>:
  match r:
    case V.FsEntries{es}:
      P9.answer(R, s, tag, W.Rreaddir{P9.dirents(es, from, count)})
    case r:
      P9.err(R, s, tag, P9.fail(r))

# The entry index of a readdir offset; past 2^32 nothing is left, so the
# index saturates.
def P9.index(o: U.U64) -> U32:
  match o:
    case U.U64{h, l}:
      Bool.pick(U32, U32.is_zero(h), l, 4294967295)

def P9.readdir.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String, offset: U.U64, +count: U32) -> V.Op<R, P9Answer>:
  +from = P9.index(offset)
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsList{path, from, U32.div(count, 24)})
    P9.on_entries(R, r, s, tag, from, count)

# Treaddir: entries from index offset on, as many as fit in count bytes.
def P9.readdir(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32, +offset: U.U64, +count: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.readdir.go(R, share, s, tag, Fid.path(f), offset, count))

def P9.unlinkat.go(-R: Type, +share: U32, +s: P9State, +tag: U32, path: String, flags: U32) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsRemove{path, U32.is_ne((flags .&. 512 : U32), 0)})
    P9.done(R, s, tag, P9.ok_errno(r), W.Runlinkat{})

# Tunlinkat: removes name from the directory dir names (a directory when
# flags has AT_REMOVEDIR 512).
def P9.unlinkat(-R: Type, +share: U32, +s: P9State, +tag: U32, +dir: U32, +name: +List<U32>, +flags: U32) -> V.Op<R, P9Answer>:
  P9.with_child(R, s, tag, dir, name, p => P9.unlinkat.go(R, share, s, tag, p, flags))

def P9.renameat.go(-R: Type, +share: U32, +s: P9State, +tag: U32, +from: String, +to: String) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsRename{from, to})
    P9.on_ok(R, r, s, tag, u => P9.answer(R, P9.rename_fids(s, from, to), tag, W.Rrenameat{}))

# Trenameat: fids naming the old path, or a path under it, follow it.
def P9.renameat(-R: Type, +share: U32, +s: P9State, +tag: U32, +olddir: U32, +oldname: +List<U32>, +newdir: U32, +newname: +List<U32>) -> V.Op<R, P9Answer>:
  P9.with_child(R, s, tag, olddir, oldname, from => P9.with_child(R, s, tag, newdir, newname, to => P9.renameat.go(R, share, s, tag, from, to)))

def P9.on_statfs(-R: Type, r: V.FsResult, s: P9State, +tag: U32) -> V.Op<R, P9Answer>:
  match r:
    case V.FsStatfsOk{bsize, blocks, bfree, bavail, files, ffree}:
      P9.answer(R, s, tag, W.Rstatfs{bsize, blocks, bfree, bavail, files, ffree})
    case r:
      P9.err(R, s, tag, P9.fail(r))

def P9.statfs.go(-R: Type, +share: U32, +s: P9State, +tag: U32) -> V.Op<R, P9Answer>:
  do V.Op<R, P9Answer>:
    r : V.FsResult <- V.Op.fs(R, share, V.FsStatfs{})
    P9.on_statfs(R, r, s, tag)

# Tstatfs.
def P9.statfs(-R: Type, +share: U32, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.statfs.go(R, share, s, tag))

# Tfsync: nothing is buffered here.
def P9.fsync(-R: Type, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.answer(R, s, tag, W.Rfsync{}))

# Tclunk: forgets the fid.
def P9.clunk(-R: Type, +s: P9State, +tag: U32, +fid: U32) -> V.Op<R, P9Answer>:
  P9.with_fid(R, s, tag, fid, f => P9.answer(R, P9.unbind(s, fid), tag, W.Rclunk{}))

# Serves one request on share `share`.
def P9.serve(-R: Type, share: U32, s: P9State, m: W.P9Msg) -> V.Op<R, P9Answer>:
  match m:
    case W.P9Msg{tag, req}:
      match req:
        case W.Tversion{msize, version}:
          P9.version(R, tag, msize, version)
        case W.Tattach{fid, afid, uname, aname, nu}:
          P9.attach(R, share, s, tag, fid)
        case W.Twalk{fid, newfid, names}:
          P9.walk(R, share, s, tag, fid, newfid, names)
        case W.Tgetattr{fid, mask}:
          P9.getattr(R, share, s, tag, fid)
        case W.Tsetattr{fid, valid, mode, uid, gid, size}:
          P9.setattr(R, share, s, tag, fid, valid, mode, size)
        case W.Tlopen{fid, flags}:
          P9.lopen(R, share, s, tag, fid)
        case W.Tlcreate{fid, name, flags, mode, gid}:
          P9.lcreate(R, share, s, tag, fid, name, mode)
        case W.Tmkdir{dfid, name, mode, gid}:
          P9.mkdir(R, share, s, tag, dfid, name, mode)
        case W.Tsymlink{fid, name, target, gid}:
          P9.symlink(R, share, s, tag, fid, name, target)
        case W.Treadlink{fid}:
          P9.readlink(R, share, s, tag, fid)
        case W.Tread{fid, offset, count}:
          P9.read(R, share, s, tag, fid, offset, count)
        case W.Twrite{fid, offset, data}:
          P9.write(R, share, s, tag, fid, offset, data)
        case W.Treaddir{fid, offset, count}:
          P9.readdir(R, share, s, tag, fid, offset, count)
        case W.Tunlinkat{dir, name, flags}:
          P9.unlinkat(R, share, s, tag, dir, name, flags)
        case W.Trenameat{olddir, oldname, newdir, newname}:
          P9.renameat(R, share, s, tag, olddir, oldname, newdir, newname)
        case W.Tstatfs{fid}:
          P9.statfs(R, share, s, tag, fid)
        case W.Tfsync{fid}:
          P9.fsync(R, s, tag, fid)
        case W.Tflush{oldtag}:
          P9.answer(R, s, tag, W.Rflush{})
        case W.Tclunk{fid}:
          P9.clunk(R, s, tag, fid)
        case W.Txattrwalk{fid, newfid, name}:
          P9.err(R, s, tag, P9.eopnotsupp())
        case W.Tunknown{kind}:
          P9.err(R, s, tag, P9.eopnotsupp())

type P9Pass is Data:
  P9Pass{state: P9State, q: Q.Vq, used: Bool}

# The answer to a request's bytes: Rlerror EINVAL with tag 65535 when they
# are not a message.
def P9.handle(-R: Type, share: U32, s: P9State, m: Maybe<&2, W.P9Msg>) -> V.Op<R, P9Answer>:
  match m:
    case None{}:
      P9.err(R, s, 65535, P9.einval())
    case Some{msg}:
      P9.serve(R, share, s, msg)

# Writes the reply into the chain and pushes it used with the reply's length.
def P9.reply_chain(-R: Type, a: P9Answer, q: Q.Vq, +h: U32, w: +List<Q.Desc>) -> V.Op<R, P9Pass>:
  match a:
    case P9Answer{st, +reply}:
      do V.Op<R, P9Pass>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, reply)
        q2 : Q.Vq <- Q.Vq.push(R, q, h, U32.from_nat(List.length(&2, U32, reply)))
        return P9Pass{st, q2, True{}}

# Serves one chain.
def P9.serve_chain(-R: Type, +share: U32, s: P9State, q: Q.Vq, c: Q.Chain) -> V.Op<R, P9Pass>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, P9Pass>:
        req : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        a : P9Answer <- P9.handle(R, share, s, W.P9.parse(req))
        P9.reply_chain(R, a, q, h, w)

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def P9.step(-R: Type, +share: U32, s: P9State, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool, k: P9Pass -> V.Op<R, P9Pass>) -> V.Op<R, P9Pass>:
  match r:
    case (q, None{}):
      V.Op.pure(R, P9Pass, P9Pass{s, q, used})
    case (q, Some{c}):
      V.Op.bind(R, P9Pass, P9Pass, P9.serve_chain(R, share, s, q, c), k)

# Pops and serves chains, at most fuel of them.
def P9.go(fuel: Nat, -R: Type, +share: U32, p: P9Pass) -> V.Op<R, P9Pass>:
  match fuel:
    case 0n:
      V.Op.pure(R, P9Pass, p)
    case 1n+f:
      match p:
        case P9Pass{s, q, used}:
          do V.Op<R, P9Pass>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            P9.step(R, share, s, r, used, p2 => P9.go(f, R, share, p2))

# Serves every available chain (at most num): the request is the chain's
# readable bytes, the reply goes to its writable descriptors, pushed used with
# the reply's length. A malformed request gets Rlerror EINVAL with tag 65535.
def P9.process(-R: Type, share: U32, s: P9State, q: Q.Vq) -> V.Op<R, P9Pass>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      P9.go(U32.to_nat(num), R, share, P9Pass{s, Q.Vq{num, d, dr, dv, na, nu}, False{}})
