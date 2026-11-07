import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/fs/quota.bend as Q

# Spec for src/fs/quota.bend: a share's quota.

def w(x: U32) -> U.U64:
  U.U64{0, x}

law quota.none:
  {Q.Quota.allows(w(4294967295), w(4096), w(0)) == True{} : Bool}

law quota.fits:
  {Q.Quota.allows(w(1000), w(24), w(1024)) == True{} : Bool}

law quota.past:
  {Q.Quota.allows(w(1000), w(25), w(1024)) == False{} : Bool}

law quota.growth_write:
  {Q.Quota.growth(V.FsWrite{"log", w(0), [1, 2, 3]}) == w(3) : U.U64}

law quota.growth_ram:
  {Q.Quota.growth(V.FsWriteRam{"log", w(0), [V.Iov{w(4096), 512}, V.Iov{w(8192), 100}]}) == w(612) : U.U64}

law quota.growth_truncate:
  {Q.Quota.growth(V.FsTruncate{"log", w(1048576)}) == w(0) : U.U64}

law quota.growth_create:
  {Q.Quota.growth(V.FsCreate{"log", 420}) == w(0) : U.U64}
