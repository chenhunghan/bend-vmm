import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ./hvf.bend as H
import ../src/fs/quota.bend as Qt
import ../src/fs/contain.bend as Ct
import ../src/fs/listing.bend as Ls
import ../src/fs/entry.bend as En
import ../src/host/fdcache.bend as Fc

# Shared directories: V.FsOp on the host (host/hvf.c, "Shared directories").

def Fs.w(+ws: +List<U32>, i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, i), 0)

def Fs.w64(+ws: +List<U32>, i: Nat) -> U.U64:
  +i = i
  U.U64{Fs.w(ws, i), Fs.w(ws, 1n+i)}

def Fs.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, rest}:
      SCon{Char.from_u32(b), Fs.chars(rest)}

# Entries: (ino hi, ino lo, type, name length, name bytes)*.
def Fs.entries(fuel: Nat, ws: +List<U32>) -> +List<V.FsEntry>:
  match fuel:
    case 0n:
      []
    case 1n+f:
      match ws:
        case Nil{}:
          []
        case Con{+h, rest}:
          +rest = rest
          +len = U32.to_nat(Fs.w(rest, 2n))
          name = Fs.chars(List.take(&2, U32, List.drop(&2, U32, rest, 3n), len))
          V.FsEntry{name, U.U64{h, Fs.w(rest, 0n)}, Fs.w(rest, 1n)} <> Fs.entries(f, List.drop(&2, U32, rest, Nat.add(3n, len)))

def Fs.attr(+ws: +List<U32>) -> V.FsAttr:
  V.FsAttr{Fs.w(ws, 1n), Fs.w(ws, 2n), Fs.w(ws, 3n), Fs.w(ws, 4n), Fs.w64(ws, 5n), Fs.w64(ws, 7n), Fs.w64(ws, 9n), Fs.w64(ws, 11n), Fs.w64(ws, 13n), Fs.w64(ws, 15n)}

def Fs.ename(e: V.FsEntry) -> String:
  match e:
    case V.FsEntry{n, i, k}:
      n

def Fs.decode.go(+tag: U32, +ws: +List<U32>) -> V.FsResult:
  +rest = List.drop(&2, U32, ws, 1n)
  Bool.pick(V.FsResult, U32.is_eq(tag, 0), V.FsOk{},
  Bool.pick(V.FsResult, U32.is_eq(tag, 2), V.FsGotAttr{Fs.attr(ws)},
  Bool.pick(V.FsResult, U32.is_eq(tag, 3), V.FsBytes{rest},
  Bool.pick(V.FsResult, U32.is_eq(tag, 4), V.FsCount{Fs.w(ws, 1n)},
  Bool.pick(V.FsResult, U32.is_eq(tag, 5), V.FsEntries{Fs.entries(List.length(&2, U32, rest), rest)},
  Bool.pick(V.FsResult, U32.is_eq(tag, 6), V.FsLink{Fs.chars(rest)},
  Bool.pick(V.FsResult, U32.is_eq(tag, 7), V.FsStatfsOk{Fs.w(ws, 1n), Fs.w64(ws, 2n), Fs.w64(ws, 4n), Fs.w64(ws, 6n), Fs.w64(ws, 8n), Fs.w64(ws, 10n)},
    V.FsErr{Fs.w(ws, 1n)})))))))

# (tags 8 and 9 are 3 and 4 when the host opened a file for the operation)
def Fs.tag(+t: U32) -> U32:
  Bool.pick(U32, U32.is_eq(t, 8), 3, Bool.pick(U32, U32.is_eq(t, 9), 4, t))

def Fs.decode(+ws: +List<U32>) -> V.FsResult:
  Fs.decode.go(Fs.tag(Fs.w(ws, 0n)), ws)

# A file the host opened for an operation takes the slot Bend picks
# (src/host/fdcache.bend: the least recently used).
def Fs.placed(opened: Bool, +ws: +List<U32>) -> IO(V.FsResult):
  match opened:
    case False{}:
      IO.pure(V.FsResult, Fs.decode(ws))
    case True{}:
      do IO<V.FsResult>:
        +st : +List<U32> <- H.Hvf.fdc_stamps()
        _ : U32 <- H.Hvf.fdc_put(Fc.Fdc.victim(st))
        return Fs.decode(ws)

