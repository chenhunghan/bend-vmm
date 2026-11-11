import Base
import ../lib/u64.bend as U

# What the VMM makes on the host, and where it may (laws/hostfiles.bend).
#
# Modes: everything the VMM creates on the host is this user's alone: the
# control and vsock sockets, the LAN socket, the console log, a screen dump
# and a snapshot (the guest's whole RAM) are 0600, the LAN directory 0700.
#
# Listening on a path (--control, --vsock): the host reports what the path
# holds (Hvf.sock_facts: nothing, a socket, or anything else) and whether a
# process answers on it. Nothing there: bind. A socket no one answers on (a
# VMM that ended without removing it): replace it. A socket someone answers
# on (a running VMM): refuse, rather than take it over. Anything else (a
# file, a directory, a symlink): refuse, and never remove it.
#
# The LAN directory (--lan DIR) is the boundary between VMs: it is made
# (0700) when missing, and trusted only when it is a directory (not a
# symlink to one), this user's, and no one else may read, write or enter it
# (no group or other permission bits). Then only this user's VMs reach
# each other.

def Files.private() -> U32:
  384  # 0600

def Files.private_dir() -> U32:
  448  # 0700

type Listen is Data:
  LBind{}
  LReplace{}
  LInUse{}
  LNotSocket{}

# kind: 0 nothing, 1 a socket, 2 anything else (as lstat sees it, so a
# symlink is anything else); live: a process accepted a connection on it.
def Files.listen.sock(live: Bool) -> Listen:
  match live:
    case True{}:
      LInUse{}
    case False{}:
      LReplace{}

def Files.listen(+kind: U32, live: Bool) -> Listen:
  Bool.pick(Listen, U32.is_eq(kind, 0), LBind{}, Bool.pick(Listen, U32.is_eq(kind, 1), Files.listen.sock(live), LNotSocket{}))

# Why a listen was refused, for the error message; "" when it may go on.
def Files.listen.why(l: Listen) -> String:
  match l:
    case LBind{}:
      ""
    case LReplace{}:
      ""
    case LInUse{}:
      "a running VMM listens there"
    case LNotSocket{}:
      "it exists and is not a socket"

def Files.listen.replace(l: Listen) -> Bool:
  match l:
    case LReplace{}:
      True{}
    case _:
      False{}

# kind: 0 nothing, 1 a directory, 2 anything else (lstat); mine: this
# user's; perm: its permission bits.
def Files.dir_trusted(+kind: U32, mine: Bool, +perm: U32) -> Bool:
  U32.is_eq(kind, 1) && mine && U32.is_zero((perm .&. 63 : U32))

# A VM's socket in the LAN directory: its MAC, two lowercase hex digits a
# byte joined by "-", then ".sock" (host/hvf.c names the sockets it sends to
# the same way).
def Files.hex2(+b: U32) -> String:
  SCon{U.U64.hex_digit(((b >> 4n : U32) .&. 15 : U32)), SCon{U.U64.hex_digit((b .&. 15 : U32)), ""}}

def Files.mac.go(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, Nil{}}:
      Files.hex2(b)
    case Con{b, rest}:
      Files.hex2(b) ++ "-" ++ Files.mac.go(rest)

def Files.lan_sock(+mac: +List<U32>) -> String:
  Files.mac.go(mac) ++ ".sock"

# The program a guest reset starts again (Hvf.reexec): this executable as
# the system names it (Hvf.exe_path; "" when it cannot), else the first
# argument as given, found from the working directory; "" when there is
# neither, and the reset fails.
def Files.exec_path(+sys: String, +argv0: String) -> String:
  Bool.pick(String, String.is_empty(sys), argv0, sys)

# A socket path's bytes (UTF-8, as the host passes it to bind).
def Files.utf8_len(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, rest}:
      +x = Char.to_u32(c)
      (Bool.pick(U32, U32.is_lt(x, 128), 1, Bool.pick(U32, U32.is_lt(x, 2048), 2, Bool.pick(U32, U32.is_lt(x, 65536), 3, 4))) + Files.utf8_len(rest) : U32)

# Whether a Unix socket can be bound at path: its bytes fit the address's
# path field, which holds max of them and the closing 0 (Hvf.sock_path_max:
# 103 on macOS, 107 on Linux). Checked before listening, so a long path is
# an error that says so.
def Files.sock_path_fits(+path: String, +max: U32) -> Bool:
  U32.is_le(Files.utf8_len(path), max)

def Files.sock_path_why(+path: String, +max: U32) -> String:
  "the path is too long for a socket (" ++ U32.show(Files.utf8_len(path)) ++ " bytes; at most " ++ U32.show(max) ++ ")"
