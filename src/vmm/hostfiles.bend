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
# byte joined by "-", then ".sock" (host/hvf.c binds and sends to the names
# Bend gives it).
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

# A broadcast's recipients: of Hvf.lan_names' answer (this VM's socket,
# then the names in the LAN directory), every VM's socket but this one's.
def Files.lan_peer(+self: String, +name: String) -> Bool:
  String.ends_with(name, ".sock") && Bool.not(String.eq(name, self))

def Files.lan_peers.keep(keep: Bool, n: String, rest: List<String>) -> List<String>:
  match keep:
    case True{}:
      Con{n, rest}
    case False{}:
      rest

def Files.lan_peers.go(+self: String, names: List<String>) -> List<String>:
  match names:
    case Nil{}:
      []
    case Con{+n, rest}:
      Files.lan_peers.keep(Files.lan_peer(self, n), n, Files.lan_peers.go(self, rest))

def Files.lan_peers(names: List<String>) -> List<String>:
  match names:
    case Nil{}:
      []
    case Con{self, rest}:
      Files.lan_peers.go(self, rest)

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

# Files for a program that embeds the VMM (main.bend's Fs, asked by
# bend-vk8s): what a path is (Hvf.path_facts' words, decoded) and the
# directories `mkdir -p` makes, in order.
type Facts is Data:
  Facts{kind: U32, size: U.U64, mtime: U.U64}

def Files.facts.at(+ws: +List<U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, ws, i), 0)

# kind: 0 nothing, 1 a directory, 2 a regular file, 3 a symlink, 4 else;
# from the mode's file type (st_mode & 0o170000, the same on macOS and
# Linux: 0o040000 a directory, 0o100000 a regular file, 0o120000 a symlink).
def Files.kind(+there: U32, +mode: U32) -> U32:
  +t : U32 = (mode .&. 61440 : U32)
  Bool.pick(U32, U32.is_zero(there), 0,
  Bool.pick(U32, U32.is_eq(t, 16384), 1,
  Bool.pick(U32, U32.is_eq(t, 32768), 2,
  Bool.pick(U32, U32.is_eq(t, 40960), 3, 4))))

# Hvf.path_facts' words: [there, mode, size (hi, lo), mtime (hi, lo)].
def Files.facts(+ws: +List<U32>) -> Facts:
  Facts{Files.kind(Files.facts.at(ws, 0n), Files.facts.at(ws, 1n)), U.U64{Files.facts.at(ws, 2n), Files.facts.at(ws, 3n)}, U.U64{Files.facts.at(ws, 4n), Files.facts.at(ws, 5n)}}

# acc then the directories under it that parts name (empty parts skipped).
def Files.prefixes.with(+acc: String, +p: String) -> String:
  Bool.pick(String, String.is_empty(p), acc, acc ++ "/" ++ p)

def Files.prefixes.go(parts: List<&2, String>, +acc: String) -> List<&2, String>:
  match parts:
    case Nil{}:
      []
    case Con{+p, rest}:
      +next : String = Files.prefixes.with(acc, p)
      List.append(&2, String, Bool.pick(List<&2, String>, String.is_empty(p), [], [next]), Files.prefixes.go(rest, next))

def Files.prefixes.first(parts: List<&2, String>) -> List<&2, String>:
  match parts:
    case Nil{}:
      []
    case Con{+first, rest}:
      List.append(&2, String, Bool.pick(List<&2, String>, String.is_empty(first), [], [first]), Files.prefixes.go(rest, first))

# The directories `mkdir -p path` makes, outermost first: "/a/b" is "/a"
# then "/a/b", "a//b/" is "a" then "a/b".
def Files.prefixes(path: String) -> List<&2, String>:
  Files.prefixes.first(String.split(path, '/'))
