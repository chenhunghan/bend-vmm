import Base
import ./host/main.bend as H

# bend-vmm as a BendHub package (import bend-vmm@<version>/main.bend as V).
# V.Vmm.run(prog, flags) runs the VMM inside another Bend program: prog is
# how that program starts the VMM again (["vk8s", "vmm"]), flags are the
# VMM's options (bend-vmm --help). One VM per process. The program must be
# built for macOS with the Hypervisor.framework entitlement
# (scripts/build-mac.sh signs it) or for Linux arm64 with /dev/kvm.

@unsafe def Vmm.run(+prog: List<String>, +flags: List<String>) -> IO(Unit):
  H.Vmm.run(prog, flags)

@unsafe def main() -> IO(Unit):
  H.main()
