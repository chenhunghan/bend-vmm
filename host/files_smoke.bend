import Base
import ../main.bend as V
import ../src/vmm/hostfiles.bend as Hf
import ../src/lib/u64.bend as U

# Host smoke test for the package's Fs calls (main.bend): usage
# files_smoke <dir>, where dir holds blob, a file of 10 bytes, and link, a
# symlink to x/y. Prints
# one line per step; the last is "files: done".

def kind(f: Hf.Facts) -> String:
  match f:
    case Hf.Facts{k, U.U64{sh, sl}, U.U64{mh, ml}}:
      "kind " ++ U32.show(k) ++ " size " ++ U32.show(sl) ++ " mtime " ++ U32.show(ml)

def show(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, rest}:
      x ++ "," ++ show(rest)

def run(+d: String) -> IO(U32):
  do IO<U32>:
    +a : U32 <- V.Fs.mkdir_p(d ++ "/x/y/z", 448)
    +b : U32 <- V.Fs.mkdir_p(d ++ "/x/y/z", 448)
    IO.print("files: mkdir_p " ++ U32.show(a) ++ " again " ++ U32.show(b))
    +p : U32 <- V.Fs.rename(d ++ "/blob", d ++ "/x/y/z/blob")
    +c : U32 <- V.Fs.set_mtime(d ++ "/x/y/z/blob", U.U64{0, 1000000000})
    fa : Hf.Facts <- V.Fs.facts(d ++ "/x/y/z/blob")
    IO.print("files: in " ++ U32.show(p) ++ ", set_mtime " ++ U32.show(c) ++ ", facts " ++ kind(fa))
    fd : Hf.Facts <- V.Fs.facts(d ++ "/x/y")
    fn : Hf.Facts <- V.Fs.facts(d ++ "/nothing")
    IO.print("files: dir " ++ kind(fd) ++ ", missing " ++ kind(fn))
    +s1 : U32 <- V.Fs.fsync(d ++ "/x/y/z/blob")
    +s2 : U32 <- V.Fs.fsync_dir(d ++ "/x/y/z")
    +h : U32 <- V.Fs.chmod(d ++ "/x/y/z/blob", 384)
    fh : Hf.Facts <- V.Fs.facts(d ++ "/x/y/z/blob")
    +ok1 : Bool <- V.Fs.no_symlinks(d ++ "/x/y/z/blob")
    +ok2 : Bool <- V.Fs.no_symlinks(d ++ "/link/z/blob")
    IO.print("files: fsync " ++ U32.show(s1) ++ " dir " ++ U32.show(s2) ++ ", chmod " ++ U32.show(h) ++ " " ++ kind(fh) ++ ", plain " ++ Bool.show(ok1) ++ " through link " ++ Bool.show(ok2))
    +r : U32 <- V.Fs.rename(d ++ "/x/y/z/blob", d ++ "/x/y/z/moved")
    ls : List<String> <- V.Fs.ls(d ++ "/x/y/z")
    IO.print("files: rename " ++ U32.show(r) ++ ", ls " ++ show(ls))
    +m : U32 <- V.Fs.remove(d ++ "/x/y/z/moved")
    +n : U32 <- V.Fs.rmdir(d ++ "/x/y/z")
    fz : Hf.Facts <- V.Fs.facts(d ++ "/x/y/z")
    IO.print("files: remove " ++ U32.show(m) ++ " rmdir " ++ U32.show(n) ++ ", gone " ++ kind(fz))
    IO.print("files: done")
    return 0

def main() -> IO(U32):
  do IO<U32>:
    args : List<String> <- IO.args()
    run(Maybe.default(&1, String, List.head(&1, String, List.drop(&1, String, args, 1n)), "/tmp/bend-files"))
