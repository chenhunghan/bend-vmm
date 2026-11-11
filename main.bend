import Base
import ./host/main.bend as H
import ./host/api.bend as A
import ./src/vmm/snapdir.bend as Sd

# bend-vmm as a BendHub package (import bend-vmm@<version>/main.bend as V).
# V.Vmm.run(prog, flags) runs the VMM inside another Bend program: prog is
# how that program starts the VMM again (["vk8s", "vmm"]), flags are the
# VMM's options (bend-vmm --help). One VM per process. The program must be
# built for macOS with the Hypervisor.framework entitlement
# (scripts/build-mac.sh signs it) or for Linux arm64 with /dev/kvm.

@unsafe def Vmm.run(+prog: List<String>, +flags: List<String>) -> IO(Unit):
  H.Vmm.run(prog, flags)

# A VM folder (bend-vmm create): runs its VM (vm.conf, its control socket
# DIR/control.sock), or runs it from one of its snapshots, saving the
# current state first (bend-vmm restore).
@unsafe def Vmm.run_dir(+prog: List<String>, +dir: String) -> IO(Unit):
  A.Vmm.run_dir(p => f => H.Vmm.run(p, f), prog, dir)

@unsafe def Vmm.restore(+prog: List<String>, +vm: String, +name: String) -> IO(Unit):
  A.Vmm.restore(p => f => H.Vmm.run(p, f), prog, vm, name)

# Calls on a VM from another process. vm is its folder or its --control
# socket; each answers a Result whose error (A.Err) tells no socket, not
# running and timeout apart. Snapshots need a folder (src/vmm/snapdir.bend:
# DIR/snapshots/NAME). Nothing prints or ends the process.
def Vmm.status(+vm: String) -> IO(Result<&1, &1, A.Err, A.Status>):
  A.Vmm.status(vm)

def Vmm.pause(+vm: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.pause(vm)

def Vmm.resume(+vm: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.resume(vm)

def Vmm.stop(+vm: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.stop(vm)

def Vmm.powerdown(+vm: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.powerdown(vm)

def Vmm.ctl(+vm: String, +line: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.ctl(vm, line)

def Vmm.create(+dir: String, +flags: List<&2, String>) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.create(dir, flags)

def Vmm.snapshot(+vm: String, +name: String, +note: String) -> IO(Result<&1, &1, A.Err, Sd.Info>):
  A.Vmm.snapshot(vm, name, note)

def Vmm.snapshots(+vm: String) -> IO(Result<&1, &1, A.Err, List<&2, Sd.Info>>):
  A.Vmm.snapshots(vm)

def Vmm.snapshot_rm(+vm: String, +name: String) -> IO(Result<&1, &1, A.Err, String>):
  A.Vmm.snapshot_rm(vm, name)

def Vmm.prune(+vm: String, +keep: U32) -> IO(Result<&1, &1, A.Err, List<&2, String>>):
  A.Vmm.prune(vm, keep)

@unsafe def main() -> IO(Unit):
  H.main()
