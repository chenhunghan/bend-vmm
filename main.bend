import Base
import ./host/main.bend as H
import ./host/api.bend as A
import ./host/hvf.bend as Hv
import ./src/vmm/snapdir.bend as Sd
import ./src/vmm/hostfiles.bend as Hf
import ./src/lib/u64.bend as U

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

# Files on the host, for the program that embeds the VMM. Paths are
# taken as given (relative to the working directory), never through a
# symlink at their end; each call answers 0 or an errno unless it says.

# The names in a directory, but . and .. ([] when it cannot be read).
def Fs.ls(+dir: String) -> IO(List<String>):
  Hv.Hvf.ls(dir)

# What path is: kind (0 nothing, 1 a directory, 2 a regular file, 3 a
# symlink, 4 anything else), size in bytes, mtime in seconds since 1970.
def Fs.facts(+path: String) -> IO(Hf.Facts):
  A.Fs.facts(path)

# Replaces a file or symlink at `to`.
def Fs.rename(+from: String, +to: String) -> IO(U32):
  Hv.Hvf.rename(from, to)

# Removes a file (not a directory).
def Fs.remove(+path: String) -> IO(U32):
  Hv.Hvf.remove(path)

# Removes an empty directory.
def Fs.rmdir(+path: String) -> IO(U32):
  Hv.Hvf.rmdir(path)

# mkdir -p with mode for each directory it makes.
def Fs.mkdir_p(+path: String, +mode: U32) -> IO(U32):
  A.Fs.mkdir_p(path, mode)

# Sets path's modification time (seconds since 1970); its access time stays.
def Fs.set_mtime(+path: String, t: U.U64) -> IO(U32):
  A.Fs.set_mtime(path, t)

# The wall clock, in seconds since 1970.
def Fs.now() -> IO(U.U64):
  Hv.Host.now()

# Writes a file's data (fsync) or a directory's entries (fsync_dir) to the
# disk, so a publish (write, fsync, rename, fsync_dir) survives a crash.
def Fs.fsync(+path: String) -> IO(U32):
  A.Fs.fsync(path)

def Fs.fsync_dir(+path: String) -> IO(U32):
  A.Fs.fsync_dir(path)

# Sets path's permission bits (mode & 0o7777), never through a symlink.
def Fs.chmod(+path: String, +mode: U32) -> IO(U32):
  A.Fs.chmod(path, mode)

# True when no directory along path, nor path itself, is a symlink.
def Fs.no_symlinks(+path: String) -> IO(Bool):
  A.Fs.no_symlinks(path)
