// bend-vmm host layer: Hypervisor.framework effects for Bend (macOS, arm64).
//
// One VM per process. Guest RAM is one anonymous mapping at a fixed IPA.
// Each vCPU lives on its own pthread, because Hypervisor.framework only
// lets the creating thread run a vCPU or touch its registers. A Bend effect
// on a vCPU posts a request to that thread and parks on the thread's pipe
// (io_wait_on), so the Bend event loop keeps serving other vCPUs while a
// guest runs. Results come back as a list of U32 words; the pure side
// decodes them (host/hvf.bend).
//
// Hypervisor.framework is opened with dlopen, so the binary links without
// extra flags; it still needs the com.apple.security.hypervisor entitlement.

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <Hypervisor/Hypervisor.h>

#define HVF_MAX_CPUS 64
#define HVF_ERR      0xFFFFFFFFu

// Hypervisor.framework entry points, resolved once.
static struct {
  void* lib;
  __typeof__(&hv_vm_create) vm_create;
  __typeof__(&hv_vm_map) vm_map;
  __typeof__(&hv_vcpu_create) vcpu_create;
  __typeof__(&hv_vcpu_run) vcpu_run;
  __typeof__(&hv_vcpu_get_reg) get_reg;
  __typeof__(&hv_vcpu_set_reg) set_reg;
  __typeof__(&hv_vcpu_set_sys_reg) set_sys_reg;
  __typeof__(&hv_vcpu_set_vtimer_mask) set_vtimer_mask;
  __typeof__(&hv_vcpus_exit) vcpus_exit;
  __typeof__(&hv_gic_config_create) gic_config_create;
  __typeof__(&hv_gic_config_set_distributor_base) gic_set_dist;
  __typeof__(&hv_gic_config_set_redistributor_base) gic_set_redist;
  __typeof__(&hv_gic_create) gic_create;
  __typeof__(&hv_gic_set_spi) gic_set_spi;
} hv;

static int hvf_open(void) {
  if (hv.lib) {
    return 0;
  }
  hv.lib = dlopen("/System/Library/Frameworks/Hypervisor.framework/Hypervisor", RTLD_NOW);
  if (!hv.lib) {
    return -1;
  }
#define HV_SYM(field, name) hv.field = (__typeof__(hv.field))dlsym(hv.lib, #name)
  HV_SYM(vm_create, hv_vm_create);
  HV_SYM(vm_map, hv_vm_map);
  HV_SYM(vcpu_create, hv_vcpu_create);
  HV_SYM(vcpu_run, hv_vcpu_run);
  HV_SYM(get_reg, hv_vcpu_get_reg);
  HV_SYM(set_reg, hv_vcpu_set_reg);
  HV_SYM(set_sys_reg, hv_vcpu_set_sys_reg);
  HV_SYM(set_vtimer_mask, hv_vcpu_set_vtimer_mask);
  HV_SYM(vcpus_exit, hv_vcpus_exit);
  HV_SYM(gic_config_create, hv_gic_config_create);
  HV_SYM(gic_set_dist, hv_gic_config_set_distributor_base);
  HV_SYM(gic_set_redist, hv_gic_config_set_redistributor_base);
  HV_SYM(gic_create, hv_gic_create);
  HV_SYM(gic_set_spi, hv_gic_set_spi);
#undef HV_SYM
  return hv.vm_create && hv.gic_create ? 0 : -1;
}

// Guest RAM
// =========

static uint8_t* hvf_ram;
static uint64_t hvf_ram_base;
static uint64_t hvf_ram_size;

// A host pointer for [gpa, gpa+len) inside RAM, or NULL.
static uint8_t* hvf_ptr(uint64_t gpa, uint64_t len) {
  if (gpa < hvf_ram_base || len > hvf_ram_size || gpa - hvf_ram_base > hvf_ram_size - len) {
    return NULL;
  }
  return hvf_ram + (gpa - hvf_ram_base);
}

static uint64_t hvf_u64(Term hi, Term lo) {
  return ((uint64_t)(u32)hi << 32) | (u32)lo;
}

// A Bend list of U32 words.
static Term hvf_words(Env e, const uint32_t* w, u64 n) {
  Term xs = term_pak(CID(Nil), 0);
  for (u64 i = n; i > 0; i -= 1) {
    xs = io_node(e, CID(Con), (Term)w[i - 1], xs);
  }
  return xs;
}

