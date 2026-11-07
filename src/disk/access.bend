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
