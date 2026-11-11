# What host/hvf.c does, and what it decides

bend-vmm's rule: Bend decides and C acts. Every choice (a policy, limit,
order, format or validation) is made in pure Bend under `src/`, with laws.
`host/hvf.c` holds the effects Bend cannot perform: hypervisor calls,
system calls, threads, memory copies and drawing. It reports facts and
carries out plans that Bend hands it.

This file is the audit of that boundary. It covered all 113 effects in
host/hvf.c as of 2026-11-09 and says, for each group, where the
decisions are made; the migration ledger at the end lists every effect
(115 as of 2026-11-11) with its target in the C-to-Bend plan. The
section before it lists every decision still in C, with the reason it
stays.

## The effects by group

| Group | Effects | C does | Bend decides (src/) |
|---|---|---|---|
| Hypervisor | `init` `vcpu` `vcpu_queue` `irq` `kick` `pause` `resume` `pause_state` | creates the VM and vCPUs, runs them, reports exits as facts (KVM's raw, kind 2000 + reason) | everything about the machine; KVM exits become the machine's terms in `arm64/kvmexit.bend` |
| Snapshots | `snap_save` `snap_commit` `snap_drop` `snap_open` `snap_peek` `snap_load` `snap_info` `snap_args` `snap_machine` `snap_gic` `snap_plans` `rename` | reads and writes the registers and the vGIC that a plan names, and moves byte ranges | file layout, placement and format version (`vmm/snapfile.bend`), vGIC replay order (`arm64/gicplan.bend`), registers kept (`arm64/regplan.bend`), file mode (`vmm/hostfiles.bend`) |
| Memory and images | `load` `read` `write` `file_size` `zero_ram` `inflate_ram` `inflate_disk` `flash` `fw_load` | copies files into guest RAM; inflates gzip and deflate | whether to inflate (`boot/image.bend`), where things go (`vmm/layout.bend`), whether firmware fits (`Layout.flash_fits`) |
| Disks | `disk_open_with` `disk_err` `disk_read` `disk_write` `disk_copy` `disk_xcopy` `disk_alloc` `disk_flush` `disk_size` `disk_status` | moves bytes between images and guest memory; opens and locks images | how each use opens and locks (`disk/access.bend`), read-only fallback, qcow2 (`src/disk`) |
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

## Moved on 2026-11-11 (C_TO_BEND.md, stage 2)

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
| The 9p descriptor cache (16 entries, least recently used) | `hvf_fdc_*` | Per operation, so on the hot path. |
| gzip and deflate decoding | `hvf_inflate` | Decoding a ~30 MB kernel in Bend would cost far more than the 0.55 s boot. Bend decides whether to inflate. |
| Names of the LAN sockets a frame is sent to | `hvf_lan_send_run`, `hvf_lan_open_run` | Tried 2026-11-09: Bend naming each destination (and its own socket) cost +0.1 us on every exit (13 to 15 of 16 pairs slower in each variant), a code-layout effect, though LAN throughput was unchanged. C formats the names; Bend's `Files.lan_sock` (same format, with a law) names this VM's socket for the replace check. |
| Memory-safety caps (sizes, counts, path lengths) | throughout | Defence in depth beneath Bend's own checks; never the only check. |

Moving any of these: A/B the exit path with 30 interleaved pairs before
pushing. Bend compiles the program as one state machine, so a change far
from the hot path can still move exit latency
(docs/DESIGN.md, "Less C").

## Migration ledger (C_TO_BEND.md)

Every effect host/hvf.c registers, as of 2026-11-11 (115; regenerate the
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
| `pause` | `hvf_pause_run` (3563) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `resume` | `hvf_resume_run` (3580) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `pause_state` | `hvf_pause_state_run` (3596) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `irq` | `hvf_irq_run` (1481) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `kick` | `hvf_kick_run` (1490) | host/vcpu.bend, host/platform/{hvf,kvm}.bend | dedicated workers, ABI bindings | 1, 5 | check-host boot and SMP; model: tests/handoff.bend | exit, guest mmio-exit | C; blocked: toolchain |
| `snap_plans` | `hvf_snap_plans_run` (2185) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_save` | `hvf_snap_save_run` (3681) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_commit` | `hvf_snap_commit_run` (3775) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `rename` | `hvf_rename_run` (3811) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C renames; also runs the console log renames |
| `snap_drop` | `hvf_snap_drop_run` (3724) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_peek` | `hvf_snap_peek_run` (3854) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_load` | `hvf_snap_load_run` (3886) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_open` | `hvf_snap_open_run` (3829) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_info` | `hvf_snap_info_run` (3952) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_args` | `hvf_snap_args_run` (3961) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_machine` | `hvf_snap_machine_run` (3976) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `snap_gic` | `hvf_snap_gic_run` (3981) | host/snapshot.bend | dedicated workers (registers), packed mappings (RAM) | 3 | check-host snapshot and restore | bench.sh snapshot-save, boot-restore | C runs the Bend plans; blocked: workers |
| `load` | `hvf_load_run` (1249) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `write` | `hvf_write_run` (1376) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `read` | `hvf_read_run` (1391) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `fw_load` | `hvf_fw_load_run` (4747) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `flash` | `hvf_flash_run` (4785) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `file_size` | `hvf_file_size_run` (1366) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `zero_ram` | `hvf_zero_ram_run` (2032) | host/memory.bend | packed mappings, direct IO | 3 | check-host boot; model: tests/range.bend | boot | C; blocked: toolchain |
| `inflate_ram` | `hvf_inflate_ram_run` (2099) | host/memory.bend over src/lib/inflate.bend | packed buffers, efficient loops | 6 | tests/inflate.bend, tests/oracles/inflate.py; check-host gzip kernel | boot (gzip kernel), compressed qcow2 | C (zlib); Bend spec and oracle done |
| `inflate_disk` | `hvf_inflate_disk_run` (2125) | host/memory.bend over src/lib/inflate.bend | packed buffers, efficient loops | 6 | tests/inflate.bend, tests/oracles/inflate.py; check-host gzip kernel | boot (gzip kernel), compressed qcow2 | C (zlib); Bend spec and oracle done |
| `disk_open_with` | `hvf_disk_open_with_run` (1829) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_status` | `hvf_disk_status_run` (1847) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_err` | `hvf_disk_err_run` (1822) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_size` | `hvf_disk_size_run` (1863) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_flush` | `hvf_disk_flush_run` (1875) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_read` | `hvf_disk_read_run` (1894) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_write` | `hvf_disk_write_run` (1906) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_copy` | `hvf_disk_copy_run` (2007) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_alloc` | `hvf_disk_alloc_run` (2048) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `disk_xcopy` | `hvf_disk_xcopy_run` (2067) | host/disk.bend | packed mappings, direct vectored IO, 64-bit offsets | 3 | check-host disk; model: tests/transfer.bend | guest disk-* | C; short-IO decisions: now, measure |
| `signals` | `hvf_signals_run` (1731) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_log` | `hvf_console_log_run` (5034) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_size` | `hvf_console_size_run` (5044) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `console_reopen` | `hvf_console_reopen_run` (5053) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C opens; Bend plans the renames (Log.moves, 2026-11-11) |
| `err_text` | `hvf_err_text_run` (4609) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `set_args` | `hvf_set_args_run` (1306) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `set_prog` | `hvf_set_prog_run` (1297) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `prog` | `hvf_prog_run` (1302) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `reexec` | `hvf_reexec_run` (1347) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C runs execv; Bend chose the path (2026-11-11) |
| `exe_path` | `hvf_exe_path_run` (1318) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C reports a fact (2026-11-11) |
| `set_exec` | `hvf_set_exec_run` (1336) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C keeps what Bend chose (Files.exec_path, 2026-11-11) |
| `out` | `hvf_out_run` (1554) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `out_flush` | `hvf_out_flush_run` (1610) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin` | `hvf_stdin_run` (1617) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin_tty` | `hvf_stdin_tty_run` (1765) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `stdin_wait` | `hvf_stdin_wait_run` (1772) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `random` | `hvf_random_run` (1633) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `signal_wait` | `hvf_signal_wait_run` (1739) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `log_state` | `hvf_log_state_run` (1592) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `log_put` | `hvf_log_put_run` (1601) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `now` | `hvf_now_run` (1886) | host/main.bend over thin OS calls | OS-call bindings only | 2 | check-host console, log, reset | exit (layout), boot | C; orchestration: now |
| `nofile` | `hvf_nofile_run` (2299) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `set_nofile` | `hvf_set_nofile_run` (2314) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `fd_room` | `hvf_fd_room_run` (2331) | host/main.bend | OS-call bindings only | 2 | check-host descriptor budget | exit (layout) | C acts; Bend decides (Fds) |
| `accept_retry` | `hvf_accept_retry_run` (4329) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `sock_facts` | `hvf_sock_facts_run` (4008) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `sock_remove` | `hvf_sock_remove_run` (4032) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_listen` | `hvf_ctl_listen_run` (4289) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_next` | `hvf_ctl_next_run` (4386) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `ctl_reply` | `hvf_ctl_reply_run` (4398) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_base` | `hvf_vsock_base_run` (4425) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `unix_connect` | `hvf_unix_connect_run` (4440) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_listen` | `hvf_vsock_listen_run` (4481) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_accept` | `hvf_vsock_accept_run` (4585) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `fwd_listen` | `hvf_fwd_listen_run` (4617) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `fwd_accept` | `hvf_fwd_accept_run` (4703) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `vsock_file` | `hvf_vsock_file_run` (4568) | host/main.bend over thin OS calls | OS-call bindings, owned fds | 2 | check-host control, vsock, forwards | exit (layout) | C acts; Bend decides (Clients, Files) |
| `net_limits` | `hvf_net_limits_run` (2196) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_connect` | `hvf_tcp_connect_run` (2437) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_wait` | `hvf_tcp_wait_run` (2479) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_recv` | `hvf_tcp_recv_run` (2505) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_release` | `hvf_tcp_release_run` (2612) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `net_holds` | `hvf_net_holds_run` (2868) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_fill` | `hvf_tcp_fill_run` (2558) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `stage` | `hvf_stage_run` (2633) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `stage_drop` | `hvf_stage_drop_run` (2674) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_send_staged` | `hvf_tcp_send_staged_run` (2770) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `net_copy` | `hvf_net_copy_run` (2586) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_shutdown` | `hvf_tcp_shutdown_run` (2912) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_flush` | `hvf_tcp_flush_run` (2808) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `udp_ages` | `hvf_udp_ages_run` (2999) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `udp_close` | `hvf_udp_close_run` (3016) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_over` | `hvf_tcp_over_run` (2896) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_flush_act` | `hvf_tcp_flush_act_run` (2828) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `nat_send` | `hvf_nat_send_run` (2884) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_close` | `hvf_tcp_close_run` (2952) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_abort` | `hvf_tcp_abort_run` (2975) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `udp_send` | `hvf_udp_send_run` (3029) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `set_dns` | `hvf_set_dns_run` (2258) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `dns` | `hvf_dns_run` (2264) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `udp_recv` | `hvf_udp_recv_run` (3108) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `tcp_close_facts` | `hvf_tcp_close_facts_run` (2943) | host/net.bend | packed buffers, owned fds, direct socket IO | 4 | check-host NAT; tests/nat.bend; model: tests/transfer.bend | guest net-* | C; UDP lookup: now, measure; buffers blocked: toolchain |
| `mkdir` | `hvf_mkdir_run` (4041) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `dir_facts` | `hvf_dir_facts_run` (4052) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_open` | `hvf_lan_open_run` (4115) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_send` | `hvf_lan_send_run` (4174) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_recv` | `hvf_lan_recv_run` (4237) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_to_ram` | `hvf_lan_to_ram_run` (4246) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `lan_release` | `hvf_lan_release_run` (4267) | host/net.bend | packed buffers | 4 | check-host LAN | LAN throughput, exit | C; naming blocked: code layout |
| `share_quota` | `hvf_share_quota_run` (5059) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C; cache policy: now, measure |
| `share_usage` | `hvf_share_usage_run` (5075) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C; cache policy: now, measure |
| `share_open` | `hvf_share_open_run` (3172) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C; cache policy: now, measure |
| `fs` | `hvf_fs_run` (3337) | host/fs.bend over src/host/fdcache.bend | owned fds | 4 | check-host share; model: tests/fdcache.bend | guest 9p-* | C; cache policy: now, measure |
| `fb_init` | `hvf_fb_init_run` (4841) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |
| `fb_dump` | `hvf_fb_dump_run` (4861) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |
| `fb_present` | `hvf_fb_present_run` (4959) | host/display.bend | window buffer presentation | 5 | check-host screendump | display (to add) | C and Objective-C; blocked: toolchain |

### Baseline (stage 0, Apple M2 Pro, macOS 27.2, Bend 2.0.40)

`scripts/bench/ab.sh -n 30 -m exit,boot f8983a4 f8983a4` (the same build
against itself, 2026-11-11): exit 3.49 us per UART store, paired
difference 95% interval [-0.035, +0.018] us; tiny-Linux boot 255 ms,
[-2.5, +3.3] ms. That is the noise floor a change's A/B must beat to
read as faster or slower; with no equivalence margin (a decision the plan
leaves open) an equally fast change reads as inconclusive. KVM baselines
wait for a physical arm64 host.
