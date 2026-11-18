import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V

# A share's quota (--share DIR,quota=BYTES; laws/quota.bend): what the
# guest's writes may add to the bytes its files hold. The host counts them
# (approximately: summed at start, moved by each size change); a write that
# would take them past the quota fails with ENOSPC before it happens.
# Growing a file by truncate makes it sparse (no disk), so only writes count.

def Quota.enospc() -> U32:
  28

# The bytes an operation may add: a write's length, nothing for the rest.
def Quota.growth(op: V.FsOp) -> U.U64:
  match op:
    case V.FsWrite{p, off, +bs}:
      U.U64{0, U32.from_nat(List.length(&2, U32, bs))}
    case V.FsWriteRam{p, off, +iovs}:
      U.U64{0, V.Iov.total(iovs)}
    case _:
      U.U64.zero()

# Whether an operation adding growth fits: no quota (0), or the bytes held
# plus growth within it.
def Quota.allows(+usage: U.U64, +growth: U.U64, +quota: U.U64) -> Bool:
  U.U64.is_zero(quota) || U.U64.is_le(U.U64.add(usage, growth), quota)

# A share's inode cap (--share DIR,inodes=N): the entries (files,
# directories, symlinks) it may hold. The host counts them (summed at
# start, moved by each create and remove that succeeds); a create past the
# cap fails with ENOSPC before it happens, so a guest cannot fill the
# host's inodes with empty files. A rename onto an existing name frees one
# the count keeps (it errs high, never low).

# The entries an operation would make: 1 for a file, directory or symlink.
def Quota.makes(op: V.FsOp) -> U32:
  match op:
    case V.FsCreate{p, m}:
      1
    case V.FsMkdir{p, m}:
      1
    case V.FsSymlink{p, t}:
      1
    case _:
      0

# The entries an operation would free: 1 for a remove.
def Quota.frees(op: V.FsOp) -> U32:
  match op:
    case V.FsRemove{p, d}:
      1
    case _:
      0

# Whether an operation changes the count at all (the rest skip it).
def Quota.counts(+op: V.FsOp) -> Bool:
  U32.is_ne((Quota.makes(op) + Quota.frees(op) : U32), 0)

def Quota.done(r: V.FsResult) -> Bool:
  match r:
    case V.FsOk{}:
      True{}
    case _:
      False{}

# What the count moves by once the host answered r: [made, freed], each
# only when the operation succeeded.
def Quota.moved(+op: V.FsOp, r: V.FsResult) -> +List<U32>:
  +ok : Bool = Quota.done(r)
  [Bool.pick(U32, ok, Quota.makes(op), 0), Bool.pick(U32, ok, Quota.frees(op), 0)]

# Whether making n more entries fits: no cap (0), or the count plus n
# within it.
def Quota.inodes_allow(+used: U32, +n: U32, +cap: U32) -> Bool:
  U32.is_zero(cap) || U32.is_zero(n) || (U32.is_le(n, cap) && U32.is_le(used, (cap - n : U32)))
