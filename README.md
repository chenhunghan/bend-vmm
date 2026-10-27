# bend-vmm

A virtual machine monitor for arm64, written in
[Bend](https://bend-lang.com). It boots arm64 Linux on Hypervisor.framework
(macOS on Apple Silicon) and on KVM (Linux on arm64).

All of the VMM's logic is pure Bend under `src/`: trap decoding, PSCI, the
device tree, the PL011 UART, the PL031 RTC, the UEFI flash, virtio (blk,
net, console, rng, 9p, vsock, input), the qcow2 disk format, the user-mode
TCP/IP NAT, the console's escape keys, snapshots, and the exit handler that
ties them together. Laws state what each module must do, and proofs check
them, re-checked by a kernel whose soundness is proven in Lean. A simulator
runs the same code on any OS. A thin C layer (`host/`) makes the system
calls: it drives the hypervisor (Hypervisor.framework on macOS, KVM on
Linux, behind one small interface) and moves bulk data between files,
sockets and guest memory where Bend tells it to.

## What it runs

- Linux kernels as `Image` or gzip-compressed `vmlinuz` (Debian, Ubuntu), with
  an initramfs, up to 64 vCPUs (one host thread each), GICv3 and the arch timer
  in Hypervisor.framework.
- Serial console (PL011, `ttyAMA0`) with interactive input; `Ctrl-A x` quits;
  also virtio-console (`hvc0`).
- Networking with no root or entitlements: virtio-net behind a user-mode NAT
  written in Bend (DHCP, DNS, TCP, UDP, ping to the gateway; the host is
  10.0.2.2).
- Host directory sharing over virtio-9p (9P2000.L).
- virtio-vsock to Unix sockets on the host (`--vsock PATH`, Firecracker's
  convention: the guest's connection to host port P reaches `PATH_P`; a host
  client connects to `PATH` and sends `CONNECT <port>` to reach a guest port).
- UEFI boot (`--firmware`): edk2's arm64 firmware (ArmVirtQemu, as QEMU
  uses) runs in place from flash, with its variable store on a CFI flash
  model written back to a `--vars` file, so distribution ISOs and disk images
  boot through their own bootloader (GRUB) and EFI variables persist.
- A graphical console (`--display WxH`): a simple-framebuffer the guest's
  `simpledrm`/fbcon draws on, shown in a macOS window through Metal straight
  from guest memory, with a virtio keyboard and a virtio tablet (absolute
  pointer) fed by the window. The bundled initramfs runs a second shell on
  `tty1` there.
- virtio-blk disks, raw or qcow2 (read-write or read-only, FLUSH): qcow2
  images over backing files (raw or qcow2, up to 8 deep), compressed
  clusters, copy-on-write into new clusters with their reference counts, so
  `qemu-img check` passes on what the guest wrote. virtio-rng, the PL031 RTC.
- Reboot (`reboot` in the guest restarts the VM) and power-off.

## Build and run

Hosts: macOS 15+ on Apple Silicon, or Linux on arm64 with `/dev/kvm`
(kernel 6.7+). Tagged releases publish binaries for both (see Releases below).

To build: Bend 2.0.39 (`curl -fsSL https://bend-lang.com/install.sh | sh`),
and Xcode Command Line Tools on macOS or clang (plus `libx11-dev` for
`--display`) on Linux.

```sh
scripts/build.sh host/main.bend out/bend-vmm          # build (and sign, on macOS)
scripts/guest-assets.sh                               # fetch Ubuntu's arm64 kernel, build a busybox initramfs
out/bend-vmm --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio \
             --mem 1024 --cpus 2 --share ~/some/dir --disk disk.img
```

The guest boots to a busybox shell in about half a second, with networking
up (10.0.2.15 by DHCP; the host is 10.0.2.2) and `--share` mounted at
`/mnt/share`. `poweroff -f` stops it; `Ctrl-A x` quits from the host.
Any arm64 kernel with virtio-mmio and PL011 works; `scripts/guest-assets.sh`
also bundles the modules Ubuntu's kernel needs for virtio-rng, 9p and the RTC.

Options:

