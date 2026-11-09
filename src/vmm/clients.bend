import Base

# Host clients of the VMM's Unix sockets (laws/clients.bend): the control
# socket (--control) and vsock's (--vsock). A client gets Clients.deadline_ms
# to send its one line, so it cannot hold the listener; a vsock client's
# line names the guest port it wants (Firecracker's convention).

def Clients.deadline_ms() -> U32:
  5000

def Clients.chars(bs: +List<U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, rest}:
      SCon{Char.from_u32(b), Clients.chars(rest)}

# "CONNECT <port>" (a trailing CR or spaces are fine): the port.
def Clients.connect_port.of(+rest: String) -> Maybe<&2, U32>:
  U32.read(String.trim(rest))

def Clients.connect_port(bs: +List<U32>) -> Maybe<&2, U32>:
  +line = Clients.chars(bs)
  Bool.pick(Maybe<&2, U32>, String.starts_with(line, "CONNECT "), Clients.connect_port.of(String.drop(line, 8n)), None{})

# How many connections each listener lets wait (listen's backlog): the
# control socket serves one client at a time, so a few; vsock's and
# --forward's clients come in bursts (a guest's connections, a port a tool
# opens many times).
def Clients.backlog_control() -> U32:
  4

def Clients.backlog_vsock() -> U32:
  16

def Clients.backlog_forward() -> U32:
  64

# With no descriptor left to accept a client, a listener stays readable:
# the host waits this long before it tries again, rather than spinning.
def Clients.full_retry_ms() -> U32:
  100

# The signals the VMM takes (the host's numbers: SIGHUP 1, SIGINT 2,
# SIGTERM 15, the same on macOS and Linux), as a mask (bit n: signal n).
# Each presses the guest's power button (host/main.bend); any other signal
# keeps its default action.
def Clients.signals() -> List<&2, U32>:
  [1, 2, 15]

def Clients.mask(ss: List<&2, U32>) -> U32:
  match ss:
    case Nil{}:
      0
    case Con{s, rest}:
      ((1 << U32.to_nat(s) : U32) .|. Clients.mask(rest) : U32)
