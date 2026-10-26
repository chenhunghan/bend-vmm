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
#include <netinet/tcp.h>
#include <Hypervisor/Hypervisor.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>

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

enum { OP_CREATE, OP_RUN, OP_SET_REG, OP_GET_REG, OP_SET_VTIMER_MASK, OP_ADVANCE_PC };

// Register writes and PC advances need no answer, so they are queued and the
// vCPU thread applies them, in order, before its next request: an MMIO exit
// costs one round trip to the vCPU thread instead of three or four.
#define HVF_QUEUE 64
typedef struct {
  int      op;
  uint64_t a, b;
} HvfQueued;

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
  HvfQueued       queue[HVF_QUEUE];
  int             nqueue;   // under mu
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

static hv_reg_t hvf_reg_of(uint64_t r) {
  return r <= 30 ? (hv_reg_t)(HV_REG_X0 + r) : r == 31 ? HV_REG_PC : HV_REG_CPSR;
}

// Applies one queued register write or PC advance.
static void hvf_apply(HvfCpu* c, HvfQueued* q) {
  if (q->op == OP_SET_REG) {
    hv.set_reg(c->vcpu, hvf_reg_of(q->a), q->b);
  } else if (q->op == OP_ADVANCE_PC) {
    hv.set_reg(c->vcpu, HV_REG_PC, hvf_reg(c, HV_REG_PC) + 4);
  }
}

static void hvf_do(HvfCpu* c, int cpu) {
  c->nout = 0;
  pthread_mutex_lock(&c->mu);
  HvfQueued q[HVF_QUEUE];
  int       n = c->nqueue;
  memcpy(q, c->queue, sizeof(HvfQueued) * (size_t)n);
  c->nqueue = 0;
  pthread_mutex_unlock(&c->mu);
  for (int i = 0; i < n; i++) {
    hvf_apply(c, &q[i]);
  }
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

static void hvf_tty_restore(void);

// zlib, opened on first use (a gzip-compressed kernel such as Ubuntu's
// vmlinuz). zlib.h clashes with names in Bend's generated C, so its stable
// z_stream ABI is declared here.
typedef struct {
  const uint8_t* next_in;
  unsigned       avail_in;
  unsigned long  total_in;
  uint8_t*       next_out;
  unsigned       avail_out;
  unsigned long  total_out;
  const char*    msg;
  void*          state;
  void*          zalloc;
  void*          zfree;
  void*          opaque;
  int            data_type;
  unsigned long  adler;
  unsigned long  reserved;
} hvf_zstream;

#define HVF_Z_OK         0
#define HVF_Z_STREAM_END 1
#define HVF_Z_NO_FLUSH   0

static struct {
  void* lib;
  int (*init2)(hvf_zstream*, int, const char*, int);
  int (*inflate)(hvf_zstream*, int);
  int (*end)(hvf_zstream*);
} hvf_z;

// Inflates a gzip file of n bytes at src into dst (room bytes); the output
// size, or -1.
static int64_t hvf_gunzip(uint8_t* src, uint64_t n, uint8_t* dst, uint64_t room) {
  if (!hvf_z.lib) {
    hvf_z.lib = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW);
    if (!hvf_z.lib) {
      return -1;
    }
    hvf_z.init2   = dlsym(hvf_z.lib, "inflateInit2_");
    hvf_z.inflate = dlsym(hvf_z.lib, "inflate");
    hvf_z.end     = dlsym(hvf_z.lib, "inflateEnd");
  }
  hvf_zstream z = {0};
  z.next_in  = src;
  z.avail_in = (unsigned)n;
  // windowBits 15 + 16: a gzip wrapper
  if (!hvf_z.init2 || hvf_z.init2(&z, 31, "1.2.12", (int)sizeof z) != HVF_Z_OK) {
    return -1;
  }
  uint64_t out = 0;
  int      r   = HVF_Z_OK;
  while (r == HVF_Z_OK && out < room) {
    uint64_t chunk = room - out > 0x40000000 ? 0x40000000 : room - out;
    z.next_out  = dst + out;
    z.avail_out = (unsigned)chunk;
    r = hvf_z.inflate(&z, HVF_Z_NO_FLUSH);
    out += chunk - z.avail_out;
  }
  hvf_z.end(&z);
  return r == HVF_Z_STREAM_END ? (int64_t)out : -1;
}

