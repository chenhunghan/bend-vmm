import Base

# Tiny test helpers: each prints one PASS or FAIL line; scripts/check.sh fails
# the run on any FAIL line.

def ok(name: String, cond: Bool) -> IO(Unit):
  match cond:
    case True{}:
      IO.print("PASS " ++ name)
    case False{}:
      IO.print("FAIL " ++ name)

def same(name: String, cond: Bool, got: String, want: String) -> IO(Unit):
  match cond:
    case True{}:
      IO.print("PASS " ++ name)
    case False{}:
      IO.print("FAIL " ++ name ++ ": got " ++ got ++ ", want " ++ want)

def eq_u32(name: String, +got: U32, +want: U32) -> IO(Unit):
  same(name, U32.is_eq(got, want), U32.show(got), U32.show(want))

def eq_str(name: String, +got: String, +want: String) -> IO(Unit):
  same(name, String.eq(got, want), got, want)
