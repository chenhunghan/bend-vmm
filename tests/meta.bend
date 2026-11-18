import Base
import ../src/fs/meta.bend as Mt
import ./t.bend as T

# A large .bend-meta loads in time linear in its size (bend-vk8s's nginx
# layer: thousands of records, long names). Meta.pct once decided each
# character with Bool.pick, which builds both of its arguments: two
# recursions a character, so a 60-character name took minutes natively
# (scripts/check-native.sh runs this file compiled).

def name(+i: U32) -> String:
  "lib" ++ U32.show(i) ++ "-%5Bx%5D-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnop.so"

def rec(+i: U32) -> String:
  "name=" ++ name(i) ++ " host=" ++ name(i) ++ " type=f mode=755 uid=0 gid=0 mtime=1684449257.5 ino=7857868317023797249 nlink=2 xattr.user.a=6869\n"

def recs(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+(+k):
      rec(U32.from_nat(k)) ++ recs(k)

def count(ws: +List<U32>) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, 1n), 0)

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_u32("meta: 100 records with 70-character names load", count(Mt.Meta.table("bend-meta 1\n" ++ recs(100n))), 100)
    T.eq_str("meta: a long name decodes", Mt.Meta.pct(name(7)), "lib7-[x]-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnop.so")
