import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/vmm/simfs.bend as F
import ../src/virtio/queue.bend as Q
import ../src/fs/p9wire.bend as W
import ../src/fs/p9.bend as P
import ./t.bend as T

# The 9P2000.L server on the simulator's in-memory filesystem. Each scenario
# is a list of requests, served in order with the state threaded through;
# request i (from 1) carries tag i, and its reply must equal the wire bytes of
# the expected response. The share holds (inode in parentheses):
#   (2) /            directory 0o755
#   (3) hello.txt    "hello world", 0o644
#   (4) dir          directory 0o755
#   (5) dir/a        "A", 0o644
#   (6) link         symlink -> hello.txt
# New nodes get inodes 7, 8, ...

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def str(s: String) -> +List<U32>:
  B.Bytes.of_string(s)

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def share() -> F.SimFs:
  +fs = F.SimFs.with_file(F.SimFs.new(), "hello.txt", str("hello world"))
  fs = F.SimFs.with_dir(fs, "dir")
  fs = F.SimFs.with_file(fs, "dir/a", str("A"))
  F.SimFs.with_link(fs, "link", "hello.txt")

# A request and the response it must get.
type Step is Data:
  Step{req: W.P9Req, want: W.P9Resp}

def P9Answer.state(a: P.P9Answer) -> P.P9State:
  match a:
    case P.P9Answer{s, r}:
      s

def P9Answer.reply(a: P.P9Answer) -> +List<U32>:
  match a:
    case P.P9Answer{s, r}:
      r

def reqs(steps: +List<Step>) -> +List<W.P9Req>:
  match steps:
    case Nil{}:
      []
    case Step{r, w} <> t:
      r <> reqs(t)

# The expected replies, tags from tag on.
def wants(steps: +List<Step>, +tag: U32) -> +List<+List<U32>>:
  match steps:
    case Nil{}:
      []
    case Step{r, w} <> t:
      W.P9.build(tag, w) <> wants(t, (tag + 1 : U32))

type Out is Data:
  Out{state: P.P9State, replies: +List<+List<U32>>}

# Serves the requests in order, tags from tag on; acc collects the replies
# (reversed).
def session(rs: +List<W.P9Req>, -R: Type, +tag: U32, s: P.P9State, acc: +List<+List<U32>>) -> V.Op<R, Out>:
  match rs:
    case Nil{}:
      V.Op.pure(R, Out, Out{s, List.reverse(&2, +List<U32>, acc)})
    case r <> t:
      V.Op.bind(R, P.P9Answer, Out, P.P9.serve(R, 0, s, W.P9Msg{tag, r}),
        +a => session(t, R, (tag + 1 : U32), P9Answer.state(a), P9Answer.reply(a) <> acc))

def run(fs: F.SimFs, rs: +List<W.P9Req>) -> Maybe<&1, S.Sim & Out>:
  +s = S.Sim.with_fs(S.Sim.new(u64(4096), 0n), fs)
  S.Sim.exec(Out, s, session(rs, Out, 1, P.P9State.new(), []))

def check_replies(got: +List<+List<U32>>, want: +List<+List<U32>>, +name: String, +i: U32) -> IO(Unit):
  match got want:
    case Nil{} Nil{}:
      IO.pure(Unit, Unit{})
    case Con{g, gt} Con{w, wt}:
      do IO<Unit>:
        T.eq_str(name ++ " #" ++ U32.show(i), show(g), show(w))
        check_replies(gt, wt, name, (i + 1 : U32))
    case _ _:
      T.ok(name ++ " reply count", False{})

def check_out(+name: String, r: Maybe<&1, S.Sim & Out>, want: +List<+List<U32>>) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(s, Out{st, got})}:
      check_replies(got, want, name, 1)

# Runs a scenario on the share and checks every reply.
def scenario(+name: String, +steps: +List<Step>) -> IO(Unit):
  check_out(name, run(share(), reqs(steps)), wants(steps, 1))

