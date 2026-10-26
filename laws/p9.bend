import Base
import ../src/fs/p9.bend as P

# Frozen spec for src/fs/p9.bend (request handling is pinned by
# tests/p9.bend on the simulator's in-memory filesystem).

law p9.errno_enoent:
  {P.P9.linux_errno(2) == 2 : U32}

law p9.errno_enotempty:
  {P.P9.linux_errno(66) == 39 : U32}

law p9.errno_enosys:
  {P.P9.linux_errno(78) == 38 : U32}

law p9.config:
  # tag "share": tag_len 5 (le16) then the bytes
  {P.P9.config("share") == [5, 0, 115, 104, 97, 114, 101] : +List<U32>}
