import Base
import ../src/lib/u64.bend as U
import ../src/fs/p9wire.bend as W

# Frozen spec for src/fs/p9wire.bend; expected bytes from an independent
# encoder of the layouts documented in the file.

def w(x: U32) -> U.U64:
  U.U64{0, x}

def version() -> +List<U32>:
  [57, 80, 50, 48, 48, 48, 46, 76]

law p9wire.parse_version:
  {W.P9.parse([21, 0, 0, 0, 100, 255, 255, 0, 32, 0, 0, 8, 0, 57, 80, 50, 48, 48, 48, 46, 76]) == Some{W.P9Msg{65535, W.Tversion{8192, version()}}} : Maybe<&2, W.P9Msg>}

law p9wire.build_version:
  {W.P9.build(65535, W.Rversion{8192, version()}) == [21, 0, 0, 0, 101, 255, 255, 0, 32, 0, 0, 8, 0, 57, 80, 50, 48, 48, 48, 46, 76] : +List<U32>}

law p9wire.parse_walk:
  {W.P9.parse([29, 0, 0, 0, 110, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 3, 0, 101, 116, 99, 5, 0, 104, 111, 115, 116, 115]) == Some{W.P9Msg{1, W.Twalk{0, 1, [[101, 116, 99], [104, 111, 115, 116, 115]]}}} : Maybe<&2, W.P9Msg>}

law p9wire.build_walk:
  {W.P9.build(1, W.Rwalk{[W.Qid{128, 0, w(5)}, W.Qid{0, 0, w(9)}]}) == [35, 0, 0, 0, 111, 1, 0, 2, 0, 128, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0] : +List<U32>}

law p9wire.build_lerror:
  {W.P9.build(3, W.Rlerror{2}) == [11, 0, 0, 0, 7, 3, 0, 2, 0, 0, 0] : +List<U32>}

law p9wire.parse_read:
  {W.P9.parse([23, 0, 0, 0, 116, 4, 0, 1, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0]) == Some{W.P9Msg{4, W.Tread{1, w(10), 100}}} : Maybe<&2, W.P9Msg>}

law p9wire.build_read:
  {W.P9.build(4, W.Rread{[97, 98, 99]}) == [14, 0, 0, 0, 117, 4, 0, 3, 0, 0, 0, 97, 98, 99] : +List<U32>}

law p9wire.build_getattr:
  {W.P9.build(5, W.Rgetattr{W.P9Stat{W.Qid{0, 0, w(9)}, 33188, 501, 20, w(1), w(12), w(8), w(100), w(200), w(300)}}) == [160, 0, 0, 0, 25, 5, 0, 255, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 164, 129, 0, 0, 245, 1, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 44, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] : +List<U32>}

law p9wire.build_readdir:
  {W.P9.build(6, W.Rreaddir{[W.P9Dirent{W.Qid{128, 0, w(5)}, w(1), 4, [101, 116, 99]}]}) == [38, 0, 0, 0, 41, 6, 0, 27, 0, 0, 0, 128, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 3, 0, 101, 116, 99] : +List<U32>}

law p9wire.parse_short:
  {W.P9.parse([11, 0, 0, 0, 100]) == None{} : Maybe<&2, W.P9Msg>}

law p9wire.parse_size_mismatch:
  # the size field says 9 but 7 bytes follow
  {W.P9.parse([9, 0, 0, 0, 120, 1, 0]) == None{} : Maybe<&2, W.P9Msg>}

law p9wire.parse_unknown:
  {W.P9.parse([7, 0, 0, 0, 200, 9, 0]) == Some{W.P9Msg{9, W.Tunknown{200}}} : Maybe<&2, W.P9Msg>}
