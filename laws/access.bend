import Base
import ../src/disk/access.bend as A

# Spec for src/disk/access.bend: which refusals attach a disk read-only.

law access.denied:
  {A.Access.fallback(13) == True{} : Bool}

law access.not_permitted:
  {A.Access.fallback(1) == True{} : Bool}

law access.read_only_fs:
  {A.Access.fallback(30) == True{} : Bool}

law access.missing:
  {A.Access.fallback(2) == False{} : Bool}

law access.busy:
  {A.Access.fallback(16) == False{} : Bool}

law access.opened:
  {A.Access.fallback(0) == False{} : Bool}

# Proposed: how each use opens an image (Access.flags: 1 read only,
# 2 exclusive lock, 4 regular file only).
law access.writer:
  {A.Access.flags(A.Access.use(False{})) == 2 : U32}

law access.reader:
  {A.Access.flags(A.Access.use(True{})) == 1 : U32}

law access.backing:
  {A.Access.flags(A.Backing{}) == 5 : U32}