# The filesystem after a scenario (an empty one when it did not run).
def fs_of(r: Maybe<&1, S.Sim & Out>) -> F.SimFs:
  match r:
    case None{}:
      F.SimFs.new()
    case Some{(s, o)}:
      S.Sim.fs(s)

def fs_after(steps: +List<Step>) -> F.SimFs:
  fs_of(run(share(), reqs(steps)))

def qid(kind: U32, ino: U32) -> W.Qid:
  W.Qid{kind, 0, u64(ino)}

def zero() -> U.U64:
  u64(0)

# The Rgetattr of a node of the simulated share.
def stat(kind: U32, mode: U32, nlink: U32, +size: U32, ino: U32) -> W.P9Resp:
  blocks = U32.div((size + 511 : U32), 512)
  W.Rgetattr{W.P9Stat{qid(kind, ino), mode, 0, 0, u64(nlink), u64(size), u64(blocks), zero(), zero(), zero()}}

def root_qid() -> W.Qid:
  qid(128, 2)

def nofid() -> U32:
  4294967295

def version() -> Step:
  Step{W.Tversion{131072, str("9P2000.L")}, W.Rversion{65536, str("9P2000.L")}}

def attach() -> Step:
  Step{W.Tattach{0, nofid(), str("root"), str(""), 0}, W.Rattach{root_qid()}}

def err(e: U32) -> W.P9Resp:
  W.Rlerror{e}

def walk(fid: U32, newfid: U32, names: +List<+List<U32>>) -> W.P9Req:
  W.Twalk{fid, newfid, names}

def getattr(fid: U32) -> W.P9Req:
  W.Tgetattr{fid, u64(2047)}

def read(fid: U32, off: U32, count: U32) -> W.P9Req:
  W.Tread{fid, u64(off), count}

def readdir(fid: U32, off: U32, count: U32) -> W.P9Req:
  W.Treaddir{fid, u64(off), count}

def dirent(kind: U32, ino: U32, next: U32, dt: U32, name: String) -> W.P9Dirent:
  W.P9Dirent{qid(kind, ino), u64(next), dt, str(name)}

def iounit() -> U32:
  65512

# 1. The Linux mount sequence: version, attach, getattr of the root.
def mount() -> IO(Unit):
  do IO<Unit>:
    scenario("p9 mount", [version(), attach(), Step{getattr(0), stat(128, 16877, 2, 0, 2)}])
    scenario("p9 version small", [Step{W.Tversion{8192, str("9P2000.L")}, W.Rversion{8192, str("9P2000.L")}}])
    scenario("p9 version unknown", [Step{W.Tversion{8192, str("9P2000.u")}, W.Rversion{8192, str("unknown")}}])
    # Tversion resets the fid table.
    scenario("p9 version resets fids", [version(), attach(), version(), Step{getattr(0), err(9)}])

