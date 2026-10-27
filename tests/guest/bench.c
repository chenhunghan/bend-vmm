// The guest's benchmark program (scripts/bench.sh, in-guest /bench.sh):
// freestanding arm64 Linux, raw syscalls, no libc.
//   bench disk DEV [CPU]  sequential read and write (1 MiB, O_DIRECT) over
//                    the whole device, and random 4 KiB reads (O_DIRECT,
//                    QD1); on vCPU CPU when given
//   bench mmio       guest exits: 100000 reads of the PL031 RTC's data
//                    register through /dev/mem (each one traps to the VMM)
//   bench send IP PORT BYTES  TCP upload: BYTES in 1 MiB writes to IP:PORT
//   bench recv IP PORT        TCP download: reads IP:PORT to its end
//                    (no tool in between: the NAT's own rate)
//   bench on CPU PROG ARGS...  runs PROG on vCPU CPU only (where the devices'
//                    interrupts land, so no IPI wakes it: steadier numbers)
// Prints `BENCH <name> <value> <unit>` lines.

typedef unsigned long u64;
typedef long i64;

static i64 sys(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
  register i64 x8 __asm__("x8") = n;
  register i64 x0 __asm__("x0") = a;
  register i64 x1 __asm__("x1") = b;
  register i64 x2 __asm__("x2") = c;
  register i64 x3 __asm__("x3") = d;
  register i64 x4 __asm__("x4") = e;
  register i64 x5 __asm__("x5") = f;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
  return x0;
}

#define SYS_openat 56
#define SYS_close 57
#define SYS_pread64 67
#define SYS_pwrite64 68
#define SYS_write 64
#define SYS_exit 93
#define SYS_fsync 82
#define SYS_mmap 222
#define SYS_clock_gettime 113
#define SYS_ioctl 29
#define SYS_sched_setaffinity 122
#define SYS_execve 221
#define SYS_read 63
#define SYS_socket 198
#define SYS_connect 203
#define SYS_shutdown 210
#define AT_FDCWD -100
#define O_RDONLY 0
#define O_RDWR 2
#define O_SYNC 04010000
#define O_DIRECT 0200000
#define BLKGETSIZE64 0x80081272

void* memset(void* d, int c, u64 n) {
  unsigned char* p = d;
  while (n--) *p++ = (unsigned char)c;
  return d;
}
void* memcpy(void* d, const void* s, u64 n) {
  unsigned char* p = d;
  const unsigned char* q = s;
  while (n--) *p++ = *q++;
  return d;
}

static u64 now_ns(void) {
  struct { i64 s, ns; } t;
  sys(SYS_clock_gettime, 1, (i64)&t, 0, 0, 0, 0);
  return (u64)t.s * 1000000000ul + (u64)t.ns;
}

