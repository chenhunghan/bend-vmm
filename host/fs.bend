import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ./hvf.bend as H

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

def Fs.decode(+ws: +List<U32>) -> V.FsResult:
  Fs.decode.go(Fs.w(ws, 0n), ws)

def Fs.call(sh: U32, op: U32, p: String, p2: String, a: U.U64, b: U32, bytes: +List<U32>) -> IO(V.FsResult):
  match a:
    case U.U64{ah, al}:
      do IO<V.FsResult>:
        +ws : +List<U32> <- H.Hvf.fs(sh, op, p, p2, ah, al, b, bytes)
        return Fs.decode(ws)

def Host.fs(sh: U32, op: V.FsOp) -> IO(V.FsResult):
  match op:
    case V.FsStat{p}:
      Fs.call(sh, 0, p, "", U.U64.zero(), 0, [])
    case V.FsList{p, from, max}:
      Fs.call(sh, 1, p, "", U.U64.from_u32(from), max, [])
    case V.FsRead{p, off, len}:
      Fs.call(sh, 2, p, "", off, len, [])
    case V.FsWrite{p, off, bs}:
      Fs.call(sh, 3, p, "", off, 0, bs)
    case V.FsCreate{p, mode}:
      Fs.call(sh, 4, p, "", U.U64.zero(), mode, [])
    case V.FsMkdir{p, mode}:
      Fs.call(sh, 5, p, "", U.U64.zero(), mode, [])
    case V.FsRemove{p, dir}:
      Fs.call(sh, 6, p, "", U.U64.zero(), Bool.to_u32(dir), [])
    case V.FsRename{from, to}:
      Fs.call(sh, 7, from, to, U.U64.zero(), 0, [])
    case V.FsTruncate{p, size}:
      Fs.call(sh, 8, p, "", size, 0, [])
    case V.FsChmod{p, mode}:
      Fs.call(sh, 9, p, "", U.U64.zero(), mode, [])
    case V.FsSymlink{p, target}:
      Fs.call(sh, 10, p, target, U.U64.zero(), 0, [])
    case V.FsReadlink{p}:
      Fs.call(sh, 11, p, "", U.U64.zero(), 0, [])
    case V.FsStatfs{}:
      Fs.call(sh, 12, "", "", U.U64.zero(), 0, [])
