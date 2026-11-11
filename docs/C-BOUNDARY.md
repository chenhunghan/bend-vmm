# What host/hvf.c does, and what it decides

bend-vmm's rule: Bend decides and C acts. Every choice (a policy, limit,
order, format or validation) is made in pure Bend under `src/`, with laws.
`host/hvf.c` holds the effects Bend cannot perform: hypervisor calls,
system calls, threads, memory copies and drawing. It reports facts and
carries out plans that Bend hands it.

This file is the audit of that boundary. It covered all 113 effects in
host/hvf.c as of 2026-11-09 and says, for each group, where the
decisions are made; the migration ledger at the end lists every effect
(126 as of 2026-11-11) with its target in the C-to-Bend plan. The
section before it lists every decision still in C, with the reason it
stays.

## The effects by group

| Group | Effects | C does | Bend decides (src/) |
|---|---|---|---|
| Hypervisor | `init` `vcpu` `vcpu_queue` `irq` `kick` `pause` `resume` `pause_state` | creates the VM and vCPUs, runs them, reports exits as facts (KVM's raw, kind 2000 + reason) | everything about the machine; KVM exits become the machine's terms in `arm64/kvmexit.bend` |
| Snapshots | `snap_save` `snap_commit` `snap_drop` `snap_open` `snap_peek` `snap_load` `snap_info` `snap_args` `snap_machine` `snap_gic` `snap_plans` `rename` | reads and writes the registers and the vGIC that a plan names, and moves byte ranges | file layout, placement and format version (`vmm/snapfile.bend`), vGIC replay order (`arm64/gicplan.bend`), registers kept (`arm64/regplan.bend`), file mode (`vmm/hostfiles.bend`) |
| Memory and images | `load` `read` `write` `file_size` `zero_ram` `inflate_ram` `inflate_disk` `flash` `fw_load` | copies files into guest RAM; inflates gzip and deflate | whether to inflate (`boot/image.bend`), where things go (`vmm/layout.bend`), whether firmware fits (`Layout.flash_fits`) |
| Disks | `disk_open_with` `disk_err` `disk_read` `disk_write` `disk_copy` `disk_short` `disk_mark` `disk_xcopy` `disk_alloc` `disk_flush` `disk_size` `disk_status` | moves bytes between images and guest memory; opens and locks images | how each use opens and locks (`disk/access.bend`), read-only fallback, qcow2 (`src/disk`) |
| Console and process | `out` `out_flush` `stdin` `stdin_tty` `stdin_wait` `log_state` `log_put` `console_log` `console_size` `console_reopen` `signals` `signal_wait` `set_args` `set_prog` `prog` `reexec` `exe_path` `set_exec` `err_text` `now` `random` | terminal, pipes, signals, re-exec, clock, entropy | log gate (`vmm/loggate.bend`), log rotation and its renames (`dev/conlog.bend`), what a reset runs (`Files.exec_path`), escape keys, file modes |
| NAT | `tcp_*` `udp_*` `nat_send` `net_copy` `net_holds` `net_limits` `stage` `stage_drop` `dns` `set_dns` | sockets, send buffers, parking, wakeups | the whole NAT (`src/net`), limits (`net/limits.bend`), flusher actions (`net/flush.bend`), UDP flows (`net/udpflow.bend`) |
| Descriptors | `nofile` `set_nofile` `fd_room` | reads and sets rlimit; counts sockets | soft limit and flow budget (`net/fds.bend`) |
| Sockets and listeners | `ctl_listen` `ctl_next` `ctl_reply` `vsock_listen` `vsock_accept` `vsock_base` `vsock_file` `unix_connect` `fwd_listen` `fwd_accept` `accept_retry` `sock_facts` `sock_remove` | binds, accepts, connects; reports what a path holds | protocol (`vmm/control.bend`), deadlines, backlogs, retry and CONNECT (`vmm/clients.bend`), forward specs (`vmm/cli.bend`), which paths may be listened on (`vmm/hostfiles.bend`) |
| LAN | `lan_open` `lan_send` `lan_recv` `lan_to_ram` `lan_release` `mkdir` `dir_facts` | datagram sockets, one frame per datagram | where frames go (`virtio/lan.bend`), directory trust and socket replacement (`vmm/hostfiles.bend`) |
| Shares (9p) | `fs` `share_open` `share_quota` `share_usage` | walks paths with openat and O_NOFOLLOW; keeps a descriptor cache | valid names (`fs/contain.bend`), listing order and pages (`fs/listing.bend`), entries, types and modes (`fs/entry.bend`), quota (`fs/quota.bend`) |
| Display | `fb_init` `fb_present` `fb_dump` | maps the framebuffer, draws it with Metal, writes PPM | display size (`Cli.display.fits`), pointer and keys (`dev/pointer.bend`), file mode |

## Moved on 2026-11-09, after the first version of this audit

- Listen backlogs (control 4, vsock 16, forward 64) and the retry while
  out of descriptors (100 ms): `Clients.backlog_*` and
  `Clients.full_retry_ms`.
- The signals the VMM takes (SIGHUP, SIGINT, SIGTERM): `Clients.signals`.
  C's thread can catch only those three, and passes on any it is not
  given.
- The snapshot format version: `Snapf.version`, from the hypervisor C
  reports (0 Hypervisor.framework, 1 KVM).

## Moved on 2026-11-11 (C_TO_BEND.md, stages 2, 3 and 4)

- Disk snapshots, new: which disks a snapshot keeps, the copies' names and
  GEN tag, the order of cloning, writing and renaming, which copies an
  overwritten snapshot leaves behind, and how a restore sets the disks back
  are src/vmm/disksnap.bend (with laws); C clones a file (`Hvf.clone`:
  clonefile, FICLONE, or a copy), removes one (`Hvf.remove`) and reports the
  command line (`Hvf.args`).

- A disk transfer that falls short (stage 3's short-IO and retry
  decisions): C makes one vectored attempt per `Hvf.disk_copy` and reports
  a short one (`Hvf.disk_short`: bytes moved, errno); Bend decides what
  follows (`Xfer.after`, src/host/transfer.bend): another attempt from the
  next byte (`Range.advance`), after EINTR too; zeros for the rest of a
  read that met the end or an error after progress (`Hvf.zero_ram`); a
  failure for a write that stopped short, latched with `Hvf.disk_mark`. A
  complete transfer is still one host call. `BEND_VMM_SHORT_IO=N`
  (check-host 8b) caps every attempt at N bytes and interrupts every
  third. Its state sits on cache lines of its own: four earlier layouts cost
  +0.04 to +0.08 us per exit. A/B (30 pairs): exit -0.01 us against
  9705a94, -0.0125 us against f8983a4; boot -1.5 ms.

- Console output's limits: it waits at most 1 ms (`Out.batch_us`) and past
  16 MiB waiting it is dropped (`Out.backlog`), src/dev/conlog.bend, handed
  to C at startup (`Hvf.out_limits`). The console buffer's globals now sit
  on 128-byte cache lines of their own (as do the vCPU slots): moving the
  limits into variables first cost +0.06 to +0.12 us per exit through what
  shared their lines.
- The terminal console's mode: raw input and CR LF kept on output
  (`Esc.raw_input`, `Esc.out_crlf`, src/dev/escape.bend; `Hvf.tty_mode`).
- A socket path too long for the address: refused by Bend before
  listening, saying so (`Files.sock_path_fits` against
  `Hvf.sock_path_max`); C's own check stays beneath it.
- A/B (30 pairs): exit +0.02 us median against 1547f10 (within +-0.05);
  against f8983a4 exit +0.0125 us, boot -1 ms (within the drift caps).

- The 9p descriptor cache's policy: which operations empty a share's open
  files (`Fdc.invalidates`, passed as bit 256 of the operation) and which
  slot a newly opened file takes (`Fdc.victim`, least recently used, from
  the uses `Hvf.fdc_stamps` reports; `Hvf.fdc_put` places it).
  src/host/fdcache.bend. C keeps the descriptors and finds an entry by its
  key; only an operation that opened a file comes back for a slot.
- A datagram's UDP flow: `Udp.find` (src/net/udpflow.bend) picks it from
  the open flows `Hvf.udp_flows` reports, and `Hvf.udp_send` takes it (0:
  open one). C still refuses a flow whose guest port, address or port
  differ (defence beneath Bend's choice).
- A/B for both (30 pairs, the margins of C_TO_BEND.md): exit +0.005 us
  median, within +-0.05 (equivalent); boot -3 ms; against the original
  baseline f8983a4, exit +0.015 us and boot +4 ms, within the drift caps.

- The console log's rotation: which files move, to what names and in
  what order (`Log.moves`, with laws). Bend runs the renames with
  `Hvf.rename`; C only reopens the log (`Hvf.console_reopen`, which
  replaced `Hvf.console_rotate`).
- What a guest reset runs: the system's name for the executable, else the
  first argument (`Files.exec_path`, with laws), chosen once at startup
  (`Hvf.exe_path`, `Hvf.set_exec`). C restores the terminal, flushes and
  calls execv.

Pure models of the C that stays, for tests now and a port later (no host
change): `src/host/range.bend` (hvf_ptr, hvf_iov_io's resume),
`src/host/handoff.bend` (the vCPU handoff over every schedule),
`src/host/fdcache.bend` (hvf_fdc_*), `src/host/transfer.bend` (short IO,
staging slots), and `src/lib/inflate.bend` (DEFLATE and gzip with the
host's acceptance rules, checked against libz by tests/oracles/inflate.py).

## Decisions still in C, and why

The project owner accepted this list on 2026-11-09 as the end state of
"move to pure Bend without sacrificing performance": each stays for
performance, or as defence beneath Bend's own checks.

| Decision | Where | Why it stays |
|---|---|---|
| A share opens only regular files for reads and writes | `hvf_fs_run` | Moving it costs a round trip on every open that misses the descriptor cache, on the 9p hot path. `check-host` tests it. |
| gzip and deflate decoding | `hvf_inflate` | Decoding a ~30 MB kernel in Bend would cost far more than the 0.55 s boot. Bend decides whether to inflate. |
| Names of the LAN sockets a frame is sent to | `hvf_lan_send_run`, `hvf_lan_open_run` | Tried 2026-11-09: Bend naming each destination (and its own socket) cost +0.1 us on every exit (13 to 15 of 16 pairs slower in each variant), a code-layout effect, though LAN throughput was unchanged. C formats the names; Bend's `Files.lan_sock` (same format, with a law) names this VM's socket for the replace check. |
| Memory-safety caps (sizes, counts, path lengths) | throughout | Defence in depth beneath Bend's own checks; never the only check. |

Moving any of these: A/B the exit path with 30 interleaved pairs before
pushing. Bend compiles the program as one state machine, so a change far
from the hot path can still move exit latency
(docs/DESIGN.md, "Less C").

## Migration ledger (C_TO_BEND.md)

Every effect host/hvf.c registers, as of 2026-11-11 (126; regenerate the
list with `grep -o 'io_eff(CID(Hvf\.[a-z_0-9]*)' host/hvf.c`). Target and
primitive are the plan's proposals, not existing modules; line numbers are
host/hvf.c's at the commit that changed this table. Test names what checks
the effect today; Benchmark, what `scripts/bench/ab.sh` (or `bench.sh`)
measures for a change to it. In handwritten C behavior that remains: every
row but the decisions listed as moved above.

| Effect | C function (line) | Target | Native primitive needed | Stage | Test | Benchmark | Status |
|---|---|---|---|---|---|---|---|
| `init` | `hvf_init_run` (1141) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `vcpu` | `hvf_vcpu_run` (1413) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `vcpu_queue` | `hvf_vcpu_queue_run` (1462) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `pause` | `hvf_pause_run` (3640) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `resume` | `hvf_resume_run` (3657) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `pause_state` | `hvf_pause_state_run` (3673) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `irq` | `hvf_irq_run` (1481) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `kick` | `hvf_kick_run` (1490) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `snap_plans` | `hvf_snap_plans_run` (2221) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_save` | `hvf_snap_save_run` (3758) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_commit` | `hvf_snap_commit_run` (3852) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `rename` | `hvf_rename_run` (3888) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C renames; also runs the console log renames |
| `clone` | `hvf_clone_run` (5199) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C clones; Bend plans disk snapshots (Dsnap, 2026-11-11) |
| `remove` | `hvf_remove_run` (5244) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C removes; Bend says which (Dsnap, 2026-11-11) |
| `snap_drop` | `hvf_snap_drop_run` (3801) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_peek` | `hvf_snap_peek_run` (3931) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_load` | `hvf_snap_load_run` (3963) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_open` | `hvf_snap_open_run` (3906) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_info` | `hvf_snap_info_run` (4029) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_args` | `hvf_snap_args_run` (4038) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_machine` | `hvf_snap_machine_run` (4053) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_gic` | `hvf_snap_gic_run` (4058) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `load` | `hvf_load_run` (1249) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `write` | `hvf_write_run` (1376) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `read` | `hvf_read_run` (1391) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `fw_load` | `hvf_fw_load_run` (4824) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `flash` | `hvf_flash_run` (4862) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `file_size` | `hvf_file_size_run` (1366) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `zero_ram` | `hvf_zero_ram_run` (2068) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `inflate_ram` | `hvf_inflate_ram_run` (2135) | host/memory.bend over src/lib/inflate.bend | packed buffers, efficient loops | 6 | tests/inflate.bend, tests/oracles/inflate.py; check-host gzip kernel | boot (gzip kernel), compressed qcow2 | C (zlib); Bend spec and oracle done |
| `inflate_disk` | `hvf_inflate_disk_run` (2161) | host/memory.bend over src/lib/inflate.bend | packed buffers, efficient loops | 6 | tests/inflate.bend, tests/oracles/inflate.py; check-host gzip kernel | boot (gzip kernel), compressed qcow2 | C (zlib); Bend spec and oracle done |
| `disk_open_with` | `hvf_disk_open_with_run` (1843) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_status` | `hvf_disk_status_run` (1861) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_err` | `hvf_disk_err_run` (1836) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_size` | `hvf_disk_size_run` (1877) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_flush` | `hvf_disk_flush_run` (1889) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_read` | `hvf_disk_read_run` (1908) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_write` | `hvf_disk_write_run` (1920) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_copy` | `hvf_disk_copy_run` (2029) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C attempts once; Bend decides after a short one (2026-11-11) |
| `disk_short` | `hvf_disk_short_run` (5128) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C reports a fact (2026-11-11) |
| `disk_mark` | `hvf_disk_mark_run` (5135) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C latches what Bend decided (2026-11-11) |
| `disk_alloc` | `hvf_disk_alloc_run` (2084) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_xcopy` | `hvf_disk_xcopy_run` (2103) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `signals` | `hvf_signals_run` (1745) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_log` | `hvf_console_log_run` (5275) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_size` | `hvf_console_size_run` (5285) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_reopen` | `hvf_console_reopen_run` (5294) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C opens; Bend plans the renames (Log.moves, 2026-11-11) |
| `err_text` | `hvf_err_text_run` (4686) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `set_args` | `hvf_set_args_run` (1306) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `set_prog` | `hvf_set_prog_run` (1297) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `prog` | `hvf_prog_run` (1302) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `reexec` | `hvf_reexec_run` (1347) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C runs execv; Bend chose the path (2026-11-11) |
| `exe_path` | `hvf_exe_path_run` (1318) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C reports a fact (2026-11-11) |
| `set_exec` | `hvf_set_exec_run` (1336) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C keeps what Bend chose (Files.exec_path, 2026-11-11) |
| `args` | `hvf_args_run` (5152) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C reports a fact (2026-11-11) |
| `out_limits` | `hvf_out_limits_run` (5090) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C keeps what Bend chose (Out.backlog, Out.batch_us, 2026-11-11) |
| `tty_mode` | `hvf_tty_mode_run` (5100) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C applies what Bend chose (Esc.raw_input, Esc.out_crlf, 2026-11-11) |
| `out` | `hvf_out_run` (1562) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `out_flush` | `hvf_out_flush_run` (1618) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin` | `hvf_stdin_run` (1625) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin_tty` | `hvf_stdin_tty_run` (1779) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin_wait` | `hvf_stdin_wait_run` (1786) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `random` | `hvf_random_run` (1641) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `signal_wait` | `hvf_signal_wait_run` (1753) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `log_state` | `hvf_log_state_run` (1600) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `log_put` | `hvf_log_put_run` (1609) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `now` | `hvf_now_run` (1900) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `nofile` | `hvf_nofile_run` (2335) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `set_nofile` | `hvf_set_nofile_run` (2350) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `fd_room` | `hvf_fd_room_run` (2367) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `accept_retry` | `hvf_accept_retry_run` (4406) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `sock_facts` | `hvf_sock_facts_run` (4085) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `sock_path_max` | `hvf_sock_path_max_run` (5109) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C reports a fact; Bend checks paths (Files.sock_path_fits, 2026-11-11) |
| `sock_remove` | `hvf_sock_remove_run` (4109) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_listen` | `hvf_ctl_listen_run` (4366) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_next` | `hvf_ctl_next_run` (4463) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_reply` | `hvf_ctl_reply_run` (4475) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_base` | `hvf_vsock_base_run` (4502) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `unix_connect` | `hvf_unix_connect_run` (4517) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_listen` | `hvf_vsock_listen_run` (4558) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_accept` | `hvf_vsock_accept_run` (4662) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `fwd_listen` | `hvf_fwd_listen_run` (4694) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `fwd_accept` | `hvf_fwd_accept_run` (4780) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_file` | `hvf_vsock_file_run` (4645) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `net_limits` | `hvf_net_limits_run` (2232) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_connect` | `hvf_tcp_connect_run` (2473) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_wait` | `hvf_tcp_wait_run` (2515) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_recv` | `hvf_tcp_recv_run` (2541) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_release` | `hvf_tcp_release_run` (2648) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `net_holds` | `hvf_net_holds_run` (2904) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_fill` | `hvf_tcp_fill_run` (2594) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `stage` | `hvf_stage_run` (2669) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `stage_drop` | `hvf_stage_drop_run` (2710) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_send_staged` | `hvf_tcp_send_staged_run` (2806) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `net_copy` | `hvf_net_copy_run` (2622) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_shutdown` | `hvf_tcp_shutdown_run` (2948) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_flush` | `hvf_tcp_flush_run` (2844) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `udp_ages` | `hvf_udp_ages_run` (3042) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `udp_close` | `hvf_udp_close_run` (3059) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_over` | `hvf_tcp_over_run` (2932) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_flush_act` | `hvf_tcp_flush_act_run` (2864) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `nat_send` | `hvf_nat_send_run` (2920) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_close` | `hvf_tcp_close_run` (2988) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_abort` | `hvf_tcp_abort_run` (3011) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `udp_send` | `hvf_udp_send_run` (3072) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C sends; Bend picks the flow (Udp.find, 2026-11-11) |
| `udp_flows` | `hvf_udp_flows_run` (3024) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C reports a fact (2026-11-11) |
| `set_dns` | `hvf_set_dns_run` (2294) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `dns` | `hvf_dns_run` (2300) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `udp_recv` | `hvf_udp_recv_run` (3155) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `tcp_close_facts` | `hvf_tcp_close_facts_run` (2979) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; buffers blocked: toolchain |
| `mkdir` | `hvf_mkdir_run` (4118) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `dir_facts` | `hvf_dir_facts_run` (4129) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_open` | `hvf_lan_open_run` (4192) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_send` | `hvf_lan_send_run` (4251) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_recv` | `hvf_lan_recv_run` (4314) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_to_ram` | `hvf_lan_to_ram_run` (4323) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_release` | `hvf_lan_release_run` (4344) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `share_quota` | `hvf_share_quota_run` (5300) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C finds and keeps; Bend decides invalidation and eviction (2026-11-11) |
| `share_usage` | `hvf_share_usage_run` (5316) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C finds and keeps; Bend decides invalidation and eviction (2026-11-11) |
| `share_open` | `hvf_share_open_run` (3219) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C finds and keeps; Bend decides invalidation and eviction (2026-11-11) |
| `fs` | `hvf_fs_run` (3413) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C finds and keeps; Bend decides invalidation and eviction (2026-11-11) |
| `fdc_stamps` | `hvf_fdc_stamps_run` (3333) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | Bend decides eviction (2026-11-11) |
| `fdc_put` | `hvf_fdc_put_run` (3344) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | Bend decides eviction (2026-11-11) |
| `fb_init` | `hvf_fb_init_run` (4918) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |
| `fb_dump` | `hvf_fb_dump_run` (4938) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |
| `fb_present` | `hvf_fb_present_run` (5036) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |

### Baseline (stage 0, Apple M2 Pro, macOS 27.2, Bend 2.0.40)

`scripts/bench/ab.sh -n 30 -m exit,boot f8983a4 f8983a4` (the same build
against itself, 2026-11-11): exit 3.49 us per UART store, paired
difference 95% interval [-0.035, +0.018] us; tiny-Linux boot 255 ms,
[-2.5, +3.3] ms. That is the noise floor a change's A/B must beat to
read as faster or slower; with no equivalence margin (a decision the plan
leaves open) an equally fast change reads as inconclusive. KVM baselines
wait for a physical arm64 host.
