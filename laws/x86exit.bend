import Base
import ../src/vmm/abi.bend as V
import ../src/arm64/kvmexit.bend as Kx
import ../src/x86/xexit.bend as E

# Spec for src/x86/xexit.bend: KVM's x86 exits as the VMM sees them.

# OUT of one byte 65 to port 1016
law x86exit.out:
  {E.XExit.decode([2002, 1, 1, 1016, 1, 65]) == E.XIo{True{}, 1016, 1, 65} : E.XExit}

# IN of two bytes from port 112
law x86exit.in:
  {E.XExit.decode([2002, 0, 2, 112, 1, 0]) == E.XIo{False{}, 112, 2, 0} : E.XExit}

# a 4-byte store of 7 to virtio slot 3 reaches the machine at its bus address
law x86exit.mmio_moves:
  {E.XExit.decode([2006, 4, 1, 0, 3489662464, 0, 7]) == E.XMem{Kx.KvmExit.mmio([4, 1, 0, 167773696, 0, 7])} : E.XExit}

law x86exit.shutdown_resets:
  {E.XExit.decode([2008]) == E.XReset{} : E.XExit}

law x86exit.signal_cancels:
  {E.XExit.decode([2]) == E.XMem{V.Canceled{}} : E.XExit}

law x86exit.other:
  {E.XExit.decode([2017]) == E.XMem{V.UnknownExit{2017}} : E.XExit}

law x86exit.short_io:
  {E.XExit.decode([2002, 1]) == E.XMem{V.UnknownExit{4294967295}} : E.XExit}

law x86exit.empty:
  {E.XExit.decode([]) == E.XMem{V.UnknownExit{4294967295}} : E.XExit}
