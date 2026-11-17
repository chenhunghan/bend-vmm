import Base
import ../vmm/abi.bend as V

# Read-only shares (laws/readonly.bend): `--share DIR,ro`. A share's number
# (D.P9Kind's share, the one a snapshot keeps) carries Ro.bit() when it is
# read-only; the host's index is the number without it. Every operation
# that could change the host's files is refused with EROFS, whatever the
# guest asks: one guest must not alter what other VMs read.

def Ro.bit() -> U32:
  256

def Ro.erofs() -> U32:
  30

def Ro.mark(+index: U32, ro: Bool) -> U32:
  Bool.pick(U32, ro, (index .|. Ro.bit() : U32), index)

def Ro.is_ro(+share: U32) -> Bool:
  U32.is_ne((share .&. Ro.bit() : U32), 0)

# The host's index of a share (hvf.c's hvf_shares), without the bits that
# say how it is served (256 read-only, 512 meta: src/fs/meta.bend).
def Ro.index(+share: U32) -> U32:
  (share .&. 255 : U32)

# Whether an operation can change the host's files: write, create, mkdir,
# remove, rename, truncate, chmod, symlink, and a write from guest memory.
def Ro.changes(op: V.FsOp) -> Bool:
  match op:
    case V.FsStat{p}:
      False{}
    case V.FsList{p, f, m}:
      False{}
    case V.FsRead{p, o, l}:
      False{}
    case V.FsReadlink{p}:
      False{}
    case V.FsStatfs{}:
      False{}
    case V.FsReadRam{p, o, i}:
      False{}
    case V.FsXattr{p, n}:
      False{}
    case _:
      True{}

def Ro.refuses(+share: U32, op: V.FsOp) -> Bool:
  Ro.is_ro(share) && Ro.changes(op)
