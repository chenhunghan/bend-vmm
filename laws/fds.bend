import Base
import ../src/net/fds.bend as F

# Spec for src/net/fds.bend: the descriptor budget for guest flows.

law fds.macos:
  {F.Fds.room(1024) == 896 : U32}

law fds.small:
  {F.Fds.room(100) == 50 : U32}

law fds.linux:
  {F.Fds.room(65536) == 65408 : U32}

law fds.none:
  {F.Fds.room(0) == 0 : U32}
