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

# How each use opens an image (Access.flags: 1 read only,
# 2 exclusive lock, 4 regular file only).
law access.writer:
  {A.Access.flags(A.Access.use(False{})) == 2 : U32}

law access.reader:
  {A.Access.flags(A.Access.use(True{})) == 1 : U32}

law access.backing:
  {A.Access.flags(A.Backing{}) == 5 : U32}

# A --disk entry's options as suffixes, in any order, each once.
law access.spec_plain:
  {A.Access.spec("a.img") == A.Spec{"a.img", False{}, False{}} : A.Spec}

law access.spec_both:
  {A.Access.spec("d/a.img:nocache:ro") == A.Spec{"d/a.img", True{}, True{}} : A.Spec}

law access.spec_suffixes:
  {A.Access.suffixes("a.img:ro:nocache") == ":ro:nocache" : String}

# :nocache adds 8 to the open flags.
law access.flags_nocache:
  {A.Access.flags_of(A.Writer{}, True{}) == 10 : U32}
