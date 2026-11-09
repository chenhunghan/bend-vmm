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

# Proposed: the soft descriptor limit set at startup (Fds.soft).
# macOS (exact, top 1024): a soft limit of 256 or 10240 under an unlimited
# hard limit becomes 1024; a hard limit of 512 caps it.
law fds.soft_macos_up:
  {F.Fds.soft(256, 4294967295, 1024, True{}) == 1024 : U32}

law fds.soft_macos_down:
  {F.Fds.soft(10240, 4294967295, 1024, True{}) == 1024 : U32}

law fds.soft_macos_hard:
  {F.Fds.soft(256, 512, 1024, True{}) == 512 : U32}

# Linux (top 65536): raised to the hard limit, never lowered, and an
# unlimited soft limit stays.
law fds.soft_linux_up:
  {F.Fds.soft(1024, 524288, 65536, False{}) == 65536 : U32}

law fds.soft_linux_keep:
  {F.Fds.soft(100000, 524288, 65536, False{}) == 100000 : U32}

law fds.soft_linux_unlimited:
  {F.Fds.soft(4294967295, 4294967295, 65536, False{}) == 4294967295 : U32}