# A host operation on a share: its paths' names vetted first
# (src/fs/contain.bend: no empty part, no "." or ".."; the host walks them
# without following a symlink).
def Fs.run(sh: U32, +op: U32, p: String, p2: String, a: U.U64, b: U32, bytes: +List<U32>) -> IO(V.FsResult):
  match a:
    case U.U64{ah, al}:
      do IO<V.FsResult>:
        +ws : +List<U32> <- H.Hvf.fs(sh, (op .|. Bool.pick(U32, Fc.Fdc.invalidates(op), 256, 0) : U32), p, p2, ah, al, b, bytes)
        +t : U32 = Fs.w(ws, 0n)
        Fs.placed(U32.is_eq(t, 8) || U32.is_eq(t, 9), ws)

def Fs.call(+sh: U32, +op: U32, +p: String, +p2: String, +a: U.U64, +b: U32, +bytes: +List<U32>) -> IO(V.FsResult):
  Bool.pick(IO(V.FsResult), Ct.Share.rel_ok(p) && (U32.is_ne(op, 7) || Ct.Share.rel_ok(p2)),
    Fs.run(sh, op, p, p2, a, b, bytes), IO.pure(V.FsResult, V.FsErr{Ct.Share.einval()}))

# The page of a listing the guest asked for (src/fs/entry.bend: which
# entries, with what type; src/fs/listing.bend: in what order).
def Fs.paged(r: V.FsResult, +from: U32, +max: U32) -> V.FsResult:
  match r:
    case V.FsEntries{es}:
      V.FsEntries{Ls.Listing.page(En.Entry.view(es), from, max)}
    case _:
      r

def Host.fs.do(sh: U32, op: V.FsOp) -> IO(V.FsResult):
  match op:
    case V.FsStat{p}:
      Fs.call(sh, 0, p, "", U.U64.zero(), 0, [])
    case V.FsList{p, from, max}:
      IO.bind(V.FsResult, V.FsResult, Fs.call(sh, 1, p, "", U.U64.zero(), 0, []), r => IO.pure(V.FsResult, Fs.paged(r, from, max)))
    case V.FsRead{p, off, len}:
      Fs.call(sh, 2, p, "", off, len, [])
    case V.FsWrite{p, off, bs}:
      Fs.call(sh, 3, p, "", off, 0, bs)
    case V.FsCreate{p, mode}:
      Fs.call(sh, 4, p, "", U.U64.zero(), En.Entry.perm(mode), [])
    case V.FsMkdir{p, mode}:
      Fs.call(sh, 5, p, "", U.U64.zero(), En.Entry.perm(mode), [])
    case V.FsRemove{p, dir}:
      Fs.call(sh, 6, p, "", U.U64.zero(), Bool.to_u32(dir), [])
    case V.FsRename{from, to}:
      Fs.call(sh, 7, from, to, U.U64.zero(), 0, [])
    case V.FsTruncate{p, size}:
      Fs.call(sh, 8, p, "", size, 0, [])
    case V.FsChmod{p, mode}:
      Fs.call(sh, 9, p, "", U.U64.zero(), En.Entry.perm(mode), [])
    case V.FsSymlink{p, target}:
      Fs.call(sh, 10, p, target, U.U64.zero(), 0, [])
    case V.FsReadlink{p}:
      Fs.call(sh, 11, p, "", U.U64.zero(), 0, [])
    case V.FsStatfs{}:
      Fs.call(sh, 12, "", "", U.U64.zero(), 0, [])
    case V.FsReadRam{p, off, iovs}:
      Fs.call(sh, 13, p, "", off, 0, H.Host.iovs(iovs))
    case V.FsWriteRam{p, off, iovs}:
      Fs.call(sh, 14, p, "", off, 0, H.Host.iovs(iovs))

# A write past the share's quota (src/fs/quota.bend) fails with ENOSPC
# before it happens.
def Host.fs.quota(ok: Bool, sh: U32, op: V.FsOp) -> IO(V.FsResult):
  match ok:
    case True{}:
      Host.fs.do(sh, op)
    case False{}:
      IO.pure(V.FsResult, V.FsErr{Qt.Quota.enospc()})

def Host.fs.grows(none: Bool, +growth: U.U64, +sh: U32, op: V.FsOp) -> IO(V.FsResult):
  match none:
    case True{}:
      Host.fs.do(sh, op)
    case False{}:
      do IO<V.FsResult>:
        +ws : +List<U32> <- H.Hvf.share_usage(sh)
        Host.fs.quota(Qt.Quota.allows(Fs.w64(ws, 0n), growth, Fs.w64(ws, 2n)), sh, op)

def Host.fs(+sh: U32, +op: V.FsOp) -> IO(V.FsResult):
  +g = Qt.Quota.growth(op)
  Host.fs.grows(U.U64.is_zero(g), g, sh, op)
