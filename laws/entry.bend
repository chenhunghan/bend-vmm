import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/fs/entry.bend as E

# Spec for src/fs/entry.bend: a share's entries and modes as the guest sees them.

def e(n: String, t: U32) -> V.FsEntry:
  V.FsEntry{n, U.U64{0, 7}, t}

# "." and ".." are dropped; a directory, a file and a symlink keep their type.
law entry.view:
  {E.Entry.view([e(".", 4), e("d", 4), e("..", 4), e("f", 8), e("l", 10)]) == [e("d", 4), e("f", 8), e("l", 10)] : List<&2, V.FsEntry>}

# A FIFO (1), a device (2, 6) or a socket (12) is unknown (0).
law entry.other:
  {E.Entry.view([e("p", 1), e("c", 2), e("b", 6), e("s", 12)]) == [e("p", 0), e("c", 0), e("b", 0), e("s", 0)] : List<&2, V.FsEntry>}

# Names that only start with dots are entries.
law entry.dots:
  {E.Entry.view([e("...", 8), e(".x", 8)]) == [e("...", 8), e(".x", 8)] : List<&2, V.FsEntry>}

# A mode keeps its permission bits: 04755 (setuid) is 0755, 01777 (sticky)
# is 0777, 02644 (setgid) is 0644.
law entry.perm_setuid:
  {E.Entry.perm(2541) == 493 : U32}

law entry.perm_sticky:
  {E.Entry.perm(1023) == 511 : U32}

law entry.perm_setgid:
  {E.Entry.perm(1444) == 420 : U32}