# 2. Walk to a file, getattr, lopen, read.
def file() -> IO(Unit):
  scenario("p9 file", [
    version(), attach(),
    Step{walk(0, 1, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{getattr(1), stat(0, 33188, 1, 11, 3)},
    Step{W.Tlopen{1, 0}, W.Rlopen{qid(0, 3), iounit()}},
    Step{read(1, 0, 100), W.Rread{str("hello world")}},
    Step{read(1, 6, 3), W.Rread{str("wor")}},
    Step{read(1, 11, 10), W.Rread{[]}}
  ])

# 3. Walks: several names, a clone, a partial walk, a missing first name.
def walks() -> IO(Unit):
  scenario("p9 walks", [
    version(), attach(),
    Step{walk(0, 1, [str("dir"), str("a")]), W.Rwalk{[qid(128, 4), qid(0, 5)]}},
    Step{read(1, 0, 10), W.Rread{str("A")}},
    Step{walk(0, 2, []), W.Rwalk{[]}},
    Step{getattr(2), stat(128, 16877, 2, 0, 2)},
    Step{walk(0, 3, [str("dir"), str("nope")]), W.Rwalk{[qid(128, 4)]}},
    Step{getattr(3), err(9)},
    Step{walk(0, 3, [str("nope")]), err(2)},
    Step{walk(0, 3, [str("link")]), W.Rwalk{[qid(2, 6)]}},
    Step{walk(1, 1, []), W.Rwalk{[]}},
    Step{getattr(1), stat(0, 33188, 1, 1, 5)}
  ])

# 4. readdir paging: offsets are entry indexes; count bounds the bytes.
def readdirs() -> IO(Unit):
  scenario("p9 readdir", [
    version(), attach(),
    Step{walk(0, 1, []), W.Rwalk{[]}},
    Step{W.Tlopen{1, 0}, W.Rlopen{root_qid(), iounit()}},
    Step{readdir(1, 0, 8192), W.Rreaddir{[dirent(0, 3, 1, 8, "hello.txt"), dirent(128, 4, 2, 4, "dir"), dirent(2, 6, 3, 10, "link")]}},
    # 40 bytes: "hello.txt" takes 33, "dir" (27) does not fit after it.
    Step{readdir(1, 0, 40), W.Rreaddir{[dirent(0, 3, 1, 8, "hello.txt")]}},
    Step{readdir(1, 1, 40), W.Rreaddir{[dirent(128, 4, 2, 4, "dir")]}},
    Step{readdir(1, 2, 60), W.Rreaddir{[dirent(2, 6, 3, 10, "link")]}},
    Step{readdir(1, 3, 8192), W.Rreaddir{[]}},
    Step{walk(0, 2, [str("dir")]), W.Rwalk{[qid(128, 4)]}},
    Step{readdir(2, 0, 8192), W.Rreaddir{[dirent(0, 5, 1, 8, "a")]}},
    Step{walk(0, 3, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{readdir(3, 0, 8192), err(20)}
  ])

def create_steps() -> +List<Step>:
  [
    version(), attach(),
    Step{walk(0, 1, []), W.Rwalk{[]}},
    Step{W.Tlcreate{1, str("new.txt"), 2, 420, 0}, W.Rlcreate{qid(0, 7), iounit()}},
    Step{W.Twrite{1, u64(0), str("abc")}, W.Rwrite{3}},
    Step{W.Twrite{1, u64(5), str("xy")}, W.Rwrite{2}},
    Step{read(1, 0, 100), W.Rread{[97, 98, 99, 0, 0, 120, 121]}},
    Step{getattr(1), stat(0, 33188, 1, 7, 7)},
    Step{walk(0, 2, []), W.Rwalk{[]}},
    Step{W.Tlcreate{2, str("hello.txt"), 2, 420, 0}, err(17)},
    Step{W.Tlcreate{9, str("x"), 2, 420, 0}, err(9)}
  ]

# 5. Create, write, read back.
def create() -> IO(Unit):
  do IO<Unit>:
    scenario("p9 create", create_steps())
    T.eq_str("p9 create on the share", show(F.SimFs.contents(fs_after(create_steps()), "new.txt")), "[97, 98, 99, 0, 0, 120, 121]")

# 6. mkdir.
def mkdir() -> IO(Unit):
  scenario("p9 mkdir", [
    version(), attach(),
    Step{W.Tmkdir{0, str("sub"), 493, 0}, W.Rmkdir{qid(128, 7)}},
    Step{walk(0, 1, [str("sub")]), W.Rwalk{[qid(128, 7)]}},
    Step{getattr(1), stat(128, 16877, 2, 0, 7)},
    Step{W.Tmkdir{1, str("deeper"), 448, 0}, W.Rmkdir{qid(128, 8)}},
    Step{walk(0, 2, [str("sub"), str("deeper")]), W.Rwalk{[qid(128, 7), qid(128, 8)]}},
    Step{getattr(2), stat(128, 16832, 2, 0, 8)},
    Step{W.Tmkdir{0, str("dir"), 493, 0}, err(17)}
  ])

# 7. unlinkat: a file, a non-empty directory (ENOTEMPTY 66 -> 39), then the
# directory once empty.
def unlink() -> IO(Unit):
  scenario("p9 unlinkat", [
    version(), attach(),
    Step{W.Tunlinkat{0, str("hello.txt"), 0}, W.Runlinkat{}},
    Step{walk(0, 1, [str("hello.txt")]), err(2)},
    Step{W.Tunlinkat{0, str("dir"), 512}, err(39)},
    Step{W.Tunlinkat{0, str("dir"), 0}, err(1)},
    Step{walk(0, 1, [str("dir")]), W.Rwalk{[qid(128, 4)]}},
    Step{W.Tunlinkat{1, str("a"), 512}, err(20)},
    Step{W.Tunlinkat{1, str("a"), 0}, W.Runlinkat{}},
    Step{W.Tunlinkat{0, str("dir"), 512}, W.Runlinkat{}},
    Step{walk(0, 2, [str("dir")]), err(2)},
    Step{W.Tunlinkat{0, str("gone"), 0}, err(2)}
  ])

# 8. renameat: a file, then a directory; fids under the old path follow.
def rename() -> IO(Unit):
  scenario("p9 renameat", [
    version(), attach(),
    Step{walk(0, 1, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{W.Trenameat{0, str("hello.txt"), 0, str("moved.txt")}, W.Rrenameat{}},
    Step{walk(0, 2, [str("hello.txt")]), err(2)},
    Step{walk(0, 2, [str("moved.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{read(1, 0, 5), W.Rread{str("hello")}},
    Step{walk(0, 3, [str("dir"), str("a")]), W.Rwalk{[qid(128, 4), qid(0, 5)]}},
    Step{walk(0, 4, [str("dir")]), W.Rwalk{[qid(128, 4)]}},
    Step{W.Trenameat{0, str("dir"), 0, str("dir2")}, W.Rrenameat{}},
    Step{read(3, 0, 5), W.Rread{str("A")}},
    Step{W.Trenameat{4, str("a"), 0, str("b")}, W.Rrenameat{}},
    Step{walk(0, 5, [str("b")]), W.Rwalk{[qid(0, 5)]}},
    Step{read(3, 0, 5), W.Rread{str("A")}},
    Step{W.Trenameat{0, str("nope"), 0, str("x")}, err(2)}
  ])

# 9. symlink and readlink.
def links() -> IO(Unit):
  scenario("p9 symlink", [
    version(), attach(),
    Step{W.Tsymlink{0, str("ln2"), str("dir/a"), 0}, W.Rsymlink{qid(2, 7)}},
    Step{walk(0, 1, [str("ln2")]), W.Rwalk{[qid(2, 7)]}},
    Step{W.Treadlink{1}, W.Rreadlink{str("dir/a")}},
    Step{getattr(1), stat(2, 41471, 1, 5, 7)},
    Step{walk(0, 2, [str("link")]), W.Rwalk{[qid(2, 6)]}},
    Step{W.Treadlink{2}, W.Rreadlink{str("hello.txt")}},
    Step{walk(0, 3, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{W.Treadlink{3}, err(22)},
    Step{W.Tsymlink{0, str("link"), str("x"), 0}, err(17)}
  ])

# 10. setattr: truncate (valid bit 3), chmod (bit 0), other bits ignored.
def setattr() -> IO(Unit):
  scenario("p9 setattr", [
    version(), attach(),
    Step{walk(0, 1, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{W.Tsetattr{1, 8, 0, 0, 0, u64(5)}, W.Rsetattr{}},
    Step{read(1, 0, 100), W.Rread{str("hello")}},
    Step{getattr(1), stat(0, 33188, 1, 5, 3)},
    Step{W.Tsetattr{1, 8, 0, 0, 0, u64(7)}, W.Rsetattr{}},
    Step{read(1, 0, 100), W.Rread{[104, 101, 108, 108, 111, 0, 0]}},
    Step{W.Tsetattr{1, 1, 33152, 0, 0, u64(0)}, W.Rsetattr{}},
    Step{getattr(1), stat(0, 33152, 1, 7, 3)},
    Step{W.Tsetattr{1, 6, 0, 1000, 1000, u64(0)}, W.Rsetattr{}},
    Step{getattr(1), stat(0, 33152, 1, 7, 3)},
    Step{W.Tsetattr{0, 8, 0, 0, 0, u64(0)}, err(21)}
  ])

# 11. statfs: the simulator's fixed numbers, 5 nodes in use.
def statfs() -> IO(Unit):
  scenario("p9 statfs", [
    version(), attach(),
    Step{W.Tstatfs{0}, W.Rstatfs{4096, u64(1024), u64(1000), u64(1000), u64(1024), u64(1019)}},
    Step{W.Tstatfs{5}, err(9)}
  ])

# 12. clunk, then any use of the fid is EBADF.
def clunk() -> IO(Unit):
  scenario("p9 clunk", [
    version(), attach(),
    Step{walk(0, 1, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    Step{W.Tclunk{1}, W.Rclunk{}},
    Step{getattr(1), err(9)},
    Step{read(1, 0, 10), err(9)},
    Step{W.Tlopen{1, 0}, err(9)},
    Step{walk(1, 2, []), err(9)},
    Step{W.Tclunk{1}, err(9)},
    Step{getattr(0), stat(128, 16877, 2, 0, 2)}
  ])

# 13. Names: "." and ".." (except ".." of the root, which is the root), "/"
# and NUL are refused with EINVAL.
def names() -> IO(Unit):
  scenario("p9 names", [
    version(), attach(),
    Step{walk(0, 1, [str("..")]), W.Rwalk{[root_qid()]}},
    Step{getattr(1), stat(128, 16877, 2, 0, 2)},
    Step{walk(0, 2, [str("dir")]), W.Rwalk{[qid(128, 4)]}},
    Step{walk(2, 3, [str("..")]), err(22)},
    Step{walk(0, 3, [str("dir"), str("..")]), err(22)},
    Step{walk(0, 3, [str(".")]), err(22)},
    Step{walk(0, 3, [str("dir/a")]), err(22)},
    Step{walk(0, 3, [str("/")]), err(22)},
    Step{walk(0, 3, [[104, 0]]), err(22)},
    Step{walk(0, 3, [[]]), err(22)},
    Step{getattr(3), err(9)},
    Step{W.Tlcreate{0, str("../x"), 2, 420, 0}, err(22)},
    Step{W.Tmkdir{0, str(".."), 493, 0}, err(22)},
    Step{W.Tsymlink{0, str("a/b"), str("x"), 0}, err(22)},
    Step{W.Tunlinkat{0, str("dir/a"), 0}, err(22)},
    Step{W.Trenameat{0, str("hello.txt"), 0, str("../x")}, err(22)},
    Step{W.Trenameat{0, str(".."), 0, str("x")}, err(22)}
  ])

# 14. The rest: flush, fsync, xattrwalk and unknown requests, reads of a
# directory, msize caps.
def misc() -> IO(Unit):
  scenario("p9 misc", [
    Step{W.Tversion{100, str("9P2000.L")}, W.Rversion{100, str("9P2000.L")}},
    attach(),
    Step{W.Tflush{7}, W.Rflush{}},
    Step{W.Tfsync{0}, W.Rfsync{}},
    Step{W.Tfsync{3}, err(9)},
    Step{W.Txattrwalk{0, 1, str("user.x")}, err(95)},
    Step{W.Tunknown{6}, err(95)},
    Step{read(0, 0, 10), err(21)},
    Step{walk(0, 1, [str("hello.txt")]), W.Rwalk{[qid(0, 3)]}},
    # msize 100: a read is capped to 89 bytes, iounit is 76.
    Step{W.Tlopen{1, 0}, W.Rlopen{qid(0, 3), 76}},
    Step{read(1, 0, 4096), W.Rread{str("hello world")}}
  ])

def errnos() -> IO(Unit):
  do IO<Unit>:
    T.eq_u32("p9 errno EPERM", P.P9.linux_errno(1), 1)
    T.eq_u32("p9 errno ENOENT", P.P9.linux_errno(2), 2)
    T.eq_u32("p9 errno EINVAL", P.P9.linux_errno(22), 22)
    T.eq_u32("p9 errno EAGAIN", P.P9.linux_errno(35), 11)
    T.eq_u32("p9 errno ENOTSUP", P.P9.linux_errno(45), 95)
    T.eq_u32("p9 errno ELOOP", P.P9.linux_errno(62), 40)
    T.eq_u32("p9 errno ENAMETOOLONG", P.P9.linux_errno(63), 36)
    T.eq_u32("p9 errno ENOTEMPTY", P.P9.linux_errno(66), 39)
    T.eq_u32("p9 errno ENOSYS", P.P9.linux_errno(78), 38)
    T.eq_u32("p9 errno other", P.P9.linux_errno(69), 69)
    T.eq_str("p9 config", show(P.P9.config("share")), "[5, 0, 115, 104, 97, 114, 101]")
    T.eq_str("p9 config empty", show(P.P9.config("")), "[0, 0]")

# P9.process over posted chains. Layout (decimal): memory 4096..20480;
# descriptor table 4096, available ring 8192, used ring 12288; requests at
# 16384 (and 16512), replies at 17408 (and 18432).

def desc(addr: U32, len: U32, flags: U32, next: U32) -> +List<U32>:
  cat(B.Bytes.le64(u64(addr)), cat(B.Bytes.le32(len), cat(B.Bytes.le16(flags), B.Bytes.le16(next))))

def le32s(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      cat(B.Bytes.le32(x), le32s(t))

def le16s(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      cat(B.Bytes.le16(x), le16s(t))

def vq() -> Q.Vq:
  Q.Vq{8, u64(4096), u64(8192), u64(12288), 0, 0}

# Memory with the descriptor table, the available ring (idx, heads) and the
# request bytes at 16384 and 16512.
def machine(table: +List<U32>, idx: U32, heads: +List<U32>, r1: +List<U32>, r2: +List<U32>) -> S.Sim:
  +s = S.Sim.with_fs(S.Sim.new(u64(4096), 16384n), share())
  s = S.Sim.write(s, u64(4096), table)
  s = S.Sim.write(s, u64(8194), cat(B.Bytes.le16(idx), le16s(heads)))
  s = S.Sim.write(s, u64(16384), r1)
  S.Sim.write(s, u64(16512), r2)

def run_q(s: S.Sim, st: P.P9State) -> Maybe<&1, S.Sim & P.P9Pass>:
  S.Sim.exec(P.P9Pass, s, P.P9.process(P.P9Pass, 0, st, vq()))

# Tversion tag 65535 (NOTAG), msize 8192, "9P2000.L"; 21 bytes.
def tversion() -> +List<U32>:
  [21, 0, 0, 0, 100, 255, 255, 0, 32, 0, 0, 8, 0, 57, 80, 50, 48, 48, 48, 46, 76]

# Rversion for it.
def rversion() -> +List<U32>:
  [21, 0, 0, 0, 101, 255, 255, 0, 32, 0, 0, 8, 0, 57, 80, 50, 48, 48, 48, 46, 76]

# Tattach tag 1: fid 0, afid NOFID, uname "", aname "", n_uname 0; 23 bytes.
def tattach() -> +List<U32>:
  [23, 0, 0, 0, 104, 1, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]

# Rattach tag 1 with the root's qid (directory, inode 2).
def rattach() -> +List<U32>:
  [20, 0, 0, 0, 105, 1, 0, 128, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]

# Tgetattr tag 2, fid 0, mask 2047; 19 bytes.
def tgetattr(fid: U32) -> +List<U32>:
  cat([19, 0, 0, 0, 24, 2, 0], cat(B.Bytes.le32(fid), [255, 7, 0, 0, 0, 0, 0, 0]))

def check_q(
  +name: String, r: Maybe<&1, S.Sim & P.P9Pass>, +addr: U32, want: +List<U32>, used: +List<U32>, flag: Bool, +n: U32
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, P.P9Pass{st, q, u})}:
      +want = want
      +used = used
      do IO<Unit>:
        T.eq_str(name ++ " reply", show(S.Sim.read(s, u64(addr), U32.from_nat(List.length(&2, U32, want)))), show(want))
        T.eq_str(name ++ " used ring", show(S.Sim.read(s, u64(12288), U32.from_nat(List.length(&2, U32, used)))), show(used))
        T.ok(name ++ " used flag", Bool.not(Bool.xor(u, flag)))
        T.ok(name ++ " queue", Q.Vq.is_eq(q, Q.Vq{8, u64(4096), u64(8192), u64(12288), n, n}))

# One chain: the request of len bytes (readable) then a 1024-byte writable reply buffer.
def one_chain(len: U32) -> +List<U32>:
  cat(desc(16384, len, 1, 1), desc(17408, 1024, 2, 0))

def process() -> IO(Unit):
  +two = cat(desc(16384, 23, 1, 1), cat(desc(17408, 1024, 2, 0), cat(desc(16512, 19, 1, 3), desc(18432, 1024, 2, 0))))
  +attached = {P.P9State{65536, [P.Fid{0, "", False{}}]} : P.P9State}
  +getattr_reply = W.P9.build(2, stat(128, 16877, 2, 0, 2))
  do IO<Unit>:
    check_q("p9 process version", run_q(machine(one_chain(21), 1, [0], tversion(), []), P.P9State.new()),
      17408, rversion(), cat([0, 0, 1, 0], le32s([0, 21])), True{}, 1)
    # A malformed request (its size field says 99): Rlerror EINVAL, tag 65535.
    check_q("p9 process malformed", run_q(machine(one_chain(21), 1, [0], [99, 0, 0, 0, 100, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], []), P.P9State.new()),
      17408, [11, 0, 0, 0, 7, 255, 255, 22, 0, 0, 0], cat([0, 0, 1, 0], le32s([0, 11])), True{}, 1)
    # Two chains: the attach binds fid 0, so the getattr after it succeeds.
    check_q("p9 process attach", run_q(machine(two, 2, [0, 2], tattach(), tgetattr(0)), P.P9State.new()),
      17408, rattach(), cat([0, 0, 2, 0], le32s([0, 20, 2, 160])), True{}, 2)
    check_q("p9 process getattr", run_q(machine(two, 2, [0, 2], tattach(), tgetattr(0)), P.P9State.new()),
      18432, getattr_reply, cat([0, 0, 2, 0], le32s([0, 20, 2, 160])), True{}, 2)
    # A state passed in: fid 0 already attached.
    check_q("p9 process state", run_q(machine(one_chain(19), 1, [0], tgetattr(0), []), attached),
      17408, getattr_reply, cat([0, 0, 1, 0], le32s([0, 160])), True{}, 1)
    check_q("p9 process empty", run_q(machine(one_chain(21), 0, [], [], []), P.P9State.new()),
      17408, [0, 0, 0, 0], [0, 0, 0, 0], False{}, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    mount()
    file()
    walks()
    readdirs()
    create()
    mkdir()
    unlink()
    rename()
    links()
    setattr()
    statfs()
    clunk()
    names()
    misc()
    errnos()
    process()