// vCPU threads
// ============

enum { OP_CREATE, OP_RUN, OP_SET_REG, OP_GET_REG, OP_SET_VTIMER_MASK };

typedef struct {
  int             live;
  pthread_t       thread;
  pthread_mutex_t mu;
  pthread_cond_t  cv;
  int             pipe[2];
  int             busy;     // a request waits for the thread
  int             op;
  uint64_t        a, b;
  uint32_t        out[20];  // the answer, in words
  u64             nout;
  hv_vcpu_t       vcpu;
  hv_vcpu_exit_t* exit;
} HvfCpu;

static HvfCpu hvf_cpus[HVF_MAX_CPUS];

// BEND_VMM_TRACE: bit 1 prints every exception exit on stderr, bit 2 the
// console input and interrupt line changes.
static int hvf_trace;

static void hvf_put64(HvfCpu* c, uint64_t v) {
  c->out[c->nout++] = (uint32_t)(v >> 32);
  c->out[c->nout++] = (uint32_t)v;
}

static uint64_t hvf_reg(HvfCpu* c, hv_reg_t r) {
  uint64_t v = 0;
  hv.get_reg(c->vcpu, r, &v);
  return v;
}

// Runs the guest until an exit and encodes it as
// [kind, esr, far, ipa, x0, x1, x2, x3, xt] (each 64-bit value as hi, lo):
// kind 0 exception, 1 vtimer, 2 canceled, 3 + reason otherwise.
static void hvf_run(HvfCpu* c) {
  hv_return_t r = hv.vcpu_run(c->vcpu);
  if (r != HV_SUCCESS) {
    c->out[c->nout++] = 1000 + (uint32_t)(r & 0xffff);
    return;
  }
  switch (c->exit->reason) {
    case HV_EXIT_REASON_EXCEPTION: {
      uint64_t esr = c->exit->exception.syndrome;
      c->out[c->nout++] = 0;
      hvf_put64(c, esr);
      hvf_put64(c, c->exit->exception.virtual_address);
      hvf_put64(c, c->exit->exception.physical_address);
      for (int i = 0; i < 4; i++) {
        hvf_put64(c, hvf_reg(c, (hv_reg_t)(HV_REG_X0 + i)));
      }
      // ISV set: the store's source register, so the pure side needs no
      // round trip to read it. SRT 31 is XZR.
      uint32_t srt = (uint32_t)(esr >> 16) & 31;
      int isv = (esr >> 24) & 1;
      hvf_put64(c, isv && srt != 31 ? hvf_reg(c, (hv_reg_t)(HV_REG_X0 + srt)) : 0);
      if (hvf_trace & 1) {
        fprintf(stderr, "[trace] esr=%08llx ipa=%09llx x0=%llx xt=%llx pc=%llx\n",
          (unsigned long long)esr, (unsigned long long)c->exit->exception.physical_address,
          (unsigned long long)hvf_reg(c, HV_REG_X0),
          (unsigned long long)(isv && srt != 31 ? hvf_reg(c, (hv_reg_t)(HV_REG_X0 + srt)) : 0),
          (unsigned long long)hvf_reg(c, HV_REG_PC));
      }
      break;
    }
    case HV_EXIT_REASON_VTIMER_ACTIVATED:
      c->out[c->nout++] = 1;
      break;
    case HV_EXIT_REASON_CANCELED:
      c->out[c->nout++] = 2;
      break;
    default:
      c->out[c->nout++] = 3 + (uint32_t)c->exit->reason;
      break;
  }
}

