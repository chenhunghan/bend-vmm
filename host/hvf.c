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
  return (Term)(hv.gic_set_spi((u32)f[0], (u32)f[1] != 0) == HV_SUCCESS ? 0 : HVF_ERR);
}

// Hvf.kick(cpu) -> U32: forces a running vCPU out of the guest.
Term hvf_kick_run(Env e, Term* f, IoWork* w) {
  u32 cpu = (u32)f[0];
  if (cpu >= HVF_MAX_CPUS || !hvf_cpus[cpu].live) {
    return (Term)HVF_ERR;
  }
  return (Term)(hv.vcpus_exit(&hvf_cpus[cpu].vcpu, 1) == HV_SUCCESS ? 0 : HVF_ERR);
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
}
