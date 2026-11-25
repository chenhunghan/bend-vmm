# bend-vmm

A virtual machine monitor for arm64 and x86_64, written in
[Bend](https://bend-lang.com). It boots arm64 Linux on Hypervisor.framework
(macOS on Apple Silicon) and on KVM (Linux on arm64), and x86_64 Linux on
KVM (Linux on x86_64).

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

- Linux kernels as `Image`, gzip-compressed `vmlinuz` (Debian, Ubuntu) or an
  EFI zboot `vmlinuz` with a gzip payload (Alpine's, Fedora's), with an
  initramfs (compressed or not: the kernel unpacks it), up to 64 vCPUs (one host thread each), GICv3 and the arch timer
  in Hypervisor.framework.
- Serial console (PL011, `ttyAMA0`) with interactive input; `Ctrl-A x` quits;
  also virtio-console (`hvc0`).
- Networking with no root or entitlements: virtio-net behind a user-mode NAT
  written in Bend (DHCP, DNS, TCP, UDP, ping to the gateway; the host is
  10.0.2.2), and TCP port forwarding from the host into the guest
  (`--forward 2222:22`, like QEMU's `hostfwd`: `ssh -p 2222 127.0.0.1`
  reaches the guest's sshd).
- VM-to-VM networking with no root or entitlements: `--lan DIR,ip=…` gives
  a VM a second NIC on a LAN shared by every VM naming the same directory
  (one Unix datagram socket per VM, named by its MAC; frames go from guest
  memory to the peer's socket, broadcasts to all, no switch process). ARP,
  any TCP or UDP port, VXLAN; each VM's own VMM answers its DHCP with the
  address given, so it keeps it across restarts. The NAT NIC stays the
  default route.
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
  `qemu-img check` passes on what the guest wrote. A qcow2 image with
  internal snapshots (`qemu-img snapshot -l`) is attached read-only (said on
  stderr): its tables are the snapshots' too. virtio-rng, the PL031 RTC.
- Reboot (`reboot` in the guest restarts the VM) and power-off.

## Build and run

Hosts: macOS 15+ on Apple Silicon, or Linux on arm64 with `/dev/kvm`
(kernel 6.7+). Tagged releases publish binaries for both (see Releases below).

To build: Bend 2.0.40 (`curl -fsSL https://bend-lang.com/install.sh | sh`),
and Xcode Command Line Tools on macOS or clang and `libx11-dev` (headers
only) on Linux. A Linux binary loads libX11 only when `--display` opens a
window, so it runs on headless servers without it.

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
| `--kernel FILE` | Linux `Image`, gzip-compressed `vmlinuz`, or an EFI zboot `vmlinuz` whose payload is gzip |
| `--initrd FILE` | initramfs |
| `--cmdline "…"` | kernel command line (default `console=ttyAMA0 earlycon=pl011,0x9000000`) |
| `--mem MiB` | guest RAM (default 512) |
| `--cpus N` | vCPUs (default 1) |
| `--disk A[,B:ro…]` | disk images (raw, or qcow2 by its header) as virtio-blk (`/dev/vda`, `/dev/vdb`, …); `:ro` attaches one read-only, and so is an image you may not write (said on stderr); `:nocache` (with `:ro` or alone, any order) keeps the image's blocks out of the host's page cache, since the guest caches them already (macOS `F_NOCACHE`; Linux `O_DIRECT` for the guest's aligned transfers) |
| `--share DIR[,quota=SIZE][,inodes=N][,tag=NAME][,ro][,meta]` | a host directory over virtio-9p (`mount -t 9p -o trans=virtio,version=9p2000.L share /mnt`); repeatable (up to 8), each share its own device mounted by its tag (default `share`, then `share1`, ...); with a quota (bytes, or K, M, G) the guest's writes past it fail with ENOSPC (its files' sizes are counted, approximately); with `inodes=N` (K, M, G scale it by 1024s) a create, mkdir or symlink that would take the share past N entries fails with ENOSPC (its entries are counted at start, then moved by each create and remove), so a guest cannot exhaust the host's inodes with empty files; `ro` makes it read-only: every write, create, mkdir, remove, rename, chmod, truncate and symlink fails with EROFS whatever the guest does; `meta` (read-only too) presents Linux metadata from each directory's `.bend-meta` (owner, mode with setuid/setgid/sticky, file type including devices and FIFOs, device numbers, nanosecond mtime, inode and link count, extended attributes such as `security.capability` and `trusted.overlay.opaque`, and a host name apart from the guest's), so container image layers kept on a macOS volume work as overlayfs lower directories; the format is in src/fs/meta.bend |
| `--console-log PATH,max=SIZE[,keep=N]` | the guest's console goes to PATH instead of stdout and rotates at about SIZE (PATH.1 … PATH.N, N 1 by default), so a guest cannot fill the host's disk with it |
| `--payload FILE` | a bare-metal binary entered at the start of RAM |
| `--vsock PATH` | virtio-vsock (guest CID 3) bridged to Unix sockets under PATH |
| `--lan DIR,ip=A.B.C.D/N[,mac=…]` | a second NIC (`eth1`) on a LAN with every other VM given the same DIR (this user's, mode 0700): the VMM answers its guest's DHCP with that address (a lease that never ends; no router, so the NAT NIC keeps the default route); without `mac=` the MAC is 52:54:01 and the address's last three bytes; checksum and TSO offload (MTU 2022), so every VM on one LAN must run the same bend-vmm version |
| `--forward [ADDR:]HP:GP[,…]` | TCP port forwarding: the host listens on ADDR (default `127.0.0.1`; `0.0.0.0` for every interface) port HP, and each client is connected to the guest's port GP (from 10.0.2.2); repeatable, at most 16; a port already in use stops the VMM at startup |
| `--firmware FILE` | UEFI firmware (`out/uefi/code.fd` from `scripts/uefi-assets.sh`) instead of `--kernel` |
| `--vars FILE` | the UEFI variable store (copy `out/uefi/vars.fd` per VM); without it variables last one run |
| `--display WxH` | a window showing the guest's framebuffer, with a virtio keyboard and tablet (`WxH,headless`: no window, for `screendump`) |
| `--version`, `--help` | the release, the options |
| `--control SOCK` | a Unix socket for management commands (below) |
| `--pack NAME` | a pack: one read-only virtio-blk disk, empty at start, that host files join while the VM runs (`pack add PATH` below); the guest finds it by its serial, NAME (1 to 20 of `A-Z a-z 0-9 . _ -`, at `/sys/block/vdX/serial`) |
| `--restore FILE` | start from a snapshot; pass the same `--disk`, `--share`, `--vsock`, `--firmware` and `--vars` it was taken with (a snapshot cannot choose host files by itself); `--forward` comes from this command line, not the snapshot |

Linux (KVM): the same binary builds on Linux arm64 (clang, `libx11-dev`)
with `scripts/build.sh`, and runs with `/dev/kvm`; snapshots
included (a snapshot restores on the hypervisor that took it).

x86_64 (KVM on Linux x86_64): the same sources build on an x86_64 Linux
host and boot x86_64 Linux guests: a bzImage (`--kernel`, the 64-bit boot
protocol: 2.12 or later) with the same devices, options and control
commands (the virtio devices, the NAT, `--lan`, `--forward`, 9p and its
quota, vsock, the balloon, `--console-log`, disks with `:ro`, `:nocache`,
qcow2 and discard). The serial console is COM1 (`console=ttyS0`, the
default there), the clock the CMOS RTC; the machine is described by ACPI
(hardware-reduced: the virtio-mmio devices, COM1 and the clock in the DSDT;
power-off and reset through the FADT), and KVM's in-kernel local APICs,
IOAPIC and PIT handle interrupts and timers, so the guest needs
`CONFIG_ACPI` and `CONFIG_VIRTIO_MMIO` (Alpine's `linux-virt` has both).
Snapshots work as on arm64 (pause, snapshot, restore, VM folders, disk
snapshots, incremental snapshots); a snapshot holds KVM's x86 state
(registers, FPU, MSRs, local APICs, IOAPIC and PICs, PIT, clock) as
src/x86/layout.bend plans it, and restores on an x86_64 KVM host. Not there
yet: `--display`, `--firmware` and `--payload`.
`scripts/guest-assets-x86.sh` fetches Alpine's x86_64 kernel and builds the
test userspace; CI runs `scripts/check-host.sh` on GitHub's x86_64 runners,
which have KVM (the `x86` workflow). From a Mac,
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
`snapshot PATH`, `hibernate PATH`, `status json` (`{"state":"running"}`), `balloon MiB|auto`, `net` (the NAT's connections and flow state),
`pack add PATH` and `pack drop OFFSET` (with `--pack`, below),
`powerdown` (presses the guest's power button), `quit`;
with `--display`, `screendump PATH` writes the
screen as a PPM, `type TEXT` types on the virtio keyboard (`\n` is Return),
`pointer X Y` moves the tablet on its 0..32767 scale). A snapshot holds guest RAM (sparse), every vCPU's
registers, the GIC, and the whole device state; `--restore` maps the RAM
copy-on-write, so restoring is immediate. A snapshot is written to a file
of its own next to PATH and renamed over it, so a failed write keeps what
PATH held, and a restored VM may snapshot over the file it came from. TCP
connections through the NAT do not survive a restore.

`hibernate PATH` is for a VM that sits idle: it pauses the VM and leaves it
paused (`status json` says `"hibernated":true` beside `"state":"paused"`
until it resumes; `bend-vmm status` says hibernated), writes its RAM to a file at PATH as a snapshot would (no disk
copies), and maps guest RAM from that file, so the VM's memory leaves the
host (a 1 GiB guest holding 300 MiB: 400 -> 5 MiB of physical footprint on
macOS, in 0.25 s). The file is removed at once: RAM keeps it open, its
space comes back at the next snapshot or hibernate or when the VM exits,
and a crash leaves nothing behind. `resume` continues the VM where it was
(its connections, shares and forwards with it); the pages it touches come
back from the file. The next `hibernate` writes only what changed since
(0.13 s for 20 MiB): macOS clones the last file (APFS) and writes the
changed chunks; Linux writes the pages that changed into the same file in
place (found in /proc/self/pagemap), on any file system, ext4 included. The file is not a snapshot: nothing restores from it.

Discard (TRIM): a writable disk offers virtio-blk DISCARD, so what the guest
frees (`fstrim`, `mount -o discard`, `blkdiscard`) goes back to the host: the
VMM punches holes in a raw image (whole 4 KiB blocks; they read as zeros),
and in a qcow2 image lets go of whole clusters that are its alone (their
entries read as zeros, their counts drop to 0, their host clusters become
holes; `qemu-img check` stays clean). A cluster with a count above 1 loses
one reference, and a compressed one a reference to each host cluster its
bytes span (the last one out frees it). A version 2 image over a backing
file keeps its clusters (it has no zero flag). New
writes to a qcow2 image take freed clusters again before growing the file.

Write zeroes: a writable raw image also offers virtio-blk WRITE_ZEROES, so
the guest's zeroing (ext4's zero-out, `fallocate` on the device) never
writes zeros it can free instead: with UNMAP the whole 4 KiB blocks become
holes (the space goes back to the host), without it the range is zeroed
and stays allocated (Linux `FALLOC_FL_ZERO_RANGE`). A qcow2 image keeps
DISCARD alone.

Space the guest freed but never trimmed: `bend-vmm sparsify [IMG...]
[--vm DIR]` gives back the free space of a stopped VM's ext4 file systems
(on the whole disk, or in MBR or GPT partitions). It opens each image as a
writer would, so a running VM's disk is refused; reads the superblock,
group descriptors and block bitmaps (src/disk/ext4free.bend decides where
to punch); and punches every free 4 KiB block. A file system not cleanly
unmounted (or with errors, a journal to replay or META_BG) is skipped. Raw
images only for now; other file systems are left alone.

Disk snapshots: a snapshot also keeps each writable `--disk` image as it was,
next to it (`PATH.GEN.disk0`, ...: a copy-on-write clone on APFS, btrfs or
XFS, which costs only the blocks the guest changes later; a full copy on
other file systems). `--restore PATH --disk IMG` sets IMG back to that
moment from the copy, which is only read, so any snapshot can be restored,
again and in any order:

```
echo "snapshot s1.snap" | nc -U vm.sock     # disk and memory as of now
echo "snapshot s2.snap" | nc -U vm.sock     # ... and later
bend-vmm --restore s1.snap --disk vm.img    # vm.img is back at s1
bend-vmm --restore s2.snap --disk vm.img    # then at s2
```

Restoring replaces IMG's current contents (snapshot first to keep them).
`:ro` disks need no copy; shared folders (`--share`) are live host
directories and are not part of a snapshot. Taking a snapshot over PATH
removes the copies of the snapshot PATH held. Keep a snapshot's copies
with it when moving it.

Stopping: `SIGTERM` (or `SIGHUP`) presses the guest's power button, the
`KEY_POWER` key of a virtio keyboard every machine has, and gives the guest
10 s to shut down and power off (systemd-logind and acpid do); a second
signal, or `SIGINT`, stops the VMM at once. Disk images are locked while in
use: a second bend-vmm cannot open an image another one writes, while
several can share a read-only image or a qcow2 backing file. A guest's
flush reaches stable storage (on macOS through `F_FULLFSYNC`).

Debugging: `BEND_VMM_TRACE=1` prints every trapped exit, `=2` console input,
interrupt line changes and TCP data held for the guest, `=4` staged
transmit data, `=8` shared-folder reads and writes (bits add up).

Releases: a tag `v*` builds `bend-vmm` for macOS (signed with a Developer ID
and notarized) and Linux arm64 and publishes both on a GitHub release
(`.github/workflows/release.yml`; the signing secrets are listed there).

## Packs: host files as one growing disk

`--pack NAME` gives the guest a read-only virtio-blk disk that starts empty
(bend-vk8s keeps its container image layers there: one squashfs image per
layer, loop-mounted, a large virtio-blk read where a 9p share's are 4 KiB
pages). `pack add PATH` on the control socket opens the file read-only (as
`--disk PATH:ro` would), places it at the disk's end on a 1 MiB boundary,
grows the disk (the guest sees the new size at once: a config change) and
answers `OFFSET LENGTH` in bytes. In the guest, with busybox:

```sh
dev=$(for b in /sys/block/vd*; do [ "$(cat $b/serial)" = NAME ] && echo /dev/${b##*/}; done)
losetup -r -o OFFSET /dev/loop0 $dev && mount -t squashfs -o ro /dev/loop0 /mnt/layer
```

Past a file's end its slot reads as zeros. `pack drop OFFSET` (once the
guest has unmounted it) ends the entry: its slot then fails to read, its file
is closed, and the slot is never handed out again, so the guest's cache of
the disk can never show one file's bytes for another; the disk never
shrinks. Files are opened on demand into 32 host descriptors (entry n in
slot n mod 32), and a file opened again must be the one added (device,
inode, size, modification time): one changed since reads as an I/O error.
`status json` lists the pack (`"pack":{"name":…,"size":…,"entries":[{"offset":…,"length":…,"path":…,"live":…}]}`).
A snapshot or hibernate keeps the table; a restore opens every live file
again and fails, naming it, when one is missing or changed. Reading all of
a 96 MiB squashfs layer's files (337 MB) cold, the reader on vCPU 1:
1.55-1.83 s from the pack and 1.95-2.03 s over a 9p share on macOS;
1.5-2.7 s from the pack and 8.6-9.0 s over 9p on nested arm64 KVM.

## Memory give-back

Every VM has a virtio-balloon device with free page reporting
(VIRTIO_BALLOON_F_FREE_PAGE_REPORTING; `--balloon off` leaves it out, and
`--balloon free-page-reporting` is accepted for older command lines): a Linux guest
(CONFIG_VIRTIO_BALLOON, CONFIG_PAGE_REPORTING; tested with Ubuntu's 6.8)
reports the memory it frees, a few seconds after it frees it, and the VMM
hands it back to the host. Freeing 1 GiB in a 2 GiB guest takes the VMM from
about 1.1 GiB to about 180 MiB resident. On macOS the reported range is
unmapped from the guest, replaced by fresh pages and mapped again (the
memory leaves the process at once; the guest reads zeros there next); on
Linux it is `madvise(MADV_DONTNEED)` (zeros, or the snapshot's contents for
RAM mapped from a snapshot). Only whole 16 KiB blocks are released (a
macOS page; on a 64 KiB-page Linux host, the whole pages inside). A guest
with 4 KiB pages frees memory in 4 KiB pieces, so on fragmented memory
much of it cannot come back to a 16 KiB-page Mac: in a test, about 400 MB
of free guest memory stayed with the host. `page_reporting.page_reporting_order=2`
on the guest's command line reports 16 KiB blocks (the default is 2 or 4
MiB), and a guest kernel with 16 KiB pages (CONFIG_ARM64_16K_PAGES)
releases in whole host pages. The
device goes last, so other devices keep their slots; a snapshot restores
with or without it as it was taken. A guest's page cache counts as used:
`echo 1 > /proc/sys/vm/drop_caches` in the guest frees it for reporting.

The host can also take memory back on demand: `balloon MiB` on the control
socket sets how much the guest should give to the balloon (`balloon 0`
gives it all back); the guest frees that much (dropping cache first) and
the VMM releases each 16 KiB block once all of its pages are in the
balloon. `status json` then reads
`{"state":"running","balloon":{"target_mib":1024,"actual_mib":1024,"kept_mib":0}}`:
`status json` also reports `"ram":{"resident_mib":…,"compressed_mib":…}`:
what of guest RAM the host holds (resident, and in macOS's compressor),
and `"exits":[{"cpu":0,"vtimer":…,"mmio":…},…]`: each vCPU's exits so far
by kind (`wfi`, `hvc`, `sysreg`, `mmio`, `vtimer`, `canceled` for a kick,
`io`, `hlt`, …; `ec_N` or `kvm_N` for the rest; counts wrap at 2^32), to
see what an idle guest costs;
the VMM's footprint is that plus its own memory (a few MiB). On macOS a
page of guest RAM the VMM itself writes (a disk read, a received packet,
a shared-folder read, the kernel it loads) is charged to it twice, once
for the guest's mapping and once for its own, until its own mapping of
that page is replaced: every 2 s the VMM maps what it wrote again onto
itself (the same memory), so a guest's page cache is charged once. Between
two of those a burst of disk reads can show more.
`kept_mib` is what of the balloon the host could not release (pages of
16 KiB blocks only partly in it). A 4 KiB-page guest whose free memory is
fragmented gives the balloon its scattered single pages first, and those
stay charged to the host (`bench frag` in the test guest shows it: 200 MiB
in the balloon, 200 MiB kept). Compaction in the guest does not fix that
by itself (it moves balloon pages into other single-page holes); a
16 KiB-page guest kernel avoids it, and so does `balloon 0`, compaction
(`echo 1 > /proc/sys/vm/compact_memory`), then the balloon again. The
device offers VIRTIO_BALLOON_F_DEFLATE_ON_OOM, so a guest short of
memory takes pages back from the balloon instead of failing.

By default the balloon is also automatic (`--balloon auto`;
`--balloon free-page-reporting` keeps reporting alone): the device offers
its stats queue (VIRTIO_BALLOON_F_STATS_VQ), the VMM reads the guest's free
memory every 2 s (from 30 s after it starts), and moves the target so the guest keeps a floor free
(256 MiB, or a tenth of its RAM) and the balloon holds at most half of it,
with hysteresis: it grows only when 96 MiB more than the floor is free
(leaving 64 MiB above it) and shrinks only below the floor, so a guest
whose free memory moves by tens of MiB does not make it chase.
That brings back memory free page reporting misses: Linux reports a zone
again only after enough pages were freed there, so memory freed and taken
again can sit free for hours (a Kubernetes control plane with 900 MB free
kept all 2 GiB of its RAM on the host). A burst past what is left
free takes pages back from the balloon as it goes (a 1.4 GiB write into
a 2 GiB guest: 1.3 GB/s, against 4.1 GB/s with no balloon; nothing is
killed). `balloon MiB` sets a target by hand and stops the automatic
balloon; `balloon auto` starts it again. `--balloon auto,max=PCT` (10 to
90) lets the balloon hold up to PCT percent of the RAM instead of half: an
idle 2 GiB guest's balloon then fills to 1.5 GiB, and the same 1.4 GiB burst
takes 4.8 s instead of 4.3 s. When the guest takes pages back from the
balloon on its own (DEFLATE_ON_OOM), the target drops at once to 256 MiB
below what the balloon holds, rather than at the next poll. The policy is
src/virtio/balauto.bend.

## VM folders and snapshots

A VM can live in a folder: its options in `vm.conf`, its disks beside them,
its snapshots in `snapshots/`, its control socket in it while it runs. The
commands find it by the folder (`--vm DIR`, default the current one), so no
socket path is needed:

```
bend-vmm create web --kernel Image --initrd initrd.cpio --mem 1024 --disk disk.img
cd web                                # relative paths in vm.conf are the folder's
bend-vmm run                          # runs the VM here (control socket: control.sock)

bend-vmm snapshot before-upgrade      # (another terminal) memory and disks, now
bend-vmm snapshot --note "it works"   # named by the time: 2026-11-11-081052
bend-vmm snapshots                    # oldest first, with parents and sizes: what
                                      # each holds on its own (disk copies share
                                      # blocks with the disk until it changes)
bend-vmm restore before-upgrade       # saves the current state first, stops the VM,
                                      # runs from the snapshot (memory and disks)
bend-vmm restore before-restore-2026-11-11-081530   # ... which undoes it
bend-vmm snapshot-rm NAME; bend-vmm prune --keep 5
bend-vmm sparsify                     # (stopped) its disks' unused ext4 space back
bend-vmm status | pause | resume | stop | powerdown
```

Each snapshot is a folder, `snapshots/NAME/`: `memory`, a copy of each
writable disk (`disk0`, ...: copy-on-write on APFS, btrfs and XFS) and
`info`, written whole and then renamed into place. A restore takes the host
files from `vm.conf` (a snapshot never chooses them) and never writes a
snapshot's copies, so any snapshot can be restored again, in any order. A
snapshot of a stopped VM keeps its disks only; restoring it boots on them.
Shared folders are not part of a snapshot.

Snapshots are incremental: after one is written, the running VM's memory
maps it (copy-on-write), so what the guest has not written since is clean
file data the host may drop (a 1 GiB VM went from 452 MB to 6 MB of
physical footprint right after a snapshot), and the next snapshot starts as
a clone of it and writes only the memory written since (20 MiB written: a
29 MiB snapshot in 0.07 s, against 397 MiB). On APFS, btrfs and XFS the
clone shares the unchanged blocks, and `bend-vmm snapshots` shows what each
snapshot holds on its own: the space removing it gives back. The latest
snapshot backs the running VM, so removing it frees its space only at the
next snapshot or when the VM stops; never change a snapshot file in place.

`vm.conf` holds one option per
line, as on the command line (`--cmdline console=ttyAMA0 quiet`; `#`
comments); `bend-vmm --help` lists the commands.

## As a library

`main.bend` at the repository's root is a BendHub package (MIT):
`import 0x51718d1816cd36f20955e9590377c5e5/main.bend as V` (bend-vmm as of
2c3aaa9, x86_64 guests on KVM, per-vCPU exit counts in status json, host file calls (Fs), tagged read-only and meta shares with inode caps, LAN TSO, hibernate (in place on Linux; status json says hibernated), --balloon auto,max=PCT, EFI zboot kernels, device interrupts on the vCPU that issued the request (macOS), --pack disks; each publish of a change has a new hash), then `V.Vmm.run(prog, flags)` runs the VMM inside another Bend
program: `prog` is how that program starts the VMM again (on a guest reset,
and in a snapshot's saved command line), e.g. `["vk8s", "vmm"]`, and `flags`
are the options above. One VM per process (the host layer's state is the
process's). `V.Vmm.run_dir(prog, dir)` and `V.Vmm.restore(prog, dir, name)`
run a VM folder's VM. From another process, typed calls take a VM's folder or
its `--control` socket and answer a `Result` (nothing prints or exits):
`V.Vmm.status` (running, paused or stopped, and the forwards), `pause`,
`resume`, `stop`, `powerdown`, `ctl`, `create`, `snapshot`, `snapshots`,
`snapshot_rm` and `prune`; the error tells no socket, not running and a
timeout apart (host/api.bend). `V.Fs` has the host file calls such a
program needs, so it adds no C of its own: `ls`, `facts` (kind, size,
mtime; never through a symlink), `rename`, `remove`, `rmdir`, `mkdir_p`,
`set_mtime`, `fsync`, `fsync_dir`, `chmod`, `no_symlinks` and `now`;
each answers 0 or an errno (host/files_smoke.bend
uses them all). On macOS the program needs the Hypervisor.framework entitlement
(`scripts/build.sh your.bend out/your` builds and signs it).

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
| disk sequential read / write (1 MiB, O_DIRECT; the host's page cache) | ~2800 / ~1300 MB/s |
| disk 4 KiB random read, QD1 | ~45-50k IOPS (~20 µs) |
| TCP download / upload through the NAT (1 MiB reads and writes) | ~650 / ~590 MB/s |
| the same with busybox `wget` / `dd \| nc` in the guest | ~500-650 / ~80 MB/s |
| 9p read / write | ~190 / ~100 MB/s |
| vsock to / from the guest | ~100 / ~1500 MB/s |

(busybox's own copy loop, not the VMM, bounds the `nc` upload.)

virtio-blk offers SEG_MAX and SIZE_MAX, so Linux sends a 1 MiB request as
one chain of up to 128 segments; the host moves it with one preadv/pwritev.
A failed host operation (a full host disk, an I/O error) answers the request
with IOERR rather than losing the data quietly.

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
  the ones opened; its header must describe a machine this host makes
  (RAM at its base, whole MiB), and a malformed file is refused
  (src/vmm/snapfile.bend bounds every part before the host reads it).
  Snapshots, screendumps, the console log and the control, vsock and LAN
  sockets are this user's alone (mode 0600), and never written through a
  symlink. `--control` and `--vsock` replace only a dead socket at their
  path: a socket a running VMM listens on, or anything that is not a
  socket, is refused and left alone (src/vmm/hostfiles.bend).
- Disk images: locked while in use; `:ro` disks and qcow2 backing files open
  read-only, and a backing file must be a regular file. A guest cannot
  write a qcow2 header at the start of a raw disk (which would make it a
  qcow2 image, with a backing file of its choosing, at the next start). A
  qcow2 image's
  backing file name is trusted as `qemu-img` trusts it: do not attach
  images from untrusted sources.
- The network (user-mode NAT): the guest reaches what your host reaches,
  except these, refused by the NAT (a TCP SYN gets a RST, a UDP datagram is
  dropped): 0.0.0.0/8, 127.0.0.0/8 named directly, 169.254.0.0/16 (link
  local, where clouds serve instance metadata), 224.0.0.0/4 (multicast) and
  255.255.255.255; 10.0.2.3 (the host's resolver, the first nameserver of
  /etc/resolv.conf, read again at each query so a host network change
  reaches a running guest; `net` on the control socket shows it) takes port
  53 only. The
  host itself stays reachable as 10.0.2.2, which is the host's loopback: a
  service bound to 127.0.0.1 on the host is open to the guest. The guest
  holds at most 256 TCP connections and 128 UDP flows (the least recently
  used closes first; a flow idle for 60 s closes); each UDP flow is a
  socket connected to the one address and port the guest sent to, so only
  that peer answers it. No socket send waits: guest data a peer does not
  take waits on the host, up to 4 MiB per connection and 64 MiB over all
  connections before the NAT stops taking more from the guest (a zero
  window); past 32 MiB per connection or 96 MiB in all, or when its peer
  takes nothing for 60 s, the connection is reset. A guest RST resets the
  host's socket at once and drops what waits; a closed connection sends
  what waits for at most 30 s (at most 64 such at once). On macOS the
  VMM keeps below 1024 descriptors (select() there refuses more); on Linux
  it raises its soft limit up to 65536. Either way a new flow that would
  pass the socket budget is refused before the VMM runs out of descriptors. A connection queues at most
  1 MiB for the guest before the host stops reading its socket. Nothing
  reaches the host's sockets before the host's connect completes.
- Forwarded ports (`--forward`): anyone who can reach ADDR can connect to
  the guest's port through it. The default, 127.0.0.1, is every user and
  program on this host (not only yours); `0.0.0.0` is the whole network
  your host is on. Forward only ports whose guest service authenticates
  its clients, or bind an address only trusted peers reach. Forwarded
  connections count against the guest's 256 TCP connections and the
  socket budget: past either, a new client is closed at once. A client the
  guest does not answer (three SYNs over 6 s) is reset.
- Not yet: the VMM is not sandboxed (it runs with your user's rights).

## How it is verified

| Level | Command | Where |
|---|---|---|
| Typing, termination, laws, proofs | `bend PROOF.bend` | anywhere |
| Tests on the simulator (500+) | `scripts/check.sh` | anywhere, CI |
| Same tests compiled native, on all threads | `scripts/check-native.sh` | macOS / Linux with clang |
| Proofs re-checked by the Lean-proven kernel | `VERDICT=1 scripts/check.sh` | CI (`verdict` job) |
| Real guests on the host's hypervisor | `scripts/check-host.sh` | macOS (Hypervisor.framework), Linux arm64 and x86_64 (KVM) |
| The same on a Linux KVM host from a Mac | `scripts/lima/linux-host.sh 'CHECK_SLOW=5 SKIP_NATIVE=1 scripts/check-host.sh'` | a Lima VM |
| The same on an emulated KVM host (QEMU with EL2) | `scripts/ci/emulated-kvm.sh` | CI (`host-linux` job) |
| The same with x86_64 guests on real KVM | `scripts/check-host.sh` | CI (`x86` workflow, GitHub's x86_64 runners) |
| A real distribution: Ubuntu 24.04's cloud image | `scripts/ubuntu-check.sh` | macOS / Linux, on demand (600 MiB download) |

`scripts/check-host.sh` boots a bare-metal payload, then Linux (1 and 4 CPUs),
then a busybox userspace that runs an in-guest test suite: disk reads and
writes, entropy, timers, interrupts, console input, reboot, networking, 9p,
vsock both ways, pause/resume, snapshot/restore, and the display (a
screendump, keys typed into the framebuffer console, tablet events read from
the guest's evdev), UEFI: edk2 booting Alpine's ISO, an EFI variable
written from Linux surviving a reboot, and qcow2: images over a raw backing
file, compressed and fresh, read and written by the guest, then checked by
`qemu-img check` and read back by `qemu-img`; image locks, the raw-disk
header guard, restore's path check, and SIGTERM and `powerdown` pressing the
power button.

`scripts/ubuntu-check.sh` boots Ubuntu 24.04's arm64 cloud image (qcow2,
through UEFI, cloud-init from a NoCloud seed disk, 4 vCPUs): cloud-init is
done in about 15 s, HTTPS works through the NAT, no systemd unit fails, and
SIGTERM shuts it down cleanly in a few seconds.

## Layout

- `src/` the pure VMM; `laws/` its spec; `proofs/` the proofs
- `host/` the system calls (C: Hypervisor.framework and KVM backends, files,
  sockets, the window) and the driver (`host/main.bend`)
- `scripts/` builds, checks (`check.sh`, `check-host.sh`), `bench.sh`,
  `soak.sh`, release and CI helpers
- `tests/` simulator tests; `tests/guest/` guest payloads and the in-guest suite
- `docs/DESIGN.md` architecture, verification ladder, roadmap
- `AGENTS.md` rules for contributors (human or AI)
