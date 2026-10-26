import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/vmm/simfs.bend as F
import ./t.bend as T

# The simulator's in-memory filesystem (src/vmm/simfs.bend), driven through
# VmFs effects. It needs no 9P codec, so it runs while src/fs/p9wire.bend is
# open. Errors are macOS errnos. The share holds (inode in parentheses):
# (2) the root, (3) f "hi", (4) d, (5) d/x "x", (6) l -> f.

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def str(s: String) -> +List<U32>:
  B.Bytes.of_string(s)

def share() -> F.SimFs:
  +fs = F.SimFs.with_file(F.SimFs.new(), "f", str("hi"))
  fs = F.SimFs.with_dir(fs, "d")
  fs = F.SimFs.with_file(fs, "d/x", str("x"))
  F.SimFs.with_link(fs, "l", "f")

def show_u64(a: U.U64) -> String:
  match a:
    case U.U64{h, l}:
      U32.show(l)

def show_entries(es: +List<V.FsEntry>) -> String:
  match es:
    case Nil{}:
      ""
    case V.FsEntry{n, i, k} <> t:
      n ++ "/" ++ show_u64(i) ++ "/" ++ U32.show(k) ++ " " ++ show_entries(t)

# A short text form of an answer.
def show_res(r: V.FsResult) -> String:
  match r:
    case V.FsErr{e}:
      "err " ++ U32.show(e)
    case V.FsOk{}:
      "ok"
    case V.FsGotAttr{V.FsAttr{mode, uid, gid, nlink, size, ino, blocks, at, mt, ct}}:
      "attr " ++ U32.show(mode) ++ " " ++ U32.show(nlink) ++ " " ++ show_u64(size) ++ " " ++ show_u64(ino) ++ " " ++ show_u64(blocks)
    case V.FsBytes{bs}:
      "bytes " ++ show(bs)
    case V.FsCount{n}:
      "count " ++ U32.show(n)
    case V.FsEntries{es}:
      "entries " ++ show_entries(es)
    case V.FsLink{t}:
      "link " ++ t
    case V.FsStatfsOk{bs, b, bf, ba, f, ff}:
      "statfs " ++ U32.show(bs) ++ " " ++ show_u64(b) ++ " " ++ show_u64(ff)

# Runs ops in order on share sh, answers their text forms joined by "; ".
def ops(xs: +List<V.FsOp>, -R: Type, +sh: U32, acc: String) -> V.Op<R, String>:
  match xs:
    case Nil{}:
      V.Op.pure(R, String, acc)
    case o <> t:
      V.Op.bind(R, V.FsResult, String, V.Op.fs(R, sh, o), r => ops(t, R, sh, acc ++ show_res(r) ++ "; "))

def out(r: Maybe<&1, S.Sim & String>) -> String:
  match r:
    case None{}:
      "did not run"
    case Some{(s, o)}:
      o

def run_on(+sh: U32, xs: +List<V.FsOp>) -> String:
  out(S.Sim.exec(String, S.Sim.with_fs(S.Sim.new(u64(4096), 0n), share()), ops(xs, String, sh, "")))

def check(+name: String, xs: +List<V.FsOp>, want: String) -> IO(Unit):
  T.eq_str(name, run_on(0, xs), want)

def main() -> IO(Unit):
  do IO<Unit>:
    check("simfs stat", [V.FsStat{""}, V.FsStat{"f"}, V.FsStat{"d"}, V.FsStat{"l"}, V.FsStat{"nope"}, V.FsStat{"f/x"}],
      "attr 16877 2 0 2 0; attr 33188 1 2 3 1; attr 16877 2 0 4 0; attr 41471 1 1 6 1; err 2; err 2; ")
    check("simfs list", [V.FsList{"", 0, 10}, V.FsList{"", 1, 1}, V.FsList{"d", 0, 10}, V.FsList{"f", 0, 10}, V.FsList{"no", 0, 1}],
      "entries f/3/8 d/4/4 l/6/10 ; entries d/4/4 ; entries x/5/8 ; err 20; err 2; ")
    check("simfs read", [V.FsRead{"f", u64(0), 10}, V.FsRead{"f", u64(1), 10}, V.FsRead{"f", u64(5), 10}, V.FsRead{"d", u64(0), 1}, V.FsRead{"l", u64(0), 1}],
      "bytes [104, 105]; bytes [105]; bytes []; err 21; err 62; ")
    check("simfs create write", [V.FsCreate{"n", 420}, V.FsCreate{"n", 420}, V.FsWrite{"n", u64(2), [1, 2]}, V.FsRead{"n", u64(0), 9}, V.FsStat{"n"}, V.FsCreate{"q/n", 420}, V.FsCreate{"f/n", 420}],
      "ok; err 17; count 2; bytes [0, 0, 1, 2]; attr 33188 1 4 7 1; err 2; err 20; ")
    check("simfs mkdir", [V.FsMkdir{"m", 448}, V.FsStat{"m"}, V.FsMkdir{"m/k", 493}, V.FsList{"m", 0, 9}, V.FsMkdir{"d", 493}],
      "ok; attr 16832 2 0 7 0; ok; entries k/8/4 ; err 17; ")
    check("simfs remove", [V.FsRemove{"d", True{}}, V.FsRemove{"d", False{}}, V.FsRemove{"f", True{}}, V.FsRemove{"d/x", False{}}, V.FsRemove{"d", True{}}, V.FsStat{"d"}, V.FsRemove{"", True{}}, V.FsRemove{"zz", False{}}],
      "err 66; err 1; err 20; ok; ok; err 2; err 16; err 2; ")
    check("simfs rename", [V.FsRename{"d", "e"}, V.FsStat{"e/x"}, V.FsStat{"d/x"}, V.FsRename{"f", "e/f"}, V.FsList{"e", 0, 9}, V.FsRename{"e", "e/x/y"}, V.FsRename{"e", "e/y"}, V.FsRename{"e/f", "e"}, V.FsRename{"zz", "y"}, V.FsRename{"l", "e/x"}, V.FsRead{"e/x", u64(0), 9}],
      "ok; attr 33188 1 1 5 1; err 2; ok; entries f/3/8 x/5/8 ; err 20; err 22; err 21; err 2; ok; err 62; ")
    check("simfs truncate chmod", [V.FsTruncate{"f", u64(1)}, V.FsRead{"f", u64(0), 9}, V.FsTruncate{"f", u64(3)}, V.FsRead{"f", u64(0), 9}, V.FsChmod{"f", 33216}, V.FsStat{"f"}, V.FsTruncate{"d", u64(0)}, V.FsChmod{"zz", 0}],
      "ok; bytes [104]; ok; bytes [104, 0, 0]; ok; attr 33216 1 3 3 1; err 21; err 2; ")
    check("simfs symlink", [V.FsSymlink{"s", "d/x"}, V.FsReadlink{"s"}, V.FsReadlink{"l"}, V.FsReadlink{"f"}, V.FsSymlink{"f", "x"}, V.FsStat{"s"}],
      "ok; link d/x; link f; err 22; err 17; attr 41471 1 3 7 1; ")
    check("simfs statfs", [V.FsStatfs{}], "statfs 4096 1024 1019; ")
    T.eq_str("simfs other share", run_on(1, [V.FsStat{""}]), "err 78; ")
