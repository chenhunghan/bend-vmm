# bend-vmm design

## Goal

Boot an arm64 Linux guest on macOS (Apple Silicon) with a VMM written in
Bend: serial console, virtio block/console/rng, PSCI SMP. macOS only; no
Linux or Windows host support. openvmm is a reference, not a template.

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

### Guest memory map (QEMU "virt" compatible)

| Region | Base | Size | IRQ |
|---|---|---|---|
| GIC distributor | 0x0800_0000 | 64 KiB | |
| GIC redistributors | 0x080A_0000 | 128 KiB / CPU | |
| PL011 UART | 0x0900_0000 | 4 KiB | SPI 1 (INTID 33) |
| virtio-mmio slot n | 0x0A00_0000 + n·0x200 | 512 B | SPI 16+n (INTID 48+n) |
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
4. **Hardware-in-the-loop (macOS).** `scripts/check-mac.sh` builds and signs
   the host, then (a) runs tiny bare-metal arm64 payloads (tests/guest/) that
   poke the UART, PSCI and virtio, and asserts on the serial log, and (b)
   boots a Linux kernel and initramfs to a marker line, with a timeout.
5. **Final gate.** `bend PROOF.bend` prints ALL PROOFS CHECK
   (`scripts/check.sh --strict`), then `bend PROOF.bend --verdict` re-checks it
   with the Lean-proven BendTT kernel (needs Lean 4.34).

## Parallel development

Work splits along module contracts. The architect writes a module's
contract (types, signatures, `?TODO` bodies) and its laws, then one agent
per module implements and proves it, in parallel, each in its own files
(`src/<area>/<module>.bend`, `proofs/<module>.bend`, `tests/<module>.bend`).
`LAWS.bend` and `PROOF.bend` only import, so parallel PRs do not conflict.

- **Wave 1 (independent):** lib laws, esr, psci, fdt, pl011, virtio_mmio,
  virtio_queue, image, layout.
- **Wave 2 (needs wave 1):** boot/dtb (the machine's device tree), virtio
  blk/console/rng devices, vmm/machine (the exit handler wiring every
  device), whole-boot exit traces on the simulator.
- **Host (macOS, in parallel with both):** host/hvf.c effects, vCPU threads,
  GIC, the run loop, the CLI, check-mac.sh.

## Parallelism inside the VMM

Bend parallelizes calls written as a parallel let. Places where the work
splits evenly: serializing DTB subtrees once the string table is fixed;
gathering and scattering independent virtio descriptors; processing
independent virtqueues; checksums over large buffers (halving recursion);
one `IO.fork` per vCPU at the host level.
