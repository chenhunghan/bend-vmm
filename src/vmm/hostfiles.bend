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
