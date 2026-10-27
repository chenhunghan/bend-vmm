# The in-guest half of scripts/soak.sh (kernel command line bendsoak=MINUTES
# benchttp=PORT): for MINUTES, round after round, writes random data to the
# disk, the shared folder and memory and reads it back, downloads a file from
# the host and checks its digest, and keeps the other CPUs busy. Prints
# SOAK-ITER <n> <seconds> after each round, SOAK-FAIL <what> <n> on a
# mismatch, and SOAK-DONE <rounds> at the end.
up() { cut -d. -f1 /proc/uptime; }
mins=$(sed -n 's/.*bendsoak=\([0-9]*\).*/\1/p' /proc/cmdline)
port=$(sed -n 's/.*benchttp=\([0-9]*\).*/\1/p' /proc/cmdline)
ip link set lo up; ip link set eth0 up
udhcpc -i eth0 -q -t 5 -T 1 -n >/dev/null 2>&1
mkdir -p /mnt/share && mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share
want=$(wget -q -O - "http://10.0.2.2:$port/big.md5")
mb=$(( $(cat /sys/block/vda/size) / 2048 ))
# the other CPUs: a digest loop each, until the soak ends
n=1; while [ $n -lt "$(nproc)" ]; do
  (while [ ! -e /tmp/stop ]; do dd if=/dev/zero bs=1M count=16 2>/dev/null | md5sum >/dev/null; done) &
  n=$((n + 1))
done
end=$(( $(up) + mins * 60 )); i=0
while [ "$(up)" -lt "$end" ]; do
  i=$((i + 1)); s=$(up)
  dd if=/dev/urandom of=/tmp/r bs=1M count=4 2>/dev/null
  sum=$(md5sum < /tmp/r)
  off=$(( (i * 4) % (mb - 4) ))
  dd if=/tmp/r of=/dev/vda bs=1M seek=$off conv=fsync 2>/dev/null
  echo 3 > /proc/sys/vm/drop_caches
  [ "$(dd if=/dev/vda bs=1M skip=$off count=4 2>/dev/null | md5sum)" = "$sum" ] || echo "SOAK-FAIL disk $i"
  cp /tmp/r /mnt/share/soak.$i
  [ "$(md5sum < /mnt/share/soak.$i)" = "$sum" ] || echo "SOAK-FAIL 9p $i"
  rm -f /mnt/share/soak.$i
  [ "$(wget -q -O - "http://10.0.2.2:$port/big" | md5sum | cut -d' ' -f1)" = "$want" ] || echo "SOAK-FAIL net $i"
  echo "SOAK-ITER $i $(( $(up) - s ))"
  [ $((i % 100)) = 0 ] && echo "SOAK-MEM $i $(awk '/MemAvailable|^Slab|Shmem:|^Buffers|^Cached/ { printf "%s %s ", $1, $2 }' /proc/meminfo)"
done
touch /tmp/stop
echo "SOAK-DONE $i"
