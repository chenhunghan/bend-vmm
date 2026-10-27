# bend-vmm design

## Goal

Run arm64 guests (Linux, through UEFI or a direct kernel boot) with a VMM
written in Bend, on Hypervisor.framework (macOS, Apple Silicon) and KVM
(Linux arm64), treating the guest as hostile. openvmm is a reference, not a
template.

## Shape: a pure machine and a thin host

```
             +-------------------- host/ (macOS) ---------------------+
 guest  <->  | Hypervisor.framework  <->  C effects (hvf.c)           |
             |   vCPU threads, guest RAM, GICv3 (hv_gic), vtimer       |
             |                    |  RawExit                ^ Vm program|
             +--------------------|-------------------------|---------+
                                  v                         |
             +-------------------- src/ (pure Bend) ---------------------+
             |  arm64/esr  decode the trap      arm64/psci  PSCI calls   |
             |  vmm/layout memory map + bus     dev/pl011   UART         |
             |  virtio/mmio transport           virtio/queue split rings |
             |  virtio/{blk,console,rng}        fdt + boot/dtb  the DTB  |
             |  boot/image Linux Image loader   vmm/machine exit handler |
             +-----------------------------------------------------------+
```

The host runs a vCPU until it exits and passes a `RawExit` (src/vmm/abi.bend)
to the pure side. The pure side answers with a `Vm` program, a value
describing the effects it needs: read or write guest memory, set a register,
advance PC, print to the console, raise an interrupt, power off, start a CPU.
The host interprets the program against Hypervisor.framework.

The same program runs in `src/vmm/sim.bend`, a pure interpreter over
simulated memory that records every effect. So every device, the exit
handler, and whole boot sequences of exits run on Linux, in CI, and under
proof. The host has no logic worth testing apart from the boot test.

Device code is written in `Op<R, A>`, a continuation monad over `Vm`. Its
bind needs no recursion, so `do` blocks and Nat-fuelled loops pass Bend's
termination check. Nothing in `src/` is `@unsafe`.

### Guest memory map (QEMU "virt" layout, GICR moved)

Hypervisor.framework's GIC reserves a 32 MiB redistributor region (probed
on macOS 27: distributor 64 KiB, redistributor 128 KiB per CPU, SPIs
32..1019, vtimer PPI 27). At QEMU's 0x080A_0000 that region would cover the
UART and the virtio slots, so it moves to 0x0C00_0000.

| Region | Base | Size | IRQ |
|---|---|---|---|
| flash bank 0 (UEFI firmware, host memory, RX) | 0x0000_0000 | 64 MiB | |
| flash bank 1 (UEFI variables, CFI flash model) | 0x0400_0000 | 64 MiB | |
| GIC distributor | 0x0800_0000 | 64 KiB | |
| GIC redistributors | 0x0C00_0000 | 32 MiB region (128 KiB / CPU) | |
| PL011 UART | 0x0900_0000 | 4 KiB | SPI 1 (INTID 33) |
| PL031 RTC | 0x0901_0000 | 4 KiB | SPI 2 (INTID 34) |
| virtio-mmio slot n | 0x0A00_0000 + n·0x200 | 512 B | SPI 16+n (INTID 48+n) |
| framebuffer (`--display`) | 0x1000_0000 | 16 MiB | |
| RAM | 0x4000_0000 | configurable | |

GICv3 is Hypervisor.framework's in-kernel GIC (`hv_gic_create`, macOS 15+),
so the VMM does not emulate an interrupt controller; it only drives SPI
levels. The arch timer is the guest's virtual timer (PPI 27).

### Host layer (host/)

- One pthread per vCPU, created by C. A vCPU must be run, and its registers
  read and written, on the thread that created it. The Bend effect
  `Vcpu.run(cpu)` posts a request to that thread and parks on a pipe with
  `io_wait_on`, so the Bend event loop stays free and several vCPUs run at
  once (one `IO.fork` per vCPU).
- Guest RAM is one `mmap` region mapped with `hv_vm_map`. File loading
  (kernel, initrd) and bulk copies happen in C; the pure side sees memory only
  through `Vm` programs.
- Handles are small integers (Bend 2.0 has no user handle types).
- Build: `bend host/main.bend -o out/bend-vmm`, then sign it with the
  `com.apple.security.hypervisor` entitlement (scripts/build-mac.sh). On this
  toolchain (Command Line Tools clang 17 with the macOS 27 SDK) linking needs
  `SDKROOT` pointed at the 26.x SDK; the script handles it.

## Verification ladder

Each level runs on every PR that touches its scope. Levels 1–3 run anywhere
Bend runs (CI on Linux); level 4 needs this Mac.

1. **Typing and termination.** `bend PROOF.bend` type-checks every module.
   Bend proves every live def terminates and every value is used within its
   quantity. Nothing in `src/` may be `@unsafe`.
2. **Laws.** `laws/<module>.bend` states the spec: concrete laws (exact
   register values, exact DTB bytes checked against `dtc`, exact syndrome
   decodes from the Arm ARM) and general laws (round-trips, invariants).
   `proofs/<module>.bend` proves them. `laws/done/<module>` markers are a
   ratchet: a finished module must stay fully proven.
3. **Simulation tests.** `tests/<name>.bend` runs devices and the exit
   handler on the simulator: virtqueues over fake guest memory, MMIO
   sequences a Linux driver performs, scripted exit traces. Tests headed
   FROZEN SPEC are architect-owned.
3b. **Native runtime.** `scripts/check-native.sh` compiles every test and
   runs it several times on all threads: parallel lets only run in parallel
   natively, and the native runtime has failed where the JS lane passed.