// Hvf.load(path, gpa_hi, gpa_lo) -> U32: copies a file into RAM, inflating
// it first when it is gzip-compressed; the size in RAM, or 0xFFFFFFFF.
Term hvf_load_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  int   fd   = open(path, O_RDONLY);
  free(path);
  if (fd < 0) {
    return (Term)HVF_ERR;
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return (Term)HVF_ERR;
  }
  uint8_t* file = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (file == MAP_FAILED) {
    return (Term)HVF_ERR;
  }
  uint64_t gpa = hvf_u64(f[1], f[2]);
  int64_t  got = -1;
  if (st.st_size > 2 && file[0] == 0x1f && file[1] == 0x8b) {
    uint8_t* dst = hvf_ptr(gpa, 1);
    if (dst) {
      got = hvf_gunzip(file, (uint64_t)st.st_size, dst, hvf_ram_size - (gpa - hvf_ram_base));
    }
  } else {
    uint8_t* dst = hvf_ptr(gpa, (uint64_t)st.st_size);
    if (dst) {
      memcpy(dst, file, (size_t)st.st_size);
      got = st.st_size;
    }
  }
  munmap(file, (size_t)st.st_size);
  return (Term)(got >= 0 && got < HVF_ERR ? (u32)got : HVF_ERR);
}

// Hvf.reexec() -> U32: restarts this program with its original arguments
// (PSCI SYSTEM_RESET: a fresh VM is the simplest correct reset).
Term hvf_reexec_run(Env e, Term* f, IoWork* w) {
  char     path[4096];
  uint32_t size = sizeof path;
  hvf_tty_restore();
  fflush(stdout);
  if (_NSGetExecutablePath(path, &size) == 0) {
    execv(path, *_NSGetArgv());
  }
  return (Term)HVF_ERR;
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

// Hvf.vcpu_queue(cpu, op, reg, hi, lo) -> U32: queues a register write
// (OP_SET_REG) or a PC advance (OP_ADVANCE_PC) for the vCPU's next request;
// answers at once. A full queue waits for the vCPU thread to drain it.
Term hvf_vcpu_queue_run(Env e, Term* f, IoWork* w) {
  u32 cpu = (u32)f[0];
  if (cpu >= HVF_MAX_CPUS || !hvf_cpus[cpu].live) {
    return (Term)HVF_ERR;
  }
  HvfCpu* c = &hvf_cpus[cpu];
  for (;;) {
    pthread_mutex_lock(&c->mu);
    if (c->nqueue < HVF_QUEUE) {
      c->queue[c->nqueue++] = (HvfQueued){(int)(u32)f[1], (u32)f[2], hvf_u64(f[3], f[4])};
      pthread_mutex_unlock(&c->mu);
      return (Term)0;
    }
    pthread_mutex_unlock(&c->mu);
    sched_yield();
  }
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

// Hvf.disk_flush(disk) -> U32: fsync; 0, or 0xFFFFFFFF.
Term hvf_disk_flush_run(Env e, Term* f, IoWork* w) {
  int fd = hvf_disk(f[0]);
  return (Term)(fd >= 0 && fsync(fd) == 0 ? 0 : HVF_ERR);
}

// Hvf.now() -> List<U32>: [hi, lo] of the wall clock in seconds since 1970.
Term hvf_now_run(Env e, Term* f, IoWork* w) {
  uint64_t t     = (uint64_t)time(NULL);
  uint32_t ws[2] = {(uint32_t)(t >> 32), (uint32_t)t};
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

// Network (the host end of src/net/nat.bend)
// ============================================
//
// TCP connections are keyed by the NAT's connection number, UDP sockets by
// the guest's source port. Guest addresses map to host ones: 10.0.2.2 (the
// gateway) is 127.0.0.1, 10.0.2.3 (DNS) is the host's first nameserver in
// /etc/resolv.conf (1.1.1.1 when there is none); replies map back.

#include <netinet/in.h>
#include <arpa/inet.h>

#define HVF_GW  0x0A000202u
#define HVF_DNS 0x0A000203u
#define HVF_MAX_SOCKS 1024

typedef struct {
  int      used;
  uint32_t key;   // conn id (TCP) or guest port (UDP)
  int      udp;
  int      fd;
} HvfSock;

static HvfSock  hvf_socks[HVF_MAX_SOCKS];
static uint32_t hvf_dns;

static uint32_t hvf_resolver(void) {
  if (hvf_dns) {
    return hvf_dns;
  }
  hvf_dns = 0x01010101u;
  FILE* f = fopen("/etc/resolv.conf", "r");
  char  line[256], addr[64];
  while (f && fgets(line, sizeof line, f)) {
    struct in_addr a;
    if (sscanf(line, "nameserver %63s", addr) == 1 && inet_pton(AF_INET, addr, &a) == 1) {
      hvf_dns = ntohl(a.s_addr);
      break;
    }
  }
  if (f) {
    fclose(f);
  }
  return hvf_dns;
}

static uint32_t hvf_to_host(uint32_t ip) {
  return ip == HVF_GW ? 0x7F000001u : ip == HVF_DNS ? hvf_resolver() : ip;
}

static uint32_t hvf_to_guest(uint32_t ip) {
  return ip == 0x7F000001u ? HVF_GW : ip == hvf_resolver() ? HVF_DNS : ip;
}

static HvfSock* hvf_sock(uint32_t key, int udp) {
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    if (hvf_socks[i].used && hvf_socks[i].key == key && hvf_socks[i].udp == udp) {
      return &hvf_socks[i];
    }
  }
  return NULL;
}

static HvfSock* hvf_sock_new(uint32_t key, int udp, int fd) {
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    if (!hvf_socks[i].used) {
      hvf_socks[i] = (HvfSock){1, key, udp, fd};
      return &hvf_socks[i];
    }
  }
  return NULL;
}

static void hvf_sock_free(HvfSock* k) {
  close(k->fd);
  k->used = 0;
}

static struct sockaddr_in hvf_addr(uint32_t ip, uint32_t port) {
  struct sockaddr_in a = {0};
  a.sin_family      = AF_INET;
  a.sin_port        = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(hvf_to_host(ip));
  return a;
}

// Hvf.tcp_connect(conn, ip, port) -> U32: starts a non-blocking connect; 0,
// or an errno. Hvf.tcp_wait answers when it completes.
Term hvf_tcp_connect_run(Env e, Term* f, IoWork* w) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return (Term)(u32)errno;
  }
  fcntl(fd, F_SETFL, O_NONBLOCK);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a = hvf_addr((u32)f[1], (u32)f[2]);
  if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0 && errno != EINPROGRESS) {
    int err = errno;
    close(fd);
    return (Term)(u32)err;
  }
  if (!hvf_sock_new((u32)f[0], 0, fd)) {
    close(fd);
    return (Term)(u32)EMFILE;
  }
  return (Term)0;
}

