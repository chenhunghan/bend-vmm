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