static void hvf_do(HvfCpu* c, int cpu) {
  c->nout = 0;
  switch (c->op) {
    case OP_CREATE: {
      hv_return_t r = hv.vcpu_create(&c->vcpu, &c->exit, NULL);
      if (r == HV_SUCCESS) {
        // Aff0 = cpu index; bit 31 is RES1. The GIC routes by affinity.
        r = hv.set_sys_reg(c->vcpu, HV_SYS_REG_MPIDR_EL1, (1ull << 31) | (uint64_t)cpu);
      }
      c->out[c->nout++] = r == HV_SUCCESS ? 0 : (uint32_t)r;
      break;
    }
    case OP_RUN:
      hvf_run(c);
      break;
    case OP_SET_REG: {
      // a: our register number (0..30 Xn, 31 PC, 32 CPSR), b: value
      hv_reg_t reg = c->a <= 30 ? (hv_reg_t)(HV_REG_X0 + c->a) : c->a == 31 ? HV_REG_PC : HV_REG_CPSR;
      c->out[c->nout++] = hv.set_reg(c->vcpu, reg, c->b) == HV_SUCCESS ? 0 : HVF_ERR;
      break;
    }
    case OP_GET_REG: {
      hv_reg_t reg = c->a <= 30 ? (hv_reg_t)(HV_REG_X0 + c->a) : c->a == 31 ? HV_REG_PC : HV_REG_CPSR;
      hvf_put64(c, hvf_reg(c, reg));
      break;
    }
    case OP_SET_VTIMER_MASK:
      c->out[c->nout++] = hv.set_vtimer_mask(c->vcpu, c->a != 0) == HV_SUCCESS ? 0 : HVF_ERR;
      break;
  }
}

static void* hvf_thread(void* arg) {
  int     cpu = (int)(intptr_t)arg;
  HvfCpu* c   = &hvf_cpus[cpu];
  pthread_mutex_lock(&c->mu);
  for (;;) {
    while (!c->busy) {
      pthread_cond_wait(&c->cv, &c->mu);
    }
    pthread_mutex_unlock(&c->mu);
    hvf_do(c, cpu);
    pthread_mutex_lock(&c->mu);
    c->busy = 0;
    char b = 1;
    (void)!write(c->pipe[1], &b, 1);
  }
  return NULL;
}

// Effects
// =======

// Hvf.init(ram_mb, gicd_hi, gicd_lo, gicr_hi, gicr_lo, ram_hi, ram_lo) -> U32:
// creates the VM, its GICv3 and RAM. 0 on success, else a step code.
Term hvf_init_run(Env e, Term* f, IoWork* w) {
  if (hvf_open() != 0) {
    return (Term)1;
  }
  hvf_trace = getenv("BEND_VMM_TRACE") ? atoi(getenv("BEND_VMM_TRACE")) : 0;
  if (hv.vm_create(NULL) != HV_SUCCESS) {
    return (Term)2;
  }
  hv_gic_config_t gic = hv.gic_config_create();
  if (hv.gic_set_dist(gic, hvf_u64(f[1], f[2])) != HV_SUCCESS
      || hv.gic_set_redist(gic, hvf_u64(f[3], f[4])) != HV_SUCCESS
      || hv.gic_create(gic) != HV_SUCCESS) {
    return (Term)3;
  }
  hvf_ram_size = (uint64_t)(u32)f[0] << 20;
  hvf_ram_base = hvf_u64(f[5], f[6]);
  hvf_ram = mmap(NULL, hvf_ram_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (hvf_ram == MAP_FAILED) {
    return (Term)4;
  }
  if (hv.vm_map(hvf_ram, hvf_ram_base, hvf_ram_size,
        HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC) != HV_SUCCESS) {
    return (Term)5;
  }
  return (Term)0;
}

// Hvf.load(path, gpa_hi, gpa_lo) -> U32: copies a file into RAM; its size,
// or 0xFFFFFFFF.
Term hvf_load_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  int   fd   = open(path, O_RDONLY);
  free(path);
  if (fd < 0) {
    return (Term)HVF_ERR;
  }
  struct stat st;
  uint8_t*    dst = fstat(fd, &st) == 0 ? hvf_ptr(hvf_u64(f[1], f[2]), (uint64_t)st.st_size) : NULL;
  uint64_t    got = 0;
  while (dst && got < (uint64_t)st.st_size) {
    ssize_t k = read(fd, dst + got, (size_t)st.st_size - got);
    if (k <= 0) {
      break;
    }
    got += (uint64_t)k;
  }
  close(fd);
  return (Term)(dst && got == (uint64_t)st.st_size && got < HVF_ERR ? (u32)got : HVF_ERR);
}

// Hvf.file_size(path) -> U32: a file's size, or 0xFFFFFFFF (also past 4 GiB).
Term hvf_file_size_run(Env e, Term* f, IoWork* w) {
  u64         n;
  char*       path = io_cstr(e, f[0], &n);
  struct stat st;
  int         ok = stat(path, &st) == 0 && st.st_size < HVF_ERR;
  free(path);
  return (Term)(ok ? (u32)st.st_size : HVF_ERR);
}

