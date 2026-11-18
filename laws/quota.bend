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

# Proposed: an inode cap per share (--share DIR,inodes=N; asked by
# bend-vk8s, security review F4): creates count, removes free, a create
# past the cap is refused.
law quota.makes_create:
  {Q.Quota.makes(V.FsCreate{"f", 420}) == 1 : U32}

law quota.makes_mkdir:
  {Q.Quota.makes(V.FsMkdir{"d", 493}) == 1 : U32}

law quota.makes_symlink:
  {Q.Quota.makes(V.FsSymlink{"l", "f"}) == 1 : U32}

law quota.makes_write:
  {Q.Quota.makes(V.FsWrite{"f", w(0), [1, 2]}) == 0 : U32}

law quota.frees_remove:
  {Q.Quota.frees(V.FsRemove{"f", False{}}) == 1 : U32}

law quota.counts_rename:
  {Q.Quota.counts(V.FsRename{"a", "b"}) == False{} : Bool}

law quota.moved_ok:
  {Q.Quota.moved(V.FsMkdir{"d", 493}, V.FsOk{}) == [1, 0] : +List<U32>}

law quota.moved_failed:
  {Q.Quota.moved(V.FsCreate{"f", 420}, V.FsErr{17}) == [0, 0] : +List<U32>}

law quota.moved_remove:
  {Q.Quota.moved(V.FsRemove{"d", True{}}, V.FsOk{}) == [0, 1] : +List<U32>}

law quota.inodes_none:
  {Q.Quota.inodes_allow(4294967295, 1, 0) == True{} : Bool}

law quota.inodes_fits:
  {Q.Quota.inodes_allow(19, 1, 20) == True{} : Bool}

law quota.inodes_full:
  {Q.Quota.inodes_allow(20, 1, 20) == False{} : Bool}

law quota.inodes_over:
  {Q.Quota.inodes_allow(25, 1, 20) == False{} : Bool}

law quota.inodes_remove_when_full:
  {Q.Quota.inodes_allow(25, 0, 20) == True{} : Bool}
