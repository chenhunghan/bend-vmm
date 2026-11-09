import Base
import ../src/fs/contain.bend as C

# Spec for src/fs/contain.bend: the names a share path may hold.

law contain.root:
  {C.Share.rel_ok("") == True{} : Bool}

law contain.nested:
  {C.Share.rel_ok("a/b/c.txt") == True{} : Bool}

law contain.dotdot:
  {C.Share.rel_ok("a/../../etc") == False{} : Bool}

law contain.dot:
  {C.Share.rel_ok("./a") == False{} : Bool}

law contain.empty_component:
  {C.Share.rel_ok("a//b") == False{} : Bool}

law contain.absolute:
  {C.Share.rel_ok("/etc/passwd") == False{} : Bool}

law contain.trailing_slash:
  {C.Share.rel_ok("a/") == False{} : Bool}

law contain.dots_in_name:
  {C.Share.rel_ok("a/..b/c.") == True{} : Bool}
