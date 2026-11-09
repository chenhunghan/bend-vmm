# What host/hvf.c does, and what it decides

bend-vmm's rule: Bend decides and C acts. Every choice (a policy, limit,
order, format or validation) is made in pure Bend under `src/`, with laws.
`host/hvf.c` holds the effects Bend cannot perform: hypervisor calls,
system calls, threads, memory copies and drawing. It reports facts and
carries out plans that Bend hands it.

This file is the audit of that boundary. It covers all 111 effects in
host/hvf.c as of 2026-11-09 and says, for each group, where the
decisions are made. The last section lists every decision still in C,
with the reason it stays.

## The effects by group

| Group | Effects | C does | Bend decides (src/) |
|---|---|---|---|
| Hypervisor | `init` `vcpu` `vcpu_queue` `irq` `kick` `pause` `resume` `pause_state` | creates the VM and vCPUs, runs them, reports exits as facts (KVM's raw, kind 2000 + reason) | everything about the machine; KVM exits become the machine's terms in `arm64/kvmexit.bend` |
| Snapshots | `snap_save` `snap_commit` `snap_drop` `snap_open` `snap_peek` `snap_load` `snap_info` `snap_args` `snap_machine` `snap_gic` `snap_plans` `rename` | reads and writes the registers and the vGIC that a plan names, and moves byte ranges | file layout and placement (`vmm/snapfile.bend`), vGIC replay order (`arm64/gicplan.bend`), registers kept (`arm64/regplan.bend`), file mode (`vmm/hostfiles.bend`) |
| Memory and images | `load` `read` `write` `file_size` `zero_ram` `inflate_ram` `inflate_disk` `flash` `fw_load` | copies files into guest RAM; inflates gzip and deflate | whether to inflate (`boot/image.bend`), where things go (`vmm/layout.bend`), whether firmware fits (`Layout.flash_fits`) |
| Disks | `disk_open_with` `disk_err` `disk_read` `disk_write` `disk_copy` `disk_xcopy` `disk_alloc` `disk_flush` `disk_size` `disk_status` | moves bytes between images and guest memory; opens and locks images | how each use opens and locks (`disk/access.bend`), read-only fallback, qcow2 (`src/disk`) |
| Console and process | `out` `out_flush` `stdin` `stdin_tty` `stdin_wait` `log_state` `log_put` `console_log` `console_size` `console_rotate` `signal_wait` `set_args` `set_prog` `prog` `reexec` `err_text` `now` `random` | terminal, pipes, signals, re-exec, clock, entropy | log gate (`vmm/loggate.bend`), log rotation (`dev/conlog.bend`), escape keys, file modes |
| NAT | `tcp_*` `udp_*` `nat_send` `net_copy` `net_holds` `net_limits` `stage` `stage_drop` `dns` `set_dns` | sockets, send buffers, parking, wakeups | the whole NAT (`src/net`), limits (`net/limits.bend`), flusher actions (`net/flush.bend`), UDP flows (`net/udpflow.bend`) |
| Descriptors | `nofile` `set_nofile` `fd_room` | reads and sets rlimit; counts sockets | soft limit and flow budget (`net/fds.bend`) |
| Sockets and listeners | `ctl_listen` `ctl_next` `ctl_reply` `vsock_listen` `vsock_accept` `vsock_base` `vsock_file` `unix_connect` `fwd_listen` `fwd_accept` `sock_facts` `sock_remove` | binds, accepts, connects; reports what a path holds | protocol (`vmm/control.bend`), deadlines and CONNECT (`vmm/clients.bend`), forward specs (`vmm/cli.bend`), which paths may be listened on (`vmm/hostfiles.bend`) |
| LAN | `lan_open` `lan_send` `lan_recv` `lan_to_ram` `lan_release` `mkdir` `dir_facts` | datagram sockets, one frame per datagram | where frames go (`virtio/lan.bend`), directory trust and socket replacement (`vmm/hostfiles.bend`) |
| Shares (9p) | `fs` `share_open` `share_quota` `share_usage` | walks paths with openat and O_NOFOLLOW; keeps a descriptor cache | valid names (`fs/contain.bend`), listing order and pages (`fs/listing.bend`), entries, types and modes (`fs/entry.bend`), quota (`fs/quota.bend`) |
| Display | `fb_init` `fb_present` `fb_dump` | maps the framebuffer, draws it with Metal, writes PPM | display size (`Cli.display.fits`), pointer and keys (`dev/pointer.bend`), file mode |

## Decisions still in C, and why

| Decision | Where | Why it stays |
|---|---|---|
| A share opens only regular files for reads and writes | `hvf_fs_run` | Moving it costs a round trip on every open that misses the descriptor cache, on the 9p hot path. `check-host` tests it. |
| The 9p descriptor cache (16 entries, least recently used) | `hvf_fdc_*` | Per operation, so on the hot path. |
| gzip and deflate decoding | `hvf_inflate` | Decoding a ~30 MB kernel in Bend would cost far more than the 0.55 s boot. Bend decides whether to inflate. |
| LAN socket names for the frames C sends | `hvf_lan_name` | Per frame. The same format is in Bend (`Files.lan_sock`, with a law), which names this VM's own socket. |
| Listen backlogs (4, 16, 64); a 100 ms retry while out of descriptors | listeners | Tuning of mechanism, not a policy. |
| SIGTERM, SIGINT and SIGHUP are caught | `hvf_sig_init` | Set in a constructor, before Bend runs. What a signal does is Bend's. |
| Snapshot version (1 on HVF, 2 on KVM) | `HVF_SNAP_VER` | Names the format the C reader writes; Bend checks it. |
| Memory-safety caps (sizes, counts, path lengths) | throughout | Defence in depth beneath Bend's own checks; never the only check. |

Moving any of these: A/B the exit path with 30 interleaved pairs before
pushing. Bend compiles the program as one state machine, so a change far
from the hot path can still move exit latency
(docs/DESIGN.md, "Less C").
