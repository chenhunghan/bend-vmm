import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ./hvf.bend as H
import ./fs.bend as Fs

# Host smoke test for shared-directory effects: usage fs_smoke <dir>.

def names(es: +List<V.FsEntry>) -> String:
  match es:
    case Nil{}:
      ""
    case Con{e, rest}:
      Fs.Fs.ename(e) ++ "," ++ names(rest)

def show(r: V.FsResult) -> String:
  match r:
    case V.FsErr{e}:
      "err " ++ U32.show(e)
    case V.FsOk{}:
      "ok"
    case V.FsGotAttr{V.FsAttr{mode, uid, gid, nlink, size, ino, b, a, m, c}}:
      "attr mode=" ++ U32.show(mode) ++ " size=" ++ U.U64.show_hex(size)
    case V.FsBytes{bs}:
      "bytes " ++ List.show(~&2, ~U32, ~U32.show, bs)
    case V.FsCount{n}:
      "count " ++ U32.show(n)
    case V.FsEntries{es}:
      "entries " ++ names(es)
    case V.FsLink{t}:
      "link " ++ t
    case V.FsStatfsOk{bs, b, f, a, fi, ff}:
      "statfs bsize=" ++ U32.show(bs)

def run(sh: U32, label: String, op: V.FsOp) -> IO(Unit):
  do IO<Unit>:
    r : V.FsResult <- Fs.Host.fs(sh, op)
    IO.print(label ++ ": " ++ show(r))

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dir : String = Maybe.default(&1, String, List.get(&1, String, args, 1n), ".")
    sh : U32 <- H.Hvf.share_open(dir)
    run(0, "create", V.FsCreate{"a.txt", 420})
    run(0, "write", V.FsWrite{"a.txt", U.U64.zero(), [104, 105]})
    run(0, "read", V.FsRead{"a.txt", U.U64.zero(), 10})
    run(0, "stat", V.FsStat{"a.txt"})
    run(0, "mkdir", V.FsMkdir{"d", 493})
    run(0, "symlink", V.FsSymlink{"d/l", "../a.txt"})
    run(0, "readlink", V.FsReadlink{"d/l"})
    run(0, "list", V.FsList{"", 0, 10})
    run(0, "escape", V.FsStat{"../etc"})
    run(0, "escape2", V.FsRead{"d/../../x", U.U64.zero(), 1})
    run(0, "rename", V.FsRename{"a.txt", "d/b.txt"})
    run(0, "notempty", V.FsRemove{"d", True{}})
    run(0, "statfs", V.FsStatfs{})