static Term hvf_tcp_wait_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock((uint32_t)w->hand, 0);
  if (!k) {
    return (Term)(u32)ECONNABORTED;
  }
  int       err = 0;
  socklen_t len = sizeof err;
  getsockopt(k->fd, SOL_SOCKET, SO_ERROR, &err, &len);
  return (Term)(u32)err;
}

// Hvf.tcp_wait(conn) -> U32: parks until the connect finishes; 0, or an errno.
Term hvf_tcp_wait_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (!k) {
    return (Term)(u32)ECONNABORTED;
  }
  w->hand = (intptr_t)(u32)f[0];
  return io_wait_on(w, k->fd, POLLOUT, 0, hvf_tcp_wait_more);
}

static Term hvf_tcp_recv_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock((uint32_t)w->hand, 0);
  if (!k) {
    return term_pak(CID(Nil), 0);
  }
  char    buf[16384];
  ssize_t n = recv(k->fd, buf, sizeof buf, 0);
  if (n < 0 && errno == EAGAIN) {
    return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_recv_more);
  }
  return n > 0 ? io_list(e, buf, (u64)n) : term_pak(CID(Nil), 0);
}

// Hvf.tcp_recv(conn) -> List<U32>: parks until data arrives; [] at EOF, on
// an error, or once the connection is closed.
Term hvf_tcp_recv_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (!k) {
    return term_pak(CID(Nil), 0);
  }
  w->hand = (intptr_t)(u32)f[0];
  return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_recv_more);
}

// Hvf.tcp_send(conn, bytes) -> U32: writes all bytes (waiting for room);
// 0, or an errno.
Term hvf_tcp_send_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  u64      n;
  char*    buf = io_cbuf(e, f[1], &n, CID(Con));
  if (!k || !buf) {
    free(buf);
    return (Term)(u32)EBADF;
  }
  u64 at = 0;
  while (at < n) {
    ssize_t m = send(k->fd, buf + at, n - at, 0);
    if (m > 0) {
      at += (u64)m;
    } else if (m < 0 && errno == EAGAIN) {
      struct pollfd p = {k->fd, POLLOUT, 0};
      poll(&p, 1, 1000);
    } else {
      break;
    }
  }
  free(buf);
  return (Term)(at == n ? 0 : (u32)EPIPE);
}

// Hvf.tcp_shutdown(conn) -> U32: no more data from the guest.
Term hvf_tcp_shutdown_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  return (Term)(k && shutdown(k->fd, SHUT_WR) == 0 ? 0 : HVF_ERR);
}

// Hvf.tcp_close(conn) -> U32
Term hvf_tcp_close_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (k) {
    hvf_sock_free(k);
  }
  return (Term)0;
}

