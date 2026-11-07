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