4. **Hardware-in-the-loop (macOS).** `scripts/check-mac.sh` builds and signs
   the host, then (a) runs tiny bare-metal arm64 payloads (tests/guest/) that
   poke the UART, PSCI and virtio, and asserts on the serial log, and (b)
   boots a Linux kernel and initramfs to a marker line, with a timeout.
5. **Kernel re-check.** `VERDICT=1 scripts/check.sh` re-checks every done
   module with `bend --verdict`: the BendTT kernel, whose soundness is proven
   in Lean (Lean 4.34). CI runs it as the `verdict` job. The final gate is
   `scripts/check.sh --strict` (no TODO anywhere) with VERDICT=1.

## Parallel development

Work splits along module contracts. The architect writes a module's
contract (types, signatures, `?TODO` bodies) and its laws, then one agent
per module implements and proves it, in parallel, each in its own files
(`src/<area>/<module>.bend`, `proofs/<module>.bend`, `tests/<module>.bend`).
`LAWS.bend` and `PROOF.bend` only import, so parallel PRs do not conflict.

- **Wave 1 (independent):** lib laws, esr, psci, fdt, pl011, virtio_mmio,
  virtio_queue, image, layout.
- **Wave 2 (contracts against wave 1):** boot/dtb (the machine's device
  tree, byte-exact laws), virtio device framework + rng, virtio blk,
  vmm/machine (the exit handler wiring every device; tests/machine.bend is
  its frozen spec). Each runs once its wave-1 dependencies merge.
- **Wave 3:** whole-boot exit traces on the simulator, virtio-console,
  a Linux boot in check-mac.sh.
- **Host (macOS, in parallel with both):** host/hvf.c effects, vCPU threads,
  GIC, the run loop, the CLI, check-mac.sh.

## Parallelism inside the VMM

Bend parallelizes calls written as a parallel let. Places where the work
splits evenly: serializing DTB subtrees once the string table is fixed;
gathering and scattering independent virtio descriptors; processing
independent virtqueues; checksums over large buffers (halving recursion);
one `IO.fork` per vCPU at the host level.

A native parallel let costs about 2.6 µs to spawn. Keep them off paths that
run on every exit with little work per side (`Trap.decode` was one: the
exit got that much faster without it), and give recursive splits a size
floor (`Csum.small`, `Tcp.small`).

## Status (2026-10-28)

- Every module in `src/` is implemented and proven (`bend PROOF.bend`: ALL
  PROOFS CHECK; `VERDICT=1 scripts/check.sh` re-checks the done modules with
  the Lean-proven kernel), 600+ simulator tests.
- `scripts/check-mac.sh` boots real guests on Hypervisor.framework: Ubuntu's
  6.8 kernel with a busybox userspace (virtio blk/rng/console/net/9p/vsock,
  the RTC, up to 8 CPUs and 4 GiB, reboot), pause/resume, snapshot/restore,
  the display with virtio keyboard and tablet, and UEFI: edk2 boots Alpine's
  ISO through GRUB, with EFI variables kept in a CFI flash model.
- Cold boot to a shell about 0.55 s; a snapshot restores in about 30 ms.
- Linux hosts: host/hvf.c's backends interface has a KVM implementation
  (vGICv3, PSCI forwarded to the machine by the SMCCC filter, MMIO exits
  rewritten as data aborts with a valid syndrome), and `scripts/check-host.sh`
  passes on Ubuntu 24.04 arm64 (run by `scripts/lima/linux-host.sh`; on an
  M1/M2 Mac the KVM host is emulated by QEMU), snapshots included: vCPU
  registers by KVM_GET_REG_LIST, the vGIC as an ordered replay of its
  registers. CI runs the same check on an emulated KVM host
  (`scripts/ci/emulated-kvm.sh`): GitHub's arm64 runners have no /dev/kvm.
- Data path: devices name guest memory (`V.Iov`) and the host moves bytes
  (disk, 9p, network); qcow2 images (src/disk) are walked in Bend.
- `scripts/bench.sh` and `scripts/soak.sh` measure speed and long runs; a
  30-minute soak holds the VMM's memory flat (about 265 MB, +0.4%).
- Hostile guests and files (2026-10-28, after a four-part audit): queue
  sizes, chains, gathers, rng, vsock, 9p fids and readdir are bounded in the
  pure models (laws under `# Proposed:`); the share never follows a guest
  symlink and opens regular files only; `--restore` opens only the host
  files the command line names; images are locked; a raw disk refuses a
  qcow2 header; a failed host disk operation is IOERR (VmDiskStatus); VMM
  logs are rate-limited; control and vsock clients have a 5 s deadline.
- Lifecycle: SIGTERM presses a virtio power key (systemd guests shut down in
  a few seconds); `scripts/ubuntu-check.sh` boots Ubuntu 24.04's cloud image.

## Next

- UEFI: a fw_cfg device (boot order, kernel loading) and a graphics output
  (ramfb) for the firmware's own screens.
- The NAT's remaining hardening (non-blocking sends, connection and socket
  caps, an outbound policy): PR #25. vsock's host-side send still blocks the
  event loop when the host program stops reading.
- A vCPU waiting on another's interrupt pays Hypervisor.framework's ~80 µs
  WFI wake (a disk request from vCPU 1: ~100 µs against ~21 µs on vCPU 0).
- No sandbox: the VMM runs with the user's rights.
- Less C: the host layer's remaining decisions (the console's escape keys,
  the control protocol, address mapping, the snapshot file layout) can move
  into Bend, leaving C as system calls.
