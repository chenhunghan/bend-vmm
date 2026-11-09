import Base

# The shared directory's boundary (laws/contain.bend): which names a guest
# path may hold. A path is relative to the share's root, its components
# separated by "/", none empty, "." or "..". The host walks its directories
# from the share's open root without following any symlink (and never
# follows one in the last component), so a path these names make stays
# inside the share by construction: no host path is ever compared.

def Share.einval() -> U32:
  22

def Share.comp_ok(+c: String) -> Bool:
  Bool.not(String.is_empty(c) || String.eq(c, ".") || String.eq(c, ".."))

def Share.comps_ok(cs: List<&2, String>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Share.comp_ok(c) && Share.comps_ok(rest)

# Whether rel may name something in a share ("" is its root).
def Share.rel_ok(+rel: String) -> Bool:
  String.is_empty(rel) || Share.comps_ok(String.split(rel, '/'))
