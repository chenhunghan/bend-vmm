import Base
import ../lib/u64.bend as U

# The console log (--console-log PATH,max=BYTES[,keep=N]; laws/conlog.bend):
# the VMM writes the guest's console to PATH itself and, once it holds max
# bytes, renames it to PATH.1 (PATH.1 to PATH.2, ..., the oldest past keep
# dropped) and starts a new one. A guest that prints without end then takes
# at most (keep + 1) * max bytes of the host's disk.

# Whether the log of size bytes rotates (max 0: never).
def Log.rotate(+size: U.U64, +max: U.U64) -> Bool:
  Bool.not(U.U64.is_zero(max)) && U.U64.is_le(max, size)

# A rotation's renames, in order (keep N): PATH.(N-1) to PATH.N, ..., PATH.1
# to PATH.2, then PATH to PATH.1; with keep 0, none (the log starts over).
# The host then opens a new, empty PATH (Hvf.console_reopen). A rename that
# fails (no such file yet) is no error.
type Rename is Data:
  Rename{from: String, to: String}

def Log.name(+path: String, +i: U32) -> String:
  path ++ "." ++ U32.show(i)

def Log.nat(bits: Nat, +x: U32) -> Nat:
  match bits:
    case 0n:
      0n
    case 1n+k:
      Nat.add(Nat.double(Log.nat(k, (x >> 1n : U32))), Bool.pick(Nat, U32.is_eq((x .&. 1 : U32), 1), 1n, 0n))

# The renames of the numbered logs, from PATH.n up (n down to 1).
def Log.moves.go(n: Nat, +path: String) -> List<Rename>:
  match n:
    case 0n:
      []
    case 1n+(+k):
      +i = (U32.from_nat(k) + 1 : U32)
      Con{Rename{Log.name(path, i), Log.name(path, (i + 1 : U32))}, Log.moves.go(k, path)}

def Log.moves.of(n: Nat, +path: String) -> List<Rename>:
  match n:
    case 0n:
      []
    case 1n+k:
      List.append(&1, Rename, Log.moves.go(k, path), [Rename{path, Log.name(path, 1)}])

# (keep is at most 99: Cli.conlog.)
def Log.moves(+path: String, +keep: U32) -> List<Rename>:
  Log.moves.of(Log.nat(16n, keep), path)

# Console output on stdout (the host's flusher writes it): output waits at
# most batch_us so a guest printing byte by byte costs no write per byte,
# and past backlog bytes waiting (nobody draining stdout: a stalled pipe)
# more is dropped rather than growing the VMM without bound.
def Out.batch_us() -> U32:
  1000

def Out.backlog() -> U32:
  16777216
