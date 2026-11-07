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