| Option | Meaning |
|---|---|
| `--kernel FILE` | Linux `Image` or gzip-compressed `vmlinuz` |
| `--initrd FILE` | initramfs |
| `--cmdline "…"` | kernel command line (default `console=ttyAMA0 earlycon=pl011,0x9000000`) |
| `--mem MiB` | guest RAM (default 512) |
| `--cpus N` | vCPUs (default 1) |
| `--disk A[,B:ro…]` | disk images (raw, or qcow2 by its header) as virtio-blk (`/dev/vda`, `/dev/vdb`, …); `:ro` attaches one read-only |
| `--share DIR` | a host directory over virtio-9p (`mount -t 9p -o trans=virtio,version=9p2000.L share /mnt`) |
| `--payload FILE` | a bare-metal binary entered at the start of RAM |
| `--vsock PATH` | virtio-vsock (guest CID 3) bridged to Unix sockets under PATH |
| `--firmware FILE` | UEFI firmware (`out/uefi/code.fd` from `scripts/uefi-assets.sh`) instead of `--kernel` |
| `--vars FILE` | the UEFI variable store (copy `out/uefi/vars.fd` per VM); without it variables last one run |
| `--display WxH` | a window showing the guest's framebuffer, with a virtio keyboard and tablet (`WxH,headless`: no window, for `screendump`) |
| `--version`, `--help` | the release, the options |
| `--control SOCK` | a Unix socket for management commands (below) |
| `--restore FILE` | start from a snapshot; pass the same `--disk`, `--share`, `--vsock`, `--firmware` and `--vars` it was taken with (a snapshot cannot choose host files by itself) |

Linux (KVM): the same binary builds on Linux arm64 (clang, `libx11-dev` for
`--display`) with `scripts/build.sh`, and runs with `/dev/kvm`; snapshots
included (a snapshot restores on the hypervisor that took it). From a Mac,
`scripts/lima/linux-host.sh [command]` makes
a Lima VM to try it: on M3 and later it nests KVM through
Virtualization.framework; on M1/M2, which cannot nest, QEMU emulates the
CPU's virtualization extensions (slow, but a real KVM host).

UEFI:

```sh
scripts/uefi-assets.sh                # edk2 firmware and a variable store template (Ubuntu's AAVMF), Alpine's ISO
cp out/uefi/vars.fd my-vars.fd
out/bend-vmm --firmware out/uefi/code.fd --vars my-vars.fd --mem 1024 --cpus 2 \
             --disk out/uefi/alpine.iso:ro
```

The firmware waits 5 seconds in its boot manager by default; from Linux,
`efibootmgr -t 0` (or writing `07 00 00 00 00 00` to
`/sys/firmware/efi/efivars/Timeout-8be4df61-93ca-11d2-aa0d-00e098032b8c`)
sets that to 0 for good in the `--vars` file: the firmware then reaches GRUB
in 0.2 s and Alpine its login prompt in about 5 s.

