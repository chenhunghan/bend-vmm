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
