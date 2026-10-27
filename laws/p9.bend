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

# Proposed: guest numbers are bounded. A guest sets only the permission bits
# 0777 on host files (no setuid, setgid or sticky); Treaddir's count is at
# most msize - 24; the fid table holds at most 4096 fids (a new one past that
# is EMFILE 24, a bound one may be rebound); dropping a fid removes every
# binding of it.
law p9.mode_drops_special_bits:
  {P.P9.mode(36863) == 511 : U32}

law p9.mode_keeps_permissions:
  {P.P9.mode(33188) == 420 : U32}

law p9.readdir_count_clamped:
  {P.P9.readdir_count(100, 8192) == 76 : U32}

law p9.readdir_count_small:
  {P.P9.readdir_count(8192, 40) == 40 : U32}

law p9.readdir_count_tiny_msize:
  {P.P9.readdir_count(10, 100) == 0 : U32}

law p9.emfile:
  {P.P9.emfile() == 24 : U32}

law p9.max_fids:
  {P.P9.max_fids() == 4096n : Nat}

law p9.room_full:
  {P.P9.room(False{}, 4096n) == False{} : Bool}

law p9.room_rebind:
  {P.P9.room(True{}, 4096n) == True{} : Bool}

law p9.room_below_max:
  {P.P9.room(False{}, 4095n) == True{} : Bool}

law p9.fid_room_new:
  {P.P9.fid_room([P.Fid{1, "", False{}}], 7) == True{} : Bool}

law p9.fid_drop:
  {P.P9.fid_drop([P.Fid{1, "a", False{}}, P.Fid{2, "b", True{}}, P.Fid{1, "c", False{}}], 1) == [P.Fid{2, "b", True{}}] : +List<P.Fid>}
