import Base
import ../vmm/abi.bend as V

# What a shared directory's host entries look like to the guest
# (laws/entry.bend). The host answers every name its file system lists, each
# with its file type as stat keeps it (st_mode >> 12: 4 a directory, 8 a
# regular file, 10 a symbolic link; 0 when it could not be looked at).
#   "." and ".." are not entries: the guest's 9p client makes its own.
#   A directory, a regular file and a symbolic link keep their type (the
#   DT_* value, the same number); anything else (a device, a FIFO, a
#   socket) is shown as unknown (0), and the share never opens it.
# And a mode the guest sets (create, mkdir, chmod) keeps its permission bits
# only: never setuid, setgid or sticky on the host.

def Entry.kind(+t: U32) -> U32:
  Bool.pick(U32, U32.is_eq(t, 4) || U32.is_eq(t, 8) || U32.is_eq(t, 10), t, 0)

def Entry.shown(+n: String) -> Bool:
  Bool.not(String.eq(n, ".") || String.eq(n, ".."))

def Entry.name(+e: V.FsEntry) -> String:
  match e:
    case V.FsEntry{n, i, t}:
      n

def Entry.keep(shown: Bool, e: V.FsEntry, rest: List<&2, V.FsEntry>) -> List<&2, V.FsEntry>:
  match shown e:
    case True{} V.FsEntry{n, i, t}:
      Con{V.FsEntry{n, i, Entry.kind(t)}, rest}
    case False{} _:
      rest

def Entry.view(es: List<&2, V.FsEntry>) -> List<&2, V.FsEntry>:
  match es:
    case Nil{}:
      []
    case Con{+e, rest}:
      Entry.keep(Entry.shown(Entry.name(e)), e, Entry.view(rest))

# 0777: the permission bits.
def Entry.perm(m: U32) -> U32:
  (m .&. 511 : U32)