// Hvf.write(gpa_hi, gpa_lo, bytes) -> U32: 0, or 0xFFFFFFFF outside RAM.
Term hvf_write_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* buf = io_cbuf(e, f[2], &n, CID(Con));
  if (buf == NULL) {
    return (Term)HVF_ERR;
  }
  uint8_t* dst = hvf_ptr(hvf_u64(f[0], f[1]), n);
  if (dst) {
    memcpy(dst, buf, n);
  }
  free(buf);
  return (Term)(dst ? 0 : HVF_ERR);
}

// Hvf.read(gpa_hi, gpa_lo, len) -> List<U32>: the bytes, or [] outside RAM.
Term hvf_read_run(Env e, Term* f, IoWork* w) {
  u64      n   = (u32)f[2];
  uint8_t* src = hvf_ptr(hvf_u64(f[0], f[1]), n);
  return src ? io_list(e, (const char*)src, n) : term_pak(CID(Nil), 0);
}

static Term hvf_vcpu_more(Env e, IoWork* w) {
  HvfCpu* c = &hvf_cpus[w->hand];
  char    b;
  if (read(c->pipe[0], &b, 1) != 1) {
    return io_wait_on(w, c->pipe[0], POLLIN, 0, hvf_vcpu_more);
  }
  return hvf_words(e, c->out, c->nout);
}

// Hvf.vcpu(cpu, op, a_hi, a_lo, b_hi, b_lo) -> List<U32>: runs one request
// on the vCPU's thread (creating the thread on OP_CREATE).
Term hvf_vcpu_run(Env e, Term* f, IoWork* w) {
  u32 cpu = (u32)f[0];
  if (cpu >= HVF_MAX_CPUS) {
    uint32_t err = HVF_ERR;
    return hvf_words(e, &err, 1);
  }
  HvfCpu* c = &hvf_cpus[cpu];
  if (!c->live) {
    if (pipe(c->pipe) != 0) {
      uint32_t err = HVF_ERR;
      return hvf_words(e, &err, 1);
    }
    fcntl(c->pipe[0], F_SETFL, O_NONBLOCK);
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->cv, NULL);
    c->live = 1;
    pthread_create(&c->thread, NULL, hvf_thread, (void*)(intptr_t)cpu);
  }
  pthread_mutex_lock(&c->mu);
  c->op   = (int)(u32)f[1];
  c->a    = hvf_u64(f[2], f[3]);
  c->b    = hvf_u64(f[4], f[5]);
  c->busy = 1;
  pthread_cond_signal(&c->cv);
  pthread_mutex_unlock(&c->mu);
  w->hand = (intptr_t)cpu;
  return io_wait_on(w, c->pipe[0], POLLIN, 0, hvf_vcpu_more);
}

// Hvf.irq(intid, level) -> U32: sets an SPI's level (0 low, else high).
Term hvf_irq_run(Env e, Term* f, IoWork* w) {
  hv_return_t r = hv.gic_set_spi((u32)f[0], (u32)f[1] != 0);
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] irq %u -> %u (%d)\n", (u32)f[0], (u32)f[1], r);
  }
  return (Term)(r == HV_SUCCESS ? 0 : HVF_ERR);
}

// Hvf.kick(cpu) -> U32: forces a running vCPU out of the guest.
Term hvf_kick_run(Env e, Term* f, IoWork* w) {
  u32 cpu = (u32)f[0];
  if (cpu >= HVF_MAX_CPUS || !hvf_cpus[cpu].live) {
    return (Term)HVF_ERR;
  }
  return (Term)(hv.vcpus_exit(&hvf_cpus[cpu].vcpu, 1) == HV_SUCCESS ? 0 : HVF_ERR);
}

// Console and disks
// =================

// Hvf.out(bytes) -> U32: writes raw bytes to stdout (guest console output is
// bytes, not text: IO.write would re-encode them as UTF-8).
Term hvf_out_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* buf = io_cbuf(e, f[0], &n, CID(Con));
  if (buf == NULL) {
    return (Term)HVF_ERR;
  }
  io_sync();
  io_out(stdout, buf, n);
  io_sync();
  free(buf);
  return (Term)0;
}

