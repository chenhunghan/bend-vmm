import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ../arm64/kvmexit.bend as Kx
import ./layout.bend as X

# An x86_64 KVM exit as the VMM sees it (host/hvf.c's x86 hvf_run reports
# KVM's facts as words: kind 2000 + KVM's exit reason, then its fields):
#   2006  MMIO: [length, is a write, address (hi, lo), stored value (hi, lo)]
#         -> XMem: the machine's data abort (Kx.KvmExit.mmio) at the bus
#            address X86.to_bus gives
#   2002  port IO: [is an OUT, size, port, count, value]
#         -> XIo (the value of an OUT; a string OUT of count > 1 reports
#            its first element)
#   2008  shutdown (a triple fault): -> XReset
#   2     a signal (a kick): -> XMem of a cancel
# Anything else is XMem of an unknown exit (the machine logs and stops).

type XExit is Data:
  XMem{exit: V.RawExit}
  XIo{write: Bool, port: U32, size: U32, value: U32}
  XReset{}

def XExit.mmio(ws: +List<U32>) -> XExit:
  match ws:
    case Con{+len, Con{wr, Con{ah, Con{al, Con{dh, Con{dl, rest}}}}}}:
      +bus = X.X86.to_bus(U.U64{ah, al})
      XMem{Kx.KvmExit.mmio([len, wr, U.U64.hi(bus), U.U64.lo(bus), dh, dl])}
    case _:
      XMem{V.UnknownExit{4294967295}}

def XExit.io(ws: +List<U32>) -> XExit:
  match ws:
    case Con{out, Con{size, Con{port, Con{count, Con{v, rest}}}}}:
      XIo{U32.is_ne(out, 0), port, size, v}
    case _:
      XMem{V.UnknownExit{4294967295}}

def XExit.kind(+kind: U32, +ws: +List<U32>) -> XExit:
  Bool.pick(XExit, U32.is_eq(kind, 2006), XExit.mmio(ws),
  Bool.pick(XExit, U32.is_eq(kind, 2002), XExit.io(ws),
  Bool.pick(XExit, U32.is_eq(kind, 2008), XReset{},
  Bool.pick(XExit, U32.is_eq(kind, 2), XMem{V.Canceled{}}, XMem{V.UnknownExit{kind}}))))

# The words of Hvf.vcpu(.., Op.run(), ..) on an x86_64 host.
def XExit.decode(ws: +List<U32>) -> XExit:
  match ws:
    case Nil{}:
      XMem{V.UnknownExit{4294967295}}
    case Con{+kind, rest}:
      XExit.kind(kind, rest)
