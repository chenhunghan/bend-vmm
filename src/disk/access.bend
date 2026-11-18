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

# A --disk entry: an image path, then options as suffixes in any order:
# ":ro" (the guest only reads it) and ":nocache" (the host does not keep the
# image's blocks in its own page cache: the guest caches them already; 8 in
# the open flags, Access.flags_of). Each suffix counts once.
type Spec is Data:
  Spec{path: String, ro: Bool, nocache: Bool}

def Access.strip(+s: String, +suffix: String) -> String:
  String.take(s, Nat.sub(String.length(s), String.length(suffix)))

# One suffix taken off per step (:ro or :nocache); with neither, the next
# step finds the same and the spec stands. One recursion a step: both
# arguments of a Bool.pick are computed.
def Access.spec.go(fuel: Nat, +s: String, +ro: Bool, +nc: Bool) -> Spec:
  match fuel:
    case 0n:
      Spec{s, ro, nc}
    case 1n+(+f):
      +is_ro : Bool = Bool.not(ro) && String.ends_with(s, ":ro")
      +is_nc : Bool = Bool.not(is_ro) && Bool.not(nc) && String.ends_with(s, ":nocache")
      +s2 : String = Bool.pick(String, is_ro, Access.strip(s, ":ro"), Bool.pick(String, is_nc, Access.strip(s, ":nocache"), s))
      Access.spec.go(f, s2, ro || is_ro, nc || is_nc)

def Access.spec(+s: String) -> Spec:
  Access.spec.go(2n, s, False{}, False{})

def Spec.path(+x: Spec) -> String:
  match x:
    case Spec{p, ro, nc}:
      p

def Spec.ro(+x: Spec) -> Bool:
  match x:
    case Spec{p, ro, nc}:
      ro

def Spec.nocache(+x: Spec) -> Bool:
  match x:
    case Spec{p, ro, nc}:
      nc

def Access.spec_path(+s: String) -> String:
  Spec.path(Access.spec(s))

def Access.spec_ro(+s: String) -> Bool:
  Spec.ro(Access.spec(s))

def Access.spec_nocache(+s: String) -> Bool:
  Spec.nocache(Access.spec(s))

# The suffixes of an entry, as given back after its path.
def Access.suffixes(+s: String) -> String:
  +x = Access.spec(s)
  Bool.pick(String, Spec.ro(x), ":ro", "") ++ Bool.pick(String, Spec.nocache(x), ":nocache", "")

# The open flags for a use, with 8 for :nocache.
def Access.flags_of(u: Use, +nocache: Bool) -> U32:
  (Access.flags(u) .|. Bool.pick(U32, nocache, 8, 0) : U32)
