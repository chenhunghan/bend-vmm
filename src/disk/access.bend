import Base

# How a --disk image is attached when the host refuses to open it for
# writing (laws/access.bend): an image this user may not write (EACCES,
# EPERM) or on a read-only file system (EROFS) is attached read-only, as the
# guest's read-only disk, rather than offered writable and failing every
# write; any other error stops the VMM. Errno values are the same on macOS
# and Linux.

def Access.eperm() -> U32:
  1

def Access.eacces() -> U32:
  13

def Access.erofs() -> U32:
  30

def Access.fallback(+errno: U32) -> Bool:
  U32.is_eq(errno, Access.eacces()) || U32.is_eq(errno, Access.eperm()) || U32.is_eq(errno, Access.erofs())

# How an image is opened for each use, as flags for Hvf.disk_open_with:
# 1 read only, 2 an exclusive lock (else a shared one), 4 a regular file
# only. A disk the guest writes is opened read-write and locked
# exclusively, so a second bend-vmm can neither write nor read it (two
# writers corrupt a qcow2 image at once); a :ro disk only reads, with a
# shared lock beside other readers; a qcow2 image's backing file, named
# inside the image, only reads, shared, and must be a regular file (never a
# device or a FIFO the image points at).
type Use is Data:
  Writer{}
  Reader{}
  Backing{}

def Access.flags(u: Use) -> U32:
  match u:
    case Writer{}:
      2
    case Reader{}:
      1
    case Backing{}:
      5

def Access.use(ro: Bool) -> Use:
  match ro:
    case True{}:
      Reader{}
    case False{}:
      Writer{}
