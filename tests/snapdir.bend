import Base
import ../src/vmm/snapdir.bend as S
import ./t.bend as T

# src/vmm/snapdir.bend over a sweep: default names sort as their times do
# (day after day for 2000 days from 2023, through leap days, and within a
# day), and are always valid names; metadata survives its text for a range
# of values.

def cmp_of(r: (String & String) & Cmp) -> Cmp:
  match r:
    case (p, c):
      c

def lt(+a: String, +b: String) -> Bool:
  Cmp.is_lt(cmp_of(String.cmp(a, b)))

def days_ok(n: Nat, +t: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      +a = S.Sname.of_time(t)
      +b = S.Sname.of_time((t + 86399 : U32))
      +c = S.Sname.of_time((t + 86400 : U32))
      lt(a, b) && lt(b, c) && S.Sname.valid(a) && days_ok(k, (t + 86400 : U32))

def info_ok(n: Nat, +x: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      +i : S.Info = S.Info{S.Sname.of_time(x), x, U32.show((x / 7 : U32)), (x % 100000 : U32), (x / 3 : U32), "note " ++ U32.show(x)}
      +back : S.Info = S.Sdir.info.parse(S.Sdir.info.text(i))
      String.eq(S.Sdir.info.text(back), S.Sdir.info.text(i)) && info_ok(k, ((x * 1103515245 : U32) + 12345 : U32))

def main() -> IO(Unit):
  do IO<Unit>:
    T.ok("snapdir: 2000 days of default names sort as their times, and are valid names", days_ok(2000n, 1672531200))
    T.ok("snapdir: metadata survives its text (200 values)", info_ok(200n, 7))