Management: on the console, `Ctrl-A p` pauses or resumes, `Ctrl-A s` writes
`./bend-vmm.snap`, `Ctrl-A x` quits, `Ctrl-A h` lists the keys. Over
`--control`: `echo pause | nc -U SOCK` (also `resume`, `status`,
`snapshot PATH`, `net` (the NAT's connections and flow state),
`powerdown` (presses the guest's power button), `quit`;
with `--display`, `screendump PATH` writes the
screen as a PPM, `type TEXT` types on the virtio keyboard (`\n` is Return),
`pointer X Y` moves the tablet on its 0..32767 scale). A snapshot holds guest RAM (sparse), every vCPU's
registers, the GIC, and the whole device state; `--restore` maps the RAM
copy-on-write, so restoring is immediate. TCP connections through the NAT do
not survive a restore.

Stopping: `SIGTERM` (or `SIGHUP`) presses the guest's power button, the
`KEY_POWER` key of a virtio keyboard every machine has, and gives the guest
10 s to shut down and power off (systemd-logind and acpid do); a second
signal, or `SIGINT`, stops the VMM at once. Disk images are locked while in
use: a second bend-vmm cannot open an image another one writes, while
several can share a read-only image or a qcow2 backing file. A guest's
flush reaches stable storage (on macOS through `F_FULLFSYNC`).

Debugging: `BEND_VMM_TRACE=1` prints every trapped exit, `=2` console input,
interrupt line changes and TCP data held for the guest, `=4` staged
transmit data.

Releases: a tag `v*` builds `bend-vmm` for macOS (signed with a Developer ID
and notarized) and Linux arm64 and publishes both on a GitHub release
(`.github/workflows/release.yml`; the signing secrets are listed there).

## Start time

Measured on an M-series Mac with Ubuntu's 6.8 arm64 kernel:

| Start | Time |
|---|---|
| VMM up to the first guest instruction | ~30 ms |
| Cold boot to the busybox shell (default options, full boot log) | ~0.55 s |
| Cold boot, `quiet`, to `/init` | ~0.33 s |
| `--restore` of a booted snapshot to a responsive shell | ~20-40 ms |

For the fastest start, boot once with `--control SOCK`, take
`echo snapshot base.snap | nc -U SOCK`, and start later VMs with
`--restore base.snap`: guest RAM maps copy-on-write from the file, so nothing
is read or zeroed up front. A trapped exit costs ~3 µs (`tests/guest/spam.S`):
the vCPU thread and the Bend event loop hand requests over with a short spin
before sleeping, register writes ride along with the next run, console
output is batched, and the host clock is read only while the RTC alarm is
armed.

## Speed

`scripts/bench.sh` measures boot, exits, disk, network, 9p, snapshots and
the VMM's memory, and compares with an earlier run
(`scripts/bench.sh --compare out/bench/<file>.tsv`). On an M2 Pro (2 vCPUs,
the guest pinned to vCPU 0 where device interrupts land):

| Metric | |
|---|---|
| exit (a trapped UART store, end to end) | ~3 µs |
| disk sequential read / write (1 MiB, O_DIRECT) | ~290 / ~200 MB/s |
| disk 4 KiB random read, QD1 | ~45k IOPS (~21 µs) |
| network download / upload through the NAT | ~430 / ~80 MB/s |
| 9p read / write | ~170 / ~30 MB/s |

Bulk data never passes through Bend: devices name the guest memory a
request uses (`V.Iov` pieces) and the host moves the bytes (disk, 9p,
network). The NAT does TCP flow control (the guest's window, scaled), keeps
data until the guest acknowledges it and sends it again when the guest may
have dropped it (its window shrank, or a duplicate ACK), and hands the guest
64 KiB segments (GUEST_TSO4) whose payload goes from a host buffer straight
into guest memory; the guest's big segments (HOST_TSO4) are staged on the
host and sent from there.

`scripts/soak.sh [MINUTES]` runs the guest through disk, 9p, network and
memory traffic, checking every byte read back, pausing and resuming it every
minute, and fails on a mismatch, a hang, or the VMM's memory growing past
20%.

## Security

The guest is treated as hostile; so are snapshot files and disk images from
elsewhere. What holds today:

- The shared folder: every path stays under `--share` (`..`, absolute names
  and symlinks in a directory part are refused; the last part of a path is
  never followed as a symlink, for reads, writes, truncation and listings).
  Only regular files are read or written. The guest cannot set setuid,
  setgid or sticky bits.
- Snapshots: `--restore` opens only the host files the command line names
  (and refuses a snapshot taken with others); the devices it decodes must be
  the ones opened. Snapshots, screendumps and the control and vsock sockets
  are this user's alone (mode 0600), and never written through a symlink.
- Disk images: locked while in use; `:ro` disks and qcow2 backing files open
  read-only, and a backing file must be a regular file. A qcow2 image's
  backing file name is trusted as `qemu-img` trusts it: do not attach
  images from untrusted sources.
- Not yet: the VMM is not sandboxed (it runs with your user's rights), and
  the guest's network reaches what your host reaches (10.0.2.2 is the
  host's loopback).

## How it is verified

| Level | Command | Where |
|---|---|---|
| Typing, termination, laws, proofs | `bend PROOF.bend` | anywhere |
| Tests on the simulator (500+) | `scripts/check.sh` | anywhere, CI |
| Same tests compiled native, on all threads | `scripts/check-native.sh` | macOS / Linux with clang |
| Proofs re-checked by the Lean-proven kernel | `VERDICT=1 scripts/check.sh` | CI (`verdict` job) |
| Real guests on the host's hypervisor | `scripts/check-host.sh` | macOS (Hypervisor.framework), Linux arm64 (KVM) |
| The same on a Linux KVM host from a Mac | `scripts/lima/linux-host.sh 'CHECK_SLOW=5 SKIP_NATIVE=1 scripts/check-host.sh'` | a Lima VM |
| The same on an emulated KVM host (QEMU with EL2) | `scripts/ci/emulated-kvm.sh` | CI (`host-linux` job) |

`scripts/check-host.sh` boots a bare-metal payload, then Linux (1 and 4 CPUs),
then a busybox userspace that runs an in-guest test suite: disk reads and
writes, entropy, timers, interrupts, console input, reboot, networking, 9p,
vsock both ways, pause/resume, snapshot/restore, and the display (a
screendump, keys typed into the framebuffer console, tablet events read from
the guest's evdev), UEFI: edk2 booting Alpine's ISO, an EFI variable
written from Linux surviving a reboot, and qcow2: images over a raw backing
file, compressed and fresh, read and written by the guest, then checked by
`qemu-img check` and read back by `qemu-img`.

## Layout

- `src/` the pure VMM; `laws/` its spec; `proofs/` the proofs
- `host/` the system calls (C: Hypervisor.framework and KVM backends, files,
  sockets, the window) and the driver (`host/main.bend`)
- `scripts/` builds, checks (`check.sh`, `check-host.sh`), `bench.sh`,
  `soak.sh`, release and CI helpers
- `tests/` simulator tests; `tests/guest/` guest payloads and the in-guest suite
- `docs/DESIGN.md` architecture, verification ladder, roadmap
- `AGENTS.md` rules for contributors (human or AI)
