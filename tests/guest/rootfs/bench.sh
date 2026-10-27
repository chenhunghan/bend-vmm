# The in-guest half of scripts/bench.sh (kernel command line `bendbench`):
# prints `BENCH <name> <value> <unit>` lines. /bin/bench (tests/guest/bench.c)
# times the device paths; the rest uses /proc/uptime (10 ms), so every
# transfer is sized to take a while.
up() { cut -d' ' -f1 /proc/uptime; }
# rate <name> <bytes> <start> <end>
rate() {
  awk -v n="$1" -v b="$2" -v s="$3" -v e="$4" 'BEGIN { d = e - s; if (d < 0.01) d = 0.01; printf "BENCH %s %.1f MB/s %.2fs\n", n, b / 1048576 / d, d }'
}
echo "BENCH guest-init $(up) s"
/bin/bench mmio
# on vCPU 0, where the device interrupt lands: from another vCPU each
# request also waits for an IPI to wake it (about 80us on Hypervisor.framework)
[ -b /dev/vda ] && /bin/bench disk /dev/vda 0
port=$(sed -n 's/.*benchttp=\([0-9]*\).*/\1/p' /proc/cmdline)
if [ -n "$port" ] && [ -e /sys/class/net/eth0 ]; then
  ip link set lo up; ip link set eth0 up
  udhcpc -i eth0 -q -t 5 -T 1 -n >/dev/null 2>&1
  bytes=$(wget -q -O - "http://10.0.2.2:$port/size")
  s=$(up); /bin/bench on 0 /bin/wget -q -O /dev/null "http://10.0.2.2:$port/big"; e=$(up)
  rate net-download $bytes $s $e
  # upload: the host's sink (scripts/bench/sink.py) on the next port takes
  # $bytes bytes and closes
  s=$(up); dd if=/dev/zero bs=1048576 count=$((bytes / 1048576)) 2>/dev/null | /bin/bench on 0 /bin/nc 10.0.2.2 $((port + 1)); e=$(up)
  rate net-upload $bytes $s $e
  # the same through the NAT with no tool in between (/bin/bench reads and
  # writes 1 MiB at a time): the host's source on port + 2 sends $bytes
  /bin/bench on 0 /bin/bench recv 10.0.2.2 $((port + 2))
  /bin/bench on 0 /bin/bench send 10.0.2.2 $((port + 1)) $bytes
  s=$(up); i=0; while [ $i -lt 50 ]; do wget -q -O /dev/null "http://10.0.2.2:$port/size"; i=$((i + 1)); done; e=$(up)
  awk -v s=$s -v e=$e 'BEGIN { printf "BENCH net-http-request %.1f ms\n", (e - s) * 1000 / 50 }'
fi
if grep -qs share /sys/bus/virtio/drivers/9pnet_virtio/*/mount_tag; then
  msize=$(sed -n 's/.*benchmsize=\([0-9]*\).*/\1/p' /proc/cmdline)
  mkdir -p /mnt/share && mount -t 9p -o trans=virtio,version=9p2000.L,msize=${msize:-524288} share /mnt/share
  bytes=$(cat /mnt/share/size)
  s=$(up); /bin/bench on 0 /bin/dd if=/mnt/share/big of=/dev/null bs=1M 2>/dev/null; e=$(up)
  rate 9p-read $bytes $s $e
  # not pinned: the guest's writeback works beside dd (pinned to vCPU 0
  # with it, writes ran at a third of the speed)
  s=$(up); /bin/dd if=/dev/zero of=/mnt/share/out bs=1M count=$((bytes / 1048576)) 2>/dev/null; e=$(up)
  rate 9p-write $bytes $s $e
  s=$(up); i=0; while [ $i -lt 200 ]; do stat /mnt/share/size >/dev/null; i=$((i + 1)); done; e=$(up)
  awk -v s=$s -v e=$e 'BEGIN { printf "BENCH 9p-stat %.2f ms\n", (e - s) * 1000 / 200 }'
  rm -f /mnt/share/out
fi
echo "BENCH-DONE"