// Hvf.stdin(max) -> List<U32>: up to max bytes typed on stdin, without
// blocking ([] when none are waiting).
Term hvf_stdin_run(Env e, Term* f, IoWork* w) {
  static int nonblock;
  if (!nonblock) {
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    nonblock = 1;
  }
  char    buf[256];
  u64     max = (u32)f[0] < sizeof buf ? (u32)f[0] : sizeof buf;
  ssize_t k   = read(0, buf, max);
  if ((hvf_trace & 2) && k > 0) {
    fprintf(stderr, "[trace] stdin %zd bytes\n", k);
  }
  return k > 0 ? io_list(e, buf, (u64)k) : term_pak(CID(Nil), 0);
}

// Hvf.random(len) -> List<U32>: len bytes from the host's entropy source.
Term hvf_random_run(Env e, Term* f, IoWork* w) {
  u64      n   = (u32)f[0];
  uint8_t* buf = io_mem(malloc(n ? n : 1));
  arc4random_buf(buf, n);
  Term xs = io_list(e, (const char*)buf, n);
  free(buf);
  return xs;
}

#include <termios.h>

// When stdin is a terminal it goes raw (keys, Ctrl-C included, go to the
// guest) and is restored at exit. Ctrl-A then x quits the VMM.
static struct termios hvf_tty;
static int            hvf_raw;
static int            hvf_ctrl_a;

static void hvf_tty_restore(void) {
  if (hvf_raw) {
    tcsetattr(0, TCSANOW, &hvf_tty);
  }
}

static void hvf_tty_raw(void) {
  if (hvf_raw || !isatty(0) || tcgetattr(0, &hvf_tty) != 0) {
    return;
  }
  struct termios t = hvf_tty;
  cfmakeraw(&t);
  t.c_oflag |= OPOST | ONLCR;
  if (tcsetattr(0, TCSANOW, &t) == 0) {
    hvf_raw = 1;
    atexit(hvf_tty_restore);
  }
}

// Drops the Ctrl-A escape from buf; quits on Ctrl-A x.
static ssize_t hvf_escape(char* buf, ssize_t k) {
  ssize_t n = 0;
  for (ssize_t i = 0; i < k; i++) {
    if (hvf_ctrl_a) {
      hvf_ctrl_a = 0;
      if (buf[i] == 'x') {
        hvf_tty_restore();
        fprintf(stderr, "\r\nbend-vmm: quit (Ctrl-A x)\r\n");
        exit(0);
      }
      if (buf[i] != 1) {
        buf[n++] = 1;
      }
      buf[n++] = buf[i];
    } else if (buf[i] == 1 && hvf_raw) {
      hvf_ctrl_a = 1;
    } else {
      buf[n++] = buf[i];
    }
  }
  return n;
}

static Term hvf_stdin_more(Env e, IoWork* w) {
  char    buf[256];
  ssize_t k = read(0, buf, (size_t)w->made);
  if (k < 0 && errno == EAGAIN) {
    return io_wait_on(w, 0, POLLIN, 0, hvf_stdin_more);
  }
  if (k > 0) {
    k = hvf_escape(buf, k);
    if (k == 0) {
      return io_wait_on(w, 0, POLLIN, 0, hvf_stdin_more);
    }
  }
  if ((hvf_trace & 2) && k > 0) {
    fprintf(stderr, "[trace] stdin %zd bytes\n", k);
  }
  return k > 0 ? io_list(e, buf, (u64)k) : term_pak(CID(Nil), 0);
}

// Hvf.stdin_wait(max) -> List<U32>: parks until stdin has bytes and answers
// up to max of them; [] at end of input (or on an error).
Term hvf_stdin_wait_run(Env e, Term* f, IoWork* w) {
  hvf_tty_raw();
  fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
  w->made = (u32)f[0] < 256 ? (intptr_t)(u32)f[0] : 256;
  return io_wait_on(w, 0, POLLIN, 0, hvf_stdin_more);
}

#define HVF_MAX_DISKS 8
static int hvf_disks[HVF_MAX_DISKS];
static int hvf_ndisks;

// Hvf.disk_open(path) -> U32: opens a disk image read-write; its index, or
// 0xFFFFFFFF.
Term hvf_disk_open_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  int   fd   = hvf_ndisks < HVF_MAX_DISKS ? open(path, O_RDWR) : -1;
  free(path);
  if (fd < 0) {
    return (Term)HVF_ERR;
  }
  hvf_disks[hvf_ndisks] = fd;
  return (Term)(u32)hvf_ndisks++;
}

