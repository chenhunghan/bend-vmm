import Base
import ../src/fs/readonly.bend as R
import ../src/vmm/abi.bend as V
import ../src/lib/u64.bend as U

# Spec for src/fs/readonly.bend: a read-only share refuses every change.

# Proposed: read-only shares (--share DIR,ro), asked by bend-vk8s for image
# layers shared by many VMs.
law readonly.mark:
  {R.Ro.mark(2, True{}) == 258 : U32}

law readonly.mark_rw:
  {R.Ro.mark(2, False{}) == 2 : U32}

law readonly.index:
  {R.Ro.index(258) == 2 : U32}

law readonly.write:
  {R.Ro.refuses(256, V.FsWrite{"a", U.U64{0, 0}, [1]}) == True{} : Bool}

law readonly.write_ram:
  {R.Ro.refuses(257, V.FsWriteRam{"a", U.U64{0, 0}, []}) == True{} : Bool}

law readonly.create:
  {R.Ro.refuses(256, V.FsCreate{"a", 420}) == True{} : Bool}

law readonly.mkdir:
  {R.Ro.refuses(256, V.FsMkdir{"d", 493}) == True{} : Bool}

law readonly.remove:
  {R.Ro.refuses(256, V.FsRemove{"a", False{}}) == True{} : Bool}

law readonly.rename:
  {R.Ro.refuses(256, V.FsRename{"a", "b"}) == True{} : Bool}

law readonly.truncate:
  {R.Ro.refuses(256, V.FsTruncate{"a", U.U64{0, 0}}) == True{} : Bool}

law readonly.chmod:
  {R.Ro.refuses(256, V.FsChmod{"a", 511}) == True{} : Bool}

law readonly.symlink:
  {R.Ro.refuses(256, V.FsSymlink{"l", "/etc"}) == True{} : Bool}

law readonly.reads:
  {R.Ro.refuses(256, V.FsRead{"a", U.U64{0, 0}, 4096}) == False{} : Bool}

law readonly.read_ram:
  {R.Ro.refuses(256, V.FsReadRam{"a", U.U64{0, 0}, []}) == False{} : Bool}

law readonly.stat:
  {R.Ro.refuses(256, V.FsStat{"a"}) == False{} : Bool}

law readonly.list:
  {R.Ro.refuses(256, V.FsList{"", 0, 100}) == False{} : Bool}

law readonly.writable_share:
  {R.Ro.refuses(1, V.FsWrite{"a", U.U64{0, 0}, [1]}) == False{} : Bool}

law readonly.xattr_read:
  {R.Ro.refuses(256, V.FsXattr{"a", "security.capability"}) == False{} : Bool}
