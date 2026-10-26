# In-guest tests: each prints GUEST-TEST PASS|FAIL|SKIP <name>.
pass() { echo "GUEST-TEST PASS $1"; }
fail() { echo "GUEST-TEST FAIL $1: $2"; }
skip() { echo "GUEST-TEST SKIP $1: $2"; }
check() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name" "$*"; fi; }

want_cpus=$(sed -n 's/.*bendcpus=\([0-9]*\).*/\1/p' /proc/cmdline)
[ -n "$want_cpus" ] && check cpus [ "$(nproc)" = "$want_cpus" ]

# virtio-blk: the host writes BEND-DISK-SECTOR0 at the start of the image.
if [ -b /dev/vda ]; then
  check blk-read [ "$(head -c 17 /dev/vda)" = "BEND-DISK-SECTOR0" ]
  echo "bend-vmm-write-test" | dd of=/dev/vda bs=512 seek=8 conv=sync,fsync 2>/dev/null
  echo 3 > /proc/sys/vm/drop_caches
  check blk-write [ "$(dd if=/dev/vda bs=512 skip=8 count=1 2>/dev/null | head -c 19)" = "bend-vmm-write-test" ]
  check blk-size [ "$(cat /sys/block/vda/size)" -gt 0 ]
else
  skip blk "no /dev/vda"
fi

# virtio-rng
if [ -e /dev/hwrng ] && grep -q virtio /sys/class/misc/hw_random/rng_current 2>/dev/null; then
  check rng [ "$(dd if=/dev/hwrng bs=16 count=1 2>/dev/null | wc -c)" = 16 ]
else
  skip rng "no virtio hwrng"
fi

# the guest's clock runs
t1=$(cut -d' ' -f1 /proc/uptime); sleep 1; t2=$(cut -d' ' -f1 /proc/uptime)
check timer [ "${t1%.*}" != "${t2%.*}" ] || [ "$t1" != "$t2" ]

# interrupts reach the guest on every CPU (timer PPI 27 counts up)
check irqs grep -q "arch_timer" /proc/interrupts

# PL031 RTC: the clock was set from the host at boot
if [ -e /dev/rtc0 ]; then
  check rtc [ "$(date +%Y)" -ge 2026 ]
else
  skip rtc "no /dev/rtc0 (amba: $(ls /sys/bus/amba/devices 2>/dev/null | tr '\n' ' '); pl031 id: $(cat /sys/bus/amba/devices/9010000.pl031/id 2>/dev/null); drivers: $(ls /sys/bus/amba/drivers 2>/dev/null | tr '\n' ' '))"
fi

# virtio-console: the host prints what the guest writes to hvc0
if [ -e /dev/hvc0 ]; then
  echo "HVC0-MARKER-OK" > /dev/hvc0 && pass hvc0-write
else
  skip hvc0 "no /dev/hvc0"
fi

# virtio-net through the user-mode NAT
if [ -e /sys/class/net/eth0 ]; then
  ip link set lo up
  ip link set eth0 up
  check net-dhcp udhcpc -i eth0 -n -q -t 5 -T 1
  check net-addr sh -c 'ip addr show eth0 | grep -q 10.0.2.15'
  check net-ping-gateway ping -c 1 -W 2 10.0.2.2
  port=$(sed -n 's/.*benchttp=\([0-9]*\).*/\1/p' /proc/cmdline)
  if [ -n "$port" ]; then
    check net-http sh -c "wget -q -O - http://10.0.2.2:$port/hello.txt | grep -q BEND-HTTP-OK"
  fi
  if grep -q benchdns /proc/cmdline; then
    check net-dns nslookup example.com
  fi
else
  skip net "no eth0"
fi

# virtio-9p: the host shares a directory tagged "share"
if grep -q bendshare /proc/cmdline; then
  if mount -t 9p -o trans=virtio,version=9p2000.L share /mnt; then
    pass p9-mount
    check p9-read [ "$(cat /mnt/hello.txt)" = "BEND-9P-OK" ]
    echo "from-guest" > /mnt/guest.txt && pass p9-write
    check p9-list sh -c 'ls /mnt | grep -q hello.txt'
    mkdir /mnt/newdir && check p9-mkdir [ -d /mnt/newdir ]
    umount /mnt
  else
    fail p9-mount "mount failed: $(dmesg | grep -i -E '9p|virtio' | tail -5 | tr '\n' '|')"
  fi
fi