static char out[256];
static int olen;
static void put(const char* s) { while (*s) out[olen++] = *s++; }
static void putu(u64 v) {
  char b[24];
  int i = 0;
  do { b[i++] = '0' + v % 10; v /= 10; } while (v);
  while (i) out[olen++] = b[--i];
}
// v / 10 with one decimal
static void putd(u64 tenths) { putu(tenths / 10); out[olen++] = '.'; putu(tenths % 10); }
static void flush(void) {
  out[olen++] = '\n';
  sys(SYS_write, 1, (i64)out, olen, 0, 0, 0);
  olen = 0;
}
static int eq(const char* a, const char* b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

static unsigned char buf[(1 << 20) + 4096];

static void rate(const char* name, u64 bytes, u64 ns) {
  put("BENCH "); put(name); put(" ");
  putd((bytes >> 20) * 10000000000ul / (ns ? ns : 1));
  put(" MB/s");
  flush();
}

static int disk(const char* dev) {
  unsigned char* b = (unsigned char*)(((u64)buf + 4095) & ~4095ul);
  i64 fd = sys(SYS_openat, AT_FDCWD, (i64)dev, O_RDWR | O_DIRECT, 0, 0, 0);
  if (fd < 0) { put("bench: cannot open the disk"); flush(); return 1; }
  u64 size = 0;
  sys(SYS_ioctl, fd, BLKGETSIZE64, (i64)&size, 0, 0, 0);
  u64 mib = size >> 20;
  u64 t = now_ns();
  for (u64 i = 0; i < mib; i++) sys(SYS_pread64, fd, (i64)b, 1 << 20, i << 20, 0, 0);
  rate("disk-read", mib << 20, now_ns() - t);
  memset(b, 0x5a, 1 << 20);
  t = now_ns();
  for (u64 i = 0; i < mib; i++) sys(SYS_pwrite64, fd, (i64)b, 1 << 20, i << 20, 0, 0);
  sys(SYS_fsync, fd, 0, 0, 0, 0, 0);
  rate("disk-write", mib << 20, now_ns() - t);
  u64 blocks = size >> 12, x = 88172645463325252ul, n = 4000;
  t = now_ns();
  for (u64 i = 0; i < n; i++) {
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    sys(SYS_pread64, fd, (i64)b, 4096, (x % blocks) << 12, 0, 0);
  }
  u64 ns = now_ns() - t;
  put("BENCH disk-4k-read "); putu(n * 1000000000ul / ns); put(" IOPS"); flush();
  put("BENCH disk-4k-latency "); putd(ns / n / 100); put(" us"); flush();
  sys(SYS_close, fd, 0, 0, 0, 0, 0);
  return 0;
}

static int mmio(void) {
  i64 fd = sys(SYS_openat, AT_FDCWD, (i64)"/dev/mem", O_RDONLY | O_SYNC, 0, 0, 0);
  if (fd < 0) { put("bench: cannot open /dev/mem"); flush(); return 1; }
  // PROT_READ, MAP_SHARED; the PL031 is at 0x09010000
  volatile unsigned* rtc = (volatile unsigned*)sys(SYS_mmap, 0, 4096, 1, 1, fd, 0x09010000);
  if ((i64)rtc < 0 && (i64)rtc > -4096) { put("bench: cannot map the RTC"); flush(); return 1; }
  u64 n = 100000, sum = 0;
  u64 t = now_ns();
  for (u64 i = 0; i < n; i++) sum += rtc[0];
  u64 ns = now_ns() - t;
  put("BENCH mmio-exit "); putd(ns / n / 100); put(" us"); flush();
  return (int)(sum & 0);
}

static u64 num(const char* s) {
  u64 v = 0;
  while (*s >= '0' && *s <= '9') v = v * 10 + (u64)(*s++ - '0');
  return v;
}

// A connection to a dotted IPv4 address and a port; the fd, or < 0.
static i64 dial(const char* ip, const char* port) {
  unsigned a = 0;
  for (int k = 0; k < 4; k++) {
    a = a << 8 | (unsigned)num(ip);
    while (*ip && *ip != '.') ip++;
    if (*ip) ip++;
  }
  unsigned short p = (unsigned short)num(port);
  struct { unsigned short fam, port; unsigned addr; char zero[8]; } sa = {2, (unsigned short)(p >> 8 | p << 8),
    (a >> 24) | (a >> 8 & 0xff00) | (a << 8 & 0xff0000) | (a << 24), {0}};
  i64 fd = sys(SYS_socket, 2, 1, 0, 0, 0, 0);
  if (fd < 0 || sys(SYS_connect, fd, (i64)&sa, sizeof sa, 0, 0, 0) < 0) { put("bench: cannot connect"); flush(); return -1; }
  return fd;
}

static int net(int up, const char* ip, const char* port, u64 bytes) {
  i64 fd = dial(ip, port);
  if (fd < 0) return 1;
  u64 done = 0, t = now_ns();
  if (up) {
    memset(buf, 0x5a, 1 << 20);
    while (done < bytes) {
      u64 n = bytes - done < (1 << 20) ? bytes - done : (1 << 20);
      i64 k = sys(SYS_write, fd, (i64)buf, (i64)n, 0, 0, 0);
      if (k <= 0) break;
      done += (u64)k;
    }
    sys(SYS_shutdown, fd, 1, 0, 0, 0, 0);
    // the host's sink closes once it has every byte: wait for that
    while (sys(SYS_read, fd, (i64)buf, 1 << 20, 0, 0, 0) > 0) {}
  } else {
    for (i64 k; (k = sys(SYS_read, fd, (i64)buf, 1 << 20, 0, 0, 0)) > 0;) done += (u64)k;
  }
  u64 ns = now_ns() - t;
  sys(SYS_close, fd, 0, 0, 0, 0, 0);
  rate(up ? "net-upload-raw" : "net-download-raw", done, ns);
  return 0;
}

void _start_c(u64* sp) {
  int argc = (int)sp[0];
  char** argv = (char**)(sp + 1);
  int rc = 2;
  if (argc >= 4 && eq(argv[1], "on")) {
    u64 mask = 1ul << (argv[2][0] - '0');
    sys(SYS_sched_setaffinity, 0, sizeof mask, (i64)&mask, 0, 0, 0);
    sys(SYS_execve, (i64)argv[3], (i64)(argv + 3), (i64)(argv + argc + 1), 0, 0, 0);
    sys(SYS_exit, 127, 0, 0, 0, 0, 0);
  }
  if (argc >= 4 && eq(argv[1], "disk")) {
    u64 mask = 1ul << (argv[3][0] - '0');
    sys(SYS_sched_setaffinity, 0, sizeof mask, (i64)&mask, 0, 0, 0);
  }
  if (argc >= 3 && eq(argv[1], "disk")) rc = disk(argv[2]);
  else if (argc >= 2 && eq(argv[1], "mmio")) rc = mmio();
  else if (argc >= 5 && eq(argv[1], "send")) rc = net(1, argv[2], argv[3], num(argv[4]));
  else if (argc >= 4 && eq(argv[1], "recv")) rc = net(0, argv[2], argv[3], 0);
  sys(SYS_exit, rc, 0, 0, 0, 0, 0);
}

__asm__(".global _start\n_start:\n  mov x0, sp\n  bl _start_c\n");