static int hvf_disk(Term id) {
  u32 i = (u32)id;
  return i < (u32)hvf_ndisks ? hvf_disks[i] : -1;
}

// Hvf.disk_size(disk) -> List<U32>: [hi, lo] of its size in bytes.
Term hvf_disk_size_run(Env e, Term* f, IoWork* w) {
  struct stat st;
  int         fd = hvf_disk(f[0]);
  uint64_t    sz = fd >= 0 && fstat(fd, &st) == 0 ? (uint64_t)st.st_size : 0;
  uint32_t    ws[2] = {(uint32_t)(sz >> 32), (uint32_t)sz};
  return hvf_words(e, ws, 2);
}

// Hvf.disk_read(disk, off_hi, off_lo, len) -> List<U32>: the bytes there,
// short at the end of the image.
Term hvf_disk_read_run(Env e, Term* f, IoWork* w) {
  int      fd  = hvf_disk(f[0]);
  u64      n   = (u32)f[3];
  uint8_t* buf = io_mem(malloc(n ? n : 1));
  ssize_t  k   = fd >= 0 ? pread(fd, buf, n, (off_t)hvf_u64(f[1], f[2])) : -1;
  Term     xs  = io_list(e, (const char*)buf, k > 0 ? (u64)k : 0);
  free(buf);
  return xs;
}

// Hvf.disk_write(disk, off_hi, off_lo, bytes) -> U32: 0, or 0xFFFFFFFF.
Term hvf_disk_write_run(Env e, Term* f, IoWork* w) {
  int   fd = hvf_disk(f[0]);
  u64   n;
  char* buf = io_cbuf(e, f[3], &n, CID(Con));
  if (buf == NULL) {
    return (Term)HVF_ERR;
  }
  ssize_t k = fd >= 0 ? pwrite(fd, buf, n, (off_t)hvf_u64(f[1], f[2])) : -1;
  free(buf);
  return (Term)(k == (ssize_t)n ? 0 : HVF_ERR);
}

// Effects the program never calls have no id; register only the used ones.
static void __attribute__((constructor)) hvf_use(void) {
#ifdef CID(Hvf.init)
  io_eff(CID(Hvf.init), hvf_init_run);
#endif
#ifdef CID(Hvf.load)
  io_eff(CID(Hvf.load), hvf_load_run);
#endif
#ifdef CID(Hvf.write)
  io_eff(CID(Hvf.write), hvf_write_run);
#endif
#ifdef CID(Hvf.read)
  io_eff(CID(Hvf.read), hvf_read_run);
#endif
#ifdef CID(Hvf.vcpu)
  io_eff(CID(Hvf.vcpu), hvf_vcpu_run);
#endif
#ifdef CID(Hvf.irq)
  io_eff(CID(Hvf.irq), hvf_irq_run);
#endif
#ifdef CID(Hvf.kick)
  io_eff(CID(Hvf.kick), hvf_kick_run);
#endif
#ifdef CID(Hvf.file_size)
  io_eff(CID(Hvf.file_size), hvf_file_size_run);
#endif
#ifdef CID(Hvf.out)
  io_eff(CID(Hvf.out), hvf_out_run);
#endif
#ifdef CID(Hvf.stdin)
  io_eff(CID(Hvf.stdin), hvf_stdin_run);
#endif
#ifdef CID(Hvf.stdin_wait)
  io_eff(CID(Hvf.stdin_wait), hvf_stdin_wait_run);
#endif
#ifdef CID(Hvf.random)
  io_eff(CID(Hvf.random), hvf_random_run);
#endif
#ifdef CID(Hvf.disk_open)
  io_eff(CID(Hvf.disk_open), hvf_disk_open_run);
#endif
#ifdef CID(Hvf.disk_size)
  io_eff(CID(Hvf.disk_size), hvf_disk_size_run);
#endif
#ifdef CID(Hvf.disk_read)
  io_eff(CID(Hvf.disk_read), hvf_disk_read_run);
#endif
#ifdef CID(Hvf.disk_write)
  io_eff(CID(Hvf.disk_write), hvf_disk_write_run);
#endif
}
