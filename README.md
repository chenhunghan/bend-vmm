# bend-vmm

A virtual machine monitor for macOS on Apple Silicon, written in
[Bend](https://bend-lang.com). It boots arm64 Linux on Hypervisor.framework.

All of the VMM's logic is pure Bend under `src/`: trap decoding, PSCI, the
device tree, the PL011 UART, the PL031 RTC, virtio (blk, net, console, rng,
9p), the user-mode network stack, and the exit handler that ties them
together. Laws state what each module must do, and proofs check them,
re-checked by a kernel whose soundness is proven in Lean. A simulator runs
the same code on any OS. A thin C layer (`host/`) drives Hypervisor.framework.

## What it runs

- Linux kernels as `Image` or gzip-compressed `vmlinuz` (Debian, Ubuntu), with
  an initramfs, up to 64 vCPUs (one host thread each), GICv3 and the arch timer
  in Hypervisor.framework.
- Serial console (PL011, `ttyAMA0`) with interactive input; `Ctrl-A x` quits.
- virtio-blk disks (read-write or read-only, FLUSH), virtio-rng, the RTC.
- Reboot (`reboot` in the guest restarts the VM) and power-off.

## Build and run

Requirements: macOS on Apple Silicon, Bend 2.0.39
(`curl -fsSL https://bend-lang.com/install.sh | sh`), Xcode Command Line Tools.

```sh
scripts/build-mac.sh host/main.bend out/bend-vmm      # build and sign
scripts/guest-assets.sh                               # fetch a test kernel and build a busybox initramfs
out/bend-vmm --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --mem 1024 --cpus 2
```

Options:

| Option | Meaning |
|---|---|
| `--kernel FILE` | Linux `Image` or gzip-compressed `vmlinuz` |
| `--initrd FILE` | initramfs |
| `--cmdline "…"` | kernel command line (default `console=ttyAMA0 earlycon=pl011,0x9000000`) |
| `--mem MiB` | guest RAM (default 512) |
| `--cpus N` | vCPUs (default 1) |
| `--disk FILE` | a raw disk image as virtio-blk (`/dev/vda`) |
| `--payload FILE` | a bare-metal binary entered at the start of RAM |

Debugging: `BEND_VMM_TRACE=1` prints every trapped exit, `=2` console input
and interrupt line changes.

## How it is verified

| Level | Command | Where |
|---|---|---|
| Typing, termination, laws, proofs | `bend PROOF.bend` | anywhere |
| Tests on the simulator (500+) | `scripts/check.sh` | anywhere, CI |
| Same tests compiled native, on all threads | `scripts/check-native.sh` | macOS / Linux with clang |
| Proofs re-checked by the Lean-proven kernel | `VERDICT=1 scripts/check.sh` | CI (`verdict` job) |
| Real guests on Hypervisor.framework | `scripts/check-mac.sh` | this Mac |

`scripts/check-mac.sh` boots a bare-metal payload, then Linux (1 and 4 CPUs),
then a busybox userspace that runs an in-guest test suite: disk reads and
writes, entropy, timers, interrupts, console input, reboot.

## Layout

- `src/` the pure VMM; `laws/` its spec; `proofs/` the proofs
- `host/` Hypervisor.framework effects (C) and the driver (`host/main.bend`)
- `tests/` simulator tests; `tests/guest/` guest payloads and the in-guest suite
- `docs/DESIGN.md` architecture, verification ladder, roadmap
- `AGENTS.md` rules for contributors (human or AI)