// Hvf.udp_send(sport, ip, port, bytes) -> U32: sends from the socket of
// guest port sport, creating it on first use; 1 when it was created (the
// caller starts its receive loop), 0 otherwise, 0xFFFFFFFF on failure.
Term hvf_udp_send_run(Env e, Term* f, IoWork* w) {
  HvfSock* k     = hvf_sock((u32)f[0], 1);
  int      fresh = 0;
  if (!k) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
      return (Term)HVF_ERR;
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    k = hvf_sock_new((u32)f[0], 1, fd);
    if (!k) {
      close(fd);
      return (Term)HVF_ERR;
    }
    fresh = 1;
  }
  u64   n;
  char* buf = io_cbuf(e, f[3], &n, CID(Con));
  if (!buf) {
    return (Term)HVF_ERR;
  }
  struct sockaddr_in a = hvf_addr((u32)f[1], (u32)f[2]);
  sendto(k->fd, buf, n, 0, (struct sockaddr*)&a, sizeof a);
  free(buf);
  return (Term)(u32)fresh;
}

static Term hvf_udp_recv_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock((uint32_t)w->hand, 1);
  if (!k) {
    return term_pak(CID(Nil), 0);
  }
  char               buf[65536];
  struct sockaddr_in a;
  socklen_t          len = sizeof a;
  ssize_t            n   = recvfrom(k->fd, buf, sizeof buf, 0, (struct sockaddr*)&a, &len);
  if (n < 0) {
    return errno == EAGAIN ? io_wait_on(w, k->fd, POLLIN, 0, hvf_udp_recv_more) : term_pak(CID(Nil), 0);
  }
  // [ip, port, bytes...]
  Term xs = io_list(e, buf, (u64)n);
  xs = io_node(e, CID(Con), (Term)(u32)ntohs(a.sin_port), xs);
  return io_node(e, CID(Con), (Term)hvf_to_guest(ntohl(a.sin_addr.s_addr)), xs);
}

// Hvf.udp_recv(sport) -> List<U32>: parks until a datagram arrives for guest
// port sport; [ip, port, bytes...], or [] once the socket is gone.
Term hvf_udp_recv_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 1);
  if (!k) {
    return term_pak(CID(Nil), 0);
  }
  w->hand = (intptr_t)(u32)f[0];
  return io_wait_on(w, k->fd, POLLIN, 0, hvf_udp_recv_more);
}

// Effects the program never calls have no id; register only the used ones.
// The VMM's pure work per exit is microseconds, so extra runtime worker
// threads only add contention: default the runtime to one (BENDRTS wins).
static void __attribute__((constructor)) hvf_use(void) {
  setenv("BENDRTS", "--threads 1", 0);
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
#ifdef CID(Hvf.vcpu_queue)
  io_eff(CID(Hvf.vcpu_queue), hvf_vcpu_queue_run);
#endif
#ifdef CID(Hvf.tcp_connect)
  io_eff(CID(Hvf.tcp_connect), hvf_tcp_connect_run);
#endif
#ifdef CID(Hvf.tcp_wait)
  io_eff(CID(Hvf.tcp_wait), hvf_tcp_wait_run);
#endif
#ifdef CID(Hvf.tcp_recv)
  io_eff(CID(Hvf.tcp_recv), hvf_tcp_recv_run);
#endif
#ifdef CID(Hvf.tcp_send)
  io_eff(CID(Hvf.tcp_send), hvf_tcp_send_run);
#endif
#ifdef CID(Hvf.tcp_shutdown)
  io_eff(CID(Hvf.tcp_shutdown), hvf_tcp_shutdown_run);
#endif
#ifdef CID(Hvf.tcp_close)
  io_eff(CID(Hvf.tcp_close), hvf_tcp_close_run);
#endif
#ifdef CID(Hvf.udp_send)
  io_eff(CID(Hvf.udp_send), hvf_udp_send_run);
#endif
#ifdef CID(Hvf.udp_recv)
  io_eff(CID(Hvf.udp_recv), hvf_udp_recv_run);
#endif
#ifdef CID(Hvf.irq)
  io_eff(CID(Hvf.irq), hvf_irq_run);
#endif
#ifdef CID(Hvf.kick)
  io_eff(CID(Hvf.kick), hvf_kick_run);
#endif
#ifdef CID(Hvf.reexec)
  io_eff(CID(Hvf.reexec), hvf_reexec_run);
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
#ifdef CID(Hvf.disk_flush)
  io_eff(CID(Hvf.disk_flush), hvf_disk_flush_run);
#endif
#ifdef CID(Hvf.now)
  io_eff(CID(Hvf.now), hvf_now_run);
#endif
#ifdef CID(Hvf.disk_read)
  io_eff(CID(Hvf.disk_read), hvf_disk_read_run);
#endif
#ifdef CID(Hvf.disk_write)
  io_eff(CID(Hvf.disk_write), hvf_disk_write_run);
#endif
}
