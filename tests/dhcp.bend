import Base
import ../src/lib/bytes.bend as B
import ../src/net/dhcp.bend as D
import ./t.bend as T

# The DHCP server past the laws: other xids, flags and MACs are echoed;
# options in any order, with padding and with extra options, are understood;
# malformed messages and options lists get no answer.

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def show(r: Maybe<&2, +List<U32>>) -> String:
  match r:
    case None{}:
      "none"
    case Some{bs}:
      List.show(~&2, ~U32, ~U32.show, bs)

# A request: op, xid (4 bytes), flags (2 bytes), chaddr (16 bytes), then the
# cookie and the options. ciaddr, sname and file carry junk the reply drops.
def msg(op: U32, xid: +List<U32>, flags: +List<U32>, chaddr: +List<U32>, opts: +List<U32>) -> +List<U32>:
  cat([op, 1, 6, 3], cat(xid, cat([0, 9], cat(flags, cat([10, 0, 2, 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], cat(chaddr, cat(List.replicate(U32, 192n, 7), cat([99, 130, 83, 99], opts))))))))

def xid() -> +List<U32>:
  [222, 173, 190, 239]

def mac() -> +List<U32>:
  [2, 0, 0, 170, 187, 204, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

def req(opts: +List<U32>) -> +List<U32>:
  msg(1, xid(), [0, 0], mac(), opts)

# The answer to req(..) carrying message type t.
def want(t: U32) -> String:
  show(Some{cat([2, 1, 6, 0], cat(xid(), cat([0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 0, 0, 0, 0], cat(mac(), cat(B.Bytes.zeros(192n), [99, 130, 83, 99, 53, 1, t, 54, 4, 10, 0, 2, 2, 51, 4, 0, 1, 81, 128, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 3, 255])))))})

def check(name: String, got: Maybe<&2, +List<U32>>, want: String) -> IO(Unit):
  T.eq_str(name, show(got), want)

def main() -> IO(Unit):
  do IO<Unit>:
    check("dhcp offer echoes xid, flags 0 and a 16-byte chaddr", D.Dhcp.reply(req([53, 1, 1, 255])), want(2))
    check("dhcp ack echoes xid and chaddr", D.Dhcp.reply(req([53, 1, 3, 255])), want(5))
    check("dhcp flags are echoed", D.Dhcp.reply(msg(1, [1, 2, 3, 4], [128, 0], [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [53, 1, 1, 255])), show(Some{cat([2, 1, 6, 0, 1, 2, 3, 4, 0, 0, 128, 0, 0, 0, 0, 0, 10, 0, 2, 15, 10, 0, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], cat(B.Bytes.zeros(192n), [99, 130, 83, 99, 53, 1, 2, 54, 4, 10, 0, 2, 2, 51, 4, 0, 1, 81, 128, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 3, 255]))}))
    check("dhcp pads before the type", D.Dhcp.reply(req([0, 0, 0, 53, 1, 1, 255])), want(2))
    check("dhcp pads around options", D.Dhcp.reply(req([0, 61, 7, 1, 2, 0, 0, 170, 187, 204, 0, 0, 53, 1, 3, 0, 255, 0, 0])), want(5))
    check("dhcp type after other options", D.Dhcp.reply(req([61, 7, 1, 2, 0, 0, 170, 187, 204, 12, 3, 102, 111, 111, 55, 4, 1, 3, 6, 15, 53, 1, 1, 255])), want(2))
    check("dhcp request with extra options", D.Dhcp.reply(req([53, 1, 3, 50, 4, 10, 0, 2, 15, 54, 4, 10, 0, 2, 2, 12, 3, 102, 111, 111, 55, 4, 1, 3, 6, 15, 57, 2, 2, 64, 255])), want(5))
    check("dhcp option with a 53 inside its data", D.Dhcp.reply(req([12, 3, 53, 1, 7, 53, 1, 3, 255])), want(5))
    check("dhcp options without an end", D.Dhcp.reply(req([53, 1, 1])), want(2))
    check("dhcp first type wins", D.Dhcp.reply(req([53, 1, 3, 53, 1, 1, 255])), want(5))
    check("dhcp no options", D.Dhcp.reply(req([])), "none")
    check("dhcp only end", D.Dhcp.reply(req([255])), "none")
    check("dhcp type after end", D.Dhcp.reply(req([255, 53, 1, 1])), "none")
    check("dhcp type without a length", D.Dhcp.reply(req([53])), "none")
    check("dhcp type without a value", D.Dhcp.reply(req([53, 1])), "none")
    check("dhcp type of length 0", D.Dhcp.reply(req([53, 0, 255])), "none")
    check("dhcp type of length 2", D.Dhcp.reply(req([53, 2, 1, 1, 255])), "none")
    check("dhcp option overruns the message", D.Dhcp.reply(req([12, 200, 102, 111, 111, 53, 1, 1, 255])), "none")
    check("dhcp option without a length", D.Dhcp.reply(req([0, 12])), "none")
    check("dhcp decline", D.Dhcp.reply(req([53, 1, 4, 255])), "none")
    check("dhcp nak", D.Dhcp.reply(req([53, 1, 6, 255])), "none")
    check("dhcp inform", D.Dhcp.reply(req([53, 1, 8, 255])), "none")
    check("dhcp type 0", D.Dhcp.reply(req([53, 1, 0, 255])), "none")
    check("dhcp reply op", D.Dhcp.reply(msg(2, xid(), [0, 0], mac(), [53, 1, 1, 255])), "none")
    check("dhcp op 0", D.Dhcp.reply(msg(0, xid(), [0, 0], mac(), [53, 1, 1, 255])), "none")
    check("dhcp bad cookie", D.Dhcp.reply(List.set(&2, U32, req([53, 1, 1, 255]), 238n, 84)), "none")
    check("dhcp no cookie", D.Dhcp.reply(List.take(&2, U32, req([]), 236n)), "none")
    check("dhcp 239 bytes", D.Dhcp.reply(List.take(&2, U32, req([]), 239n)), "none")
    check("dhcp empty", D.Dhcp.reply([]), "none")
