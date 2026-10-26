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
#include <mach/mach_time.h>
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
  __typeof__(&hv_vcpu_get_sys_reg) get_sys_reg;
  __typeof__(&hv_vcpu_get_simd_fp_reg) get_simd;
  __typeof__(&hv_vcpu_set_simd_fp_reg) set_simd;
  __typeof__(&hv_vcpu_get_vtimer_offset) get_vtimer_offset;
  __typeof__(&hv_vcpu_set_vtimer_offset) set_vtimer_offset;
  __typeof__(&hv_gic_state_create) gic_state_create;
  __typeof__(&hv_gic_state_get_size) gic_state_size;
  __typeof__(&hv_gic_state_get_data) gic_state_data;
  __typeof__(&hv_gic_set_state) gic_set_state;
  __typeof__(&hv_gic_get_icc_reg) get_icc;
  __typeof__(&hv_gic_set_icc_reg) set_icc;
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
  HV_SYM(get_sys_reg, hv_vcpu_get_sys_reg);
  HV_SYM(get_simd, hv_vcpu_get_simd_fp_reg);
  HV_SYM(set_simd, hv_vcpu_set_simd_fp_reg);
  HV_SYM(get_vtimer_offset, hv_vcpu_get_vtimer_offset);
  HV_SYM(set_vtimer_offset, hv_vcpu_set_vtimer_offset);
  HV_SYM(gic_state_create, hv_gic_state_create);
  HV_SYM(gic_state_size, hv_gic_state_get_size);
  HV_SYM(gic_state_data, hv_gic_state_get_data);
  HV_SYM(gic_set_state, hv_gic_set_state);
  HV_SYM(get_icc, hv_gic_get_icc_reg);
  HV_SYM(set_icc, hv_gic_set_icc_reg);
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
  int             created;  // the hv vCPU exists
  int             saved_gen;
  uint8_t*        saved;    // the last snapshot of this vCPU's registers
  size_t          nsaved;
  const uint8_t*  icc;      // GIC CPU registers to restore before the first run
  size_t          nicc;
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

// Pause, snapshots and restore
// =============================
//
// A paused VM keeps every vCPU out of the guest: a vCPU about to run waits at
// a gate, and pause kicks the running ones out (hv_vcpus_exit). While paused
// the guest's virtual counter stands still: leaving the gate adds the pause's
// length to the vtimer offset. A snapshot asks each vCPU thread to save its
// own registers (only the owning thread may read them) and waits for all.

static pthread_mutex_t hvf_gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  hvf_gate_cv = PTHREAD_COND_INITIALIZER;
static int             hvf_paused;
static int             hvf_running;     // vCPUs inside hv_vcpu_run
static uint64_t        hvf_pause_start; // mach_absolute_time at pause
static int             hvf_save_gen;    // bumped by each snapshot
static int             hvf_saving;      // vCPU threads still to save

// Every register a snapshot keeps besides X0..X30, PC, CPSR, FPCR, FPSR and
// Q0..Q31. Registers this macOS lacks fail to read and are skipped.
static const uint16_t hvf_sysregs[] = {
  HV_SYS_REG_DBGBVR0_EL1, HV_SYS_REG_DBGBCR0_EL1, HV_SYS_REG_DBGWVR0_EL1, HV_SYS_REG_DBGWCR0_EL1,
  HV_SYS_REG_DBGBVR1_EL1, HV_SYS_REG_DBGBCR1_EL1, HV_SYS_REG_DBGWVR1_EL1, HV_SYS_REG_DBGWCR1_EL1,
  HV_SYS_REG_MDCCINT_EL1, HV_SYS_REG_MDSCR_EL1, HV_SYS_REG_MPIDR_EL1, HV_SYS_REG_SCTLR_EL1,
  0xc081 /* ACTLR_EL1 */, HV_SYS_REG_CPACR_EL1, HV_SYS_REG_TTBR0_EL1, HV_SYS_REG_TTBR1_EL1,
  HV_SYS_REG_TCR_EL1, HV_SYS_REG_APIAKEYLO_EL1, HV_SYS_REG_APIAKEYHI_EL1, HV_SYS_REG_APIBKEYLO_EL1,
  HV_SYS_REG_APIBKEYHI_EL1, HV_SYS_REG_APDAKEYLO_EL1, HV_SYS_REG_APDAKEYHI_EL1, HV_SYS_REG_APDBKEYLO_EL1,
  HV_SYS_REG_APDBKEYHI_EL1, HV_SYS_REG_APGAKEYLO_EL1, HV_SYS_REG_APGAKEYHI_EL1, HV_SYS_REG_SPSR_EL1,
  HV_SYS_REG_ELR_EL1, HV_SYS_REG_SP_EL0, HV_SYS_REG_AFSR0_EL1, HV_SYS_REG_AFSR1_EL1,
  HV_SYS_REG_ESR_EL1, HV_SYS_REG_FAR_EL1, HV_SYS_REG_PAR_EL1, HV_SYS_REG_MAIR_EL1,
  HV_SYS_REG_AMAIR_EL1, HV_SYS_REG_VBAR_EL1, HV_SYS_REG_CONTEXTIDR_EL1, HV_SYS_REG_TPIDR_EL1,
  0xc687 /* SCXTNUM_EL1 */, HV_SYS_REG_CNTKCTL_EL1, HV_SYS_REG_CSSELR_EL1, HV_SYS_REG_TPIDR_EL0,
  HV_SYS_REG_TPIDRRO_EL0, 0xde85 /* TPIDR2_EL0 */, 0xde87 /* SCXTNUM_EL0 */, HV_SYS_REG_CNTV_CTL_EL0,
  HV_SYS_REG_CNTV_CVAL_EL0, HV_SYS_REG_SP_EL1, 0xdf11 /* CNTP_CTL_EL0 */, 0xdf12 /* CNTP_CVAL_EL0 */,
};
#define HVF_NSYSREGS (sizeof hvf_sysregs / sizeof *hvf_sysregs)

// The GIC CPU interface registers: hv_gic_state leaves them out, so each
// vCPU saves its own. Restored after hv_gic_set_state, before the first run.
static const uint16_t hvf_iccregs[] = {
  HV_GIC_ICC_REG_SRE_EL1, HV_GIC_ICC_REG_CTLR_EL1, HV_GIC_ICC_REG_PMR_EL1, HV_GIC_ICC_REG_BPR0_EL1,
  HV_GIC_ICC_REG_BPR1_EL1, HV_GIC_ICC_REG_AP0R0_EL1, HV_GIC_ICC_REG_AP1R0_EL1,
  HV_GIC_ICC_REG_IGRPEN0_EL1, HV_GIC_ICC_REG_IGRPEN1_EL1,
};
#define HVF_NICCREGS (sizeof hvf_iccregs / sizeof *hvf_iccregs)

// A vCPU's registers as entries {u32 key, u64 value}: key 0x10000 | n for
// hv_reg_t n, 0x20000 | n for system register n, 0x30000 | n (n < 64) for
// half n of SIMD register n / 2; then the guest's virtual count (key 0x40000).
typedef struct {
  uint32_t key;
  uint64_t val;
} __attribute__((packed)) HvfRegEntry;

static void hvf_save_regs(HvfCpu* c) {
  size_t       cap = 33 + 2 + HVF_NSYSREGS + HVF_NICCREGS + 64 + 1, n = 0;
  HvfRegEntry* e   = io_mem(malloc(cap * sizeof *e));
  for (uint32_t r = 0; r <= 30; r++) {
    e[n++] = (HvfRegEntry){0x10000 | r, hvf_reg(c, (hv_reg_t)(HV_REG_X0 + r))};
  }
  e[n++] = (HvfRegEntry){0x10000 | HV_REG_PC, hvf_reg(c, HV_REG_PC)};
  e[n++] = (HvfRegEntry){0x10000 | HV_REG_CPSR, hvf_reg(c, HV_REG_CPSR)};
  e[n++] = (HvfRegEntry){0x10000 | HV_REG_FPCR, hvf_reg(c, HV_REG_FPCR)};
  e[n++] = (HvfRegEntry){0x10000 | HV_REG_FPSR, hvf_reg(c, HV_REG_FPSR)};
  for (size_t i = 0; i < HVF_NSYSREGS; i++) {
    uint64_t v;
    if (hv.get_sys_reg(c->vcpu, (hv_sys_reg_t)hvf_sysregs[i], &v) == HV_SUCCESS) {
      e[n++] = (HvfRegEntry){0x20000 | hvf_sysregs[i], v};
    }
  }
  for (uint32_t q = 0; q < 32; q++) {
    hv_simd_fp_uchar16_t v;
    uint64_t             half[2] = {0, 0};
    if (hv.get_simd(c->vcpu, (hv_simd_fp_reg_t)(HV_SIMD_FP_REG_Q0 + q), &v) == HV_SUCCESS) {
      memcpy(half, &v, 16);
    }
    e[n++] = (HvfRegEntry){0x30000 | (2 * q), half[0]};
    e[n++] = (HvfRegEntry){0x30000 | (2 * q + 1), half[1]};
  }
  for (size_t i = 0; hv.get_icc && i < HVF_NICCREGS; i++) {
    uint64_t v;
    if (hv.get_icc(c->vcpu, (hv_gic_icc_reg_t)hvf_iccregs[i], &v) == HV_SUCCESS) {
      e[n++] = (HvfRegEntry){0x50000 | hvf_iccregs[i], v};
    }
  }
  uint64_t off = 0;
  hv.get_vtimer_offset(c->vcpu, &off);
  e[n++] = (HvfRegEntry){0x40000, mach_absolute_time() - off};
  free(c->saved);
  c->saved  = (uint8_t*)e;
  c->nsaved = n * sizeof *e;
}

static void hvf_load_regs(HvfCpu* c, const uint8_t* blob, size_t size) {
  const HvfRegEntry* e = (const HvfRegEntry*)blob;
  size_t             n = size / sizeof *e;
  uint64_t           half[64] = {0};
  for (size_t i = 0; i < n; i++) {
    uint32_t kind = e[i].key >> 16, id = e[i].key & 0xffff;
    if (kind == 1) {
      hv.set_reg(c->vcpu, (hv_reg_t)id, e[i].val);
    } else if (kind == 2) {
      hv.set_sys_reg(c->vcpu, (hv_sys_reg_t)id, e[i].val);
    } else if (kind == 3 && id < 64) {
      half[id] = e[i].val;
    } else if (kind == 4) {
      // continue the guest's virtual count from where it was
      hv.set_vtimer_offset(c->vcpu, mach_absolute_time() - e[i].val);
    }
  }
  for (uint32_t q = 0; q < 32; q++) {
    hv_simd_fp_uchar16_t v;
    memcpy(&v, &half[2 * q], 16);
    hv.set_simd(c->vcpu, (hv_simd_fp_reg_t)(HV_SIMD_FP_REG_Q0 + q), v);
  }
}

// Saves this vCPU's registers when a snapshot asked for them. Called by the
// vCPU's own thread wherever it waits.
static void hvf_service(HvfCpu* c) {
  pthread_mutex_lock(&hvf_gate_mu);
  int want = c->created && c->saved_gen != hvf_save_gen;
  int gen  = hvf_save_gen;
  pthread_mutex_unlock(&hvf_gate_mu);
  if (!want) {
    return;
  }
  // apply queued register writes first: the machine has already handled the
  // exit they finish, so the snapshot must include them
  pthread_mutex_lock(&c->mu);
  HvfQueued q[HVF_QUEUE];
  int       nq = c->nqueue;
  memcpy(q, c->queue, sizeof(HvfQueued) * (size_t)nq);
  c->nqueue = 0;
  pthread_mutex_unlock(&c->mu);
  for (int i = 0; i < nq; i++) {
    hvf_apply(c, &q[i]);
  }
  hvf_save_regs(c);
  pthread_mutex_lock(&hvf_gate_mu);
  c->saved_gen = gen;
  hvf_saving--;
  pthread_cond_broadcast(&hvf_gate_cv);
  pthread_mutex_unlock(&hvf_gate_mu);
}

// A snapshot being restored: per-vCPU register blobs, the GIC state and the
// machine words, read by Hvf.snap_open; RAM maps straight from the file.
static struct {
  int       active;
  int       fd;
  uint32_t  ncpus;
  uint64_t  ram_base, ram_size, ram_off;
  uint8_t*  cpu[64];
  size_t    ncpu[64];
  uint8_t*  gic;
  size_t    ngic;
  uint32_t* words;
  uint64_t  nwords;
  char*     args;
  uint64_t  nargs;
} hvf_snap;

static void hvf_restore_cpu(HvfCpu* c, int cpu) {
  if (hvf_snap.active && cpu < 64 && hvf_snap.cpu[cpu]) {
    hvf_load_regs(c, hvf_snap.cpu[cpu], hvf_snap.ncpu[cpu]);
    c->icc  = hvf_snap.cpu[cpu];
    c->nicc = hvf_snap.ncpu[cpu];
  }
}

// The saved GIC CPU registers (entries of kind 5), on the vCPU's thread.
static void hvf_restore_icc(HvfCpu* c) {
  const HvfRegEntry* e = (const HvfRegEntry*)c->icc;
  size_t             n = c->nicc / sizeof *e;
  for (size_t i = 0; hv.set_icc && i < n; i++) {
    if (e[i].key >> 16 == 5) {
      hv.set_icc(c->vcpu, (hv_gic_icc_reg_t)(e[i].key & 0xffff), e[i].val);
    }
  }
  c->icc  = NULL;
  c->nicc = 0;
}

// The gate before hv_vcpu_run.
static void hvf_gate(HvfCpu* c) {
  if (c->icc) {
    hvf_restore_icc(c);
  }
  pthread_mutex_lock(&hvf_gate_mu);
  int waited = 0;
  while (hvf_paused || c->saved_gen != hvf_save_gen) {
    waited = 1;
    pthread_mutex_unlock(&hvf_gate_mu);
    hvf_service(c);
    pthread_mutex_lock(&hvf_gate_mu);
    if (hvf_paused) {
      pthread_cond_wait(&hvf_gate_cv, &hvf_gate_mu);
    }
  }
  uint64_t start = hvf_pause_start;
  hvf_running++;
  pthread_mutex_unlock(&hvf_gate_mu);
  if (waited && start) {
    uint64_t off = 0;
    hv.get_vtimer_offset(c->vcpu, &off);
    hv.set_vtimer_offset(c->vcpu, off + (mach_absolute_time() - start));
  }
}

static void hvf_ungate(void) {
  pthread_mutex_lock(&hvf_gate_mu);
  hvf_running--;
  pthread_cond_broadcast(&hvf_gate_cv);
  pthread_mutex_unlock(&hvf_gate_mu);
}

// Runs the guest until an exit and encodes it as
// [kind, esr, far, ipa, x0, x1, x2, x3, xt] (each 64-bit value as hi, lo):
// kind 0 exception, 1 vtimer, 2 canceled, 3 + reason otherwise.
static void hvf_run(HvfCpu* c) {
  hvf_gate(c);
  hv_return_t r = hv.vcpu_run(c->vcpu);
  hvf_ungate();
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
      if (c->created) {
        c->out[c->nout++] = 0;
        break;
      }
      hv_return_t r = hv.vcpu_create(&c->vcpu, &c->exit, NULL);
      if (r == HV_SUCCESS) {
        // Aff0 = cpu index; bit 31 is RES1. The GIC routes by affinity.
        r = hv.set_sys_reg(c->vcpu, HV_SYS_REG_MPIDR_EL1, (1ull << 31) | (uint64_t)cpu);
        c->created = 1;
        pthread_mutex_lock(&hvf_gate_mu);
        c->saved_gen = hvf_save_gen;
        pthread_mutex_unlock(&hvf_gate_mu);
        hvf_restore_cpu(c, cpu);
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
      pthread_mutex_unlock(&c->mu);
      hvf_service(c);
      pthread_mutex_lock(&c->mu);
      if (!c->busy) {
        struct timespec t;
        clock_gettime(CLOCK_REALTIME, &t);
        t.tv_nsec += 20000000;
        if (t.tv_nsec >= 1000000000) {
          t.tv_sec++;
          t.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&c->cv, &c->mu, &t);
      }
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
  if (hvf_snap.active) {
    // a restore: guest RAM is the snapshot's, copy-on-write from the file
    hvf_ram_size = hvf_snap.ram_size;
    hvf_ram_base = hvf_snap.ram_base;
    hvf_ram = mmap(NULL, hvf_ram_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, hvf_snap.fd, (off_t)hvf_snap.ram_off);
  } else {
    hvf_ram = mmap(NULL, hvf_ram_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  }
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

// Applies the Ctrl-A escape to buf into out (words): Ctrl-A x quits here;
// Ctrl-A p, Ctrl-A s and Ctrl-A h become the words 256 + 'p' / 's' / 'h'
// for the VMM to act on; Ctrl-A Ctrl-A sends one Ctrl-A to the guest.
static ssize_t hvf_escape(const char* buf, ssize_t k, uint32_t* out) {
  ssize_t n = 0;
  for (ssize_t i = 0; i < k; i++) {
    unsigned char ch = (unsigned char)buf[i];
    if (hvf_ctrl_a) {
      hvf_ctrl_a = 0;
      if (ch == 'x') {
        hvf_tty_restore();
        fprintf(stderr, "\r\nbend-vmm: quit (Ctrl-A x)\r\n");
        exit(0);
      } else if (ch == 'p' || ch == 's' || ch == 'h') {
        out[n++] = 256u + ch;
      } else if (ch == 1) {
        out[n++] = 1;
      } else {
        out[n++] = 1;
        out[n++] = ch;
      }
    } else if (ch == 1 && hvf_raw) {
      hvf_ctrl_a = 1;
    } else {
      out[n++] = ch;
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
  if (k <= 0) {
    return term_pak(CID(Nil), 0);
  }
  uint32_t out[512];
  ssize_t  m = hvf_escape(buf, k, out);
  if (m == 0) {
    return io_wait_on(w, 0, POLLIN, 0, hvf_stdin_more);
  }
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] stdin %zd words\n", m);
  }
  return hvf_words(e, out, (u64)m);
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

// Shared directories (the host end of virtio-9p)
// ==============================================
//
// Paths from the guest are relative to a share root, components separated by
// "/", none empty, "." or "..". An operation resolves the parent directory
// with realpath and refuses it unless it lies inside the root (so a symlink
// cannot lead out), and never follows a symlink in the final component.
// Answers are word lists (host/hvf.bend decodes them):
//   [0] ok   [1, errno]   [2, mode, uid, gid, nlink, size, ino, blocks, atime,
//   mtime, ctime (64-bit values as hi, lo)]   [3, bytes...]   [4, count]
//   [5, (ino hi, ino lo, type, name length, name bytes...)*]   [6, target...]
//   [7, bsize, blocks, bfree, bavail, files, ffree (64-bit as hi, lo)]

#include <dirent.h>
#include <sys/mount.h>
#include <limits.h>

#define HVF_MAX_SHARES 8
static char* hvf_shares[HVF_MAX_SHARES];
static int   hvf_nshares;

// Hvf.share_open(path) -> U32: a share index, or 0xFFFFFFFF.
Term hvf_share_open_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  char* real = realpath(path, NULL);
  free(path);
  if (!real || hvf_nshares >= HVF_MAX_SHARES) {
    free(real);
    return (Term)HVF_ERR;
  }
  hvf_shares[hvf_nshares] = real;
  return (Term)(u32)hvf_nshares++;
}

static int hvf_rel_ok(const char* p) {
  if (p[0] == 0) {
    return 1;
  }
  const char* c = p;
  for (;;) {
    const char* end = strchr(c, '/');
    size_t      len = end ? (size_t)(end - c) : strlen(c);
    if (len == 0 || (len == 1 && c[0] == '.') || (len == 2 && c[0] == '.' && c[1] == '.')) {
      return 0;
    }
    if (!end) {
      return 1;
    }
    c = end + 1;
  }
}

// The host path for rel in share sh, in out (PATH_MAX); 0 on success or an errno.
static int hvf_resolve(u32 sh, const char* rel, char* out) {
  if (sh >= (u32)hvf_nshares || !hvf_rel_ok(rel)) {
    return EINVAL;
  }
  const char* root = hvf_shares[sh];
  if (rel[0] == 0) {
    snprintf(out, PATH_MAX, "%s", root);
    return 0;
  }
  char        parent[PATH_MAX];
  const char* slash = strrchr(rel, '/');
  if (slash) {
    snprintf(parent, sizeof parent, "%s/%.*s", root, (int)(slash - rel), rel);
  } else {
    snprintf(parent, sizeof parent, "%s", root);
  }
  char real[PATH_MAX];
  if (!realpath(parent, real)) {
    return errno;
  }
  size_t rl = strlen(root);
  if (strncmp(real, root, rl) != 0 || (real[rl] != 0 && real[rl] != '/')) {
    return EACCES;
  }
  snprintf(out, PATH_MAX, "%s/%s", real, slash ? slash + 1 : rel);
  return 0;
}

typedef struct {
  uint32_t* w;
  u64       n, cap;
} HvfWords;

static void hvf_w(HvfWords* b, uint32_t x) {
  if (b->n == b->cap) {
    b->cap = b->cap ? b->cap * 2 : 64;
    b->w   = io_mem(realloc(b->w, b->cap * sizeof(uint32_t)));
  }
  b->w[b->n++] = x;
}

static void hvf_w64(HvfWords* b, uint64_t x) {
  hvf_w(b, (uint32_t)(x >> 32));
  hvf_w(b, (uint32_t)x);
}

static Term hvf_fs_done(Env e, HvfWords* b) {
  Term t = hvf_words(e, b->w, b->n);
  free(b->w);
  return t;
}

static Term hvf_fs_err(Env e, int err) {
  uint32_t ws[2] = {1, (uint32_t)err};
  return hvf_words(e, ws, 2);
}

static Term hvf_fs_ok(Env e) {
  uint32_t ok = 0;
  return hvf_words(e, &ok, 1);
}

static int hvf_dir_cmp(const void* a, const void* b) {
  return strcmp(*(char* const*)a, *(char* const*)b);
}

// Hvf.fs(share, op, path, path2, a_hi, a_lo, b, bytes) -> List<U32>.
// op: 0 stat, 1 list(from = a_lo, max = b), 2 read(offset a, len b),
// 3 write(offset a, bytes), 4 create(mode b), 5 mkdir(mode b),
// 6 remove(dir = b), 7 rename(to path2), 8 truncate(size a), 9 chmod(mode b),
// 10 symlink(target path2), 11 readlink, 12 statfs.
Term hvf_fs_run(Env e, Term* f, IoWork* w) {
  u32      sh = (u32)f[0], op = (u32)f[1];
  u64      n1, n2, nb;
  char*    rel   = io_cstr(e, f[2], &n1);
  char*    rel2  = io_cstr(e, f[3], &n2);
  uint64_t a     = hvf_u64(f[4], f[5]);
  u32      b     = (u32)f[6];
  char*    bytes = io_cbuf(e, f[7], &nb, CID(Con));
  char     path[PATH_MAX], path2[PATH_MAX];
  HvfWords out   = {0};
  Term     res;
  int      err   = hvf_resolve(sh, rel, path);
  if (!err && (op == 7)) {
    err = hvf_resolve(sh, rel2, path2);
  }
  if (err) {
    res = hvf_fs_err(e, err);
  } else if (op == 0) {
    struct stat st;
    if (lstat(path, &st) != 0) {
      res = hvf_fs_err(e, errno);
    } else {
      hvf_w(&out, 2);
      hvf_w(&out, st.st_mode);
      hvf_w(&out, st.st_uid);
      hvf_w(&out, st.st_gid);
      hvf_w(&out, (uint32_t)st.st_nlink);
      hvf_w64(&out, (uint64_t)st.st_size);
      hvf_w64(&out, (uint64_t)st.st_ino);
      hvf_w64(&out, (uint64_t)st.st_blocks);
      hvf_w64(&out, (uint64_t)st.st_atimespec.tv_sec);
      hvf_w64(&out, (uint64_t)st.st_mtimespec.tv_sec);
      hvf_w64(&out, (uint64_t)st.st_ctimespec.tv_sec);
      res = hvf_fs_done(e, &out);
    }
  } else if (op == 1) {
    DIR* d = opendir(path);
    if (!d) {
      res = hvf_fs_err(e, errno);
    } else {
      char**         names = NULL;
      size_t         cnt = 0, cap = 0;
      struct dirent* de;
      while ((de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) {
          continue;
        }
        if (cnt == cap) {
          cap   = cap ? cap * 2 : 32;
          names = io_mem(realloc(names, cap * sizeof(char*)));
        }
        names[cnt++] = strdup(de->d_name);
      }
      closedir(d);
      qsort(names, cnt, sizeof(char*), hvf_dir_cmp);
      hvf_w(&out, 5);
      for (size_t i = (size_t)(u32)a; i < cnt && i < (size_t)(u32)a + b; i++) {
        char        p[PATH_MAX];
        struct stat st;
        snprintf(p, sizeof p, "%s/%s", path, names[i]);
        int ok = lstat(p, &st) == 0;
        hvf_w64(&out, ok ? (uint64_t)st.st_ino : 0);
        hvf_w(&out, !ok ? 0 : S_ISDIR(st.st_mode) ? 4 : S_ISLNK(st.st_mode) ? 10 : S_ISREG(st.st_mode) ? 8 : 0);
        size_t len = strlen(names[i]);
        hvf_w(&out, (uint32_t)len);
        for (size_t j = 0; j < len; j++) {
          hvf_w(&out, (uint8_t)names[i][j]);
        }
      }
      for (size_t i = 0; i < cnt; i++) {
        free(names[i]);
      }
      free(names);
      res = hvf_fs_done(e, &out);
    }
  } else if (op == 2 || op == 3) {
    int fd = open(path, (op == 2 ? O_RDONLY : O_WRONLY) | O_NOFOLLOW);
    if (fd < 0) {
      res = hvf_fs_err(e, errno);
    } else if (op == 2) {
      char*   buf = io_mem(malloc(b ? b : 1));
      ssize_t k   = pread(fd, buf, b, (off_t)a);
      if (k < 0) {
        res = hvf_fs_err(e, errno);
      } else {
        hvf_w(&out, 3);
        for (ssize_t i = 0; i < k; i++) {
          hvf_w(&out, (uint8_t)buf[i]);
        }
        res = hvf_fs_done(e, &out);
      }
      free(buf);
    } else {
      ssize_t k = bytes ? pwrite(fd, bytes, nb, (off_t)a) : -1;
      if (k < 0) {
        res = hvf_fs_err(e, bytes ? errno : EINVAL);
      } else {
        uint32_t ws[2] = {4, (uint32_t)k};
        res = hvf_words(e, ws, 2);
      }
    }
    if (fd >= 0) {
      close(fd);
    }
  } else if (op == 4) {
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, b & 07777);
    res = fd < 0 ? hvf_fs_err(e, errno) : (close(fd), hvf_fs_ok(e));
  } else if (op == 5) {
    res = mkdir(path, b & 07777) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 6) {
    res = (b ? rmdir(path) : unlink(path)) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 7) {
    res = rename(path, path2) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 8) {
    res = truncate(path, (off_t)a) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 9) {
    res = lchmod(path, b & 07777) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 10) {
    res = symlink(rel2, path) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 11) {
    char    buf[PATH_MAX];
    ssize_t k = readlink(path, buf, sizeof buf);
    if (k < 0) {
      res = hvf_fs_err(e, errno);
    } else {
      hvf_w(&out, 6);
      for (ssize_t i = 0; i < k; i++) {
        hvf_w(&out, (uint8_t)buf[i]);
      }
      res = hvf_fs_done(e, &out);
    }
  } else if (op == 12) {
    struct statfs sf;
    if (statfs(path, &sf) != 0) {
      res = hvf_fs_err(e, errno);
    } else {
      hvf_w(&out, 7);
      hvf_w(&out, (uint32_t)sf.f_bsize);
      hvf_w64(&out, sf.f_blocks);
      hvf_w64(&out, sf.f_bfree);
      hvf_w64(&out, sf.f_bavail);
      hvf_w64(&out, sf.f_files);
      hvf_w64(&out, sf.f_ffree);
      res = hvf_fs_done(e, &out);
    }
  } else {
    res = hvf_fs_err(e, ENOSYS);
  }
  free(rel);
  free(rel2);
  free(bytes);
  return res;
}

// Pause, snapshot and restore effects
// ===================================

static void hvf_kick_all(void) {
  for (int i = 0; i < HVF_MAX_CPUS; i++) {
    if (hvf_cpus[i].live && hvf_cpus[i].created) {
      hv.vcpus_exit(&hvf_cpus[i].vcpu, 1);
    }
  }
}

// Hvf.pause() -> U32: stops every vCPU at its gate (asynchronous: poll
// Hvf.pause_state until no vCPU runs). 0, or 1 if it was already paused.
Term hvf_pause_run(Env e, Term* f, IoWork* w) {
  pthread_mutex_lock(&hvf_gate_mu);
  int was = hvf_paused;
  if (!was) {
    hvf_paused      = 1;
    hvf_pause_start = mach_absolute_time();
  }
  pthread_mutex_unlock(&hvf_gate_mu);
  hvf_kick_all();
  return (Term)(u32)was;
}

// Hvf.resume() -> U32: lets every vCPU run again.
Term hvf_resume_run(Env e, Term* f, IoWork* w) {
  pthread_mutex_lock(&hvf_gate_mu);
  hvf_paused = 0;
  pthread_cond_broadcast(&hvf_gate_cv);
  pthread_mutex_unlock(&hvf_gate_mu);
  return (Term)0;
}

// Hvf.pause_state() -> List<U32>: [paused, vCPUs still inside the guest].
Term hvf_pause_state_run(Env e, Term* f, IoWork* w) {
  pthread_mutex_lock(&hvf_gate_mu);
  uint32_t ws[2] = {(uint32_t)hvf_paused, (uint32_t)hvf_running};
  pthread_mutex_unlock(&hvf_gate_mu);
  if (ws[0] && ws[1]) {
    hvf_kick_all();
  }
  return hvf_words(e, ws, 2);
}

static int hvf_put(int fd, const void* p, size_t n) {
  const uint8_t* b = p;
  while (n) {
    ssize_t k = write(fd, b, n);
    if (k <= 0) {
      return -1;
    }
    b += k;
    n -= (size_t)k;
  }
  return 0;
}

static int hvf_fput64(int fd, uint64_t v) {
  return hvf_put(fd, &v, 8);
}

// Guest RAM, skipping all-zero 64 KiB chunks (the file stays sparse).
static int hvf_put_ram(int fd, off_t at) {
  static const uint8_t zero[65536];
  for (uint64_t o = 0; o < hvf_ram_size; o += sizeof zero) {
    size_t n = hvf_ram_size - o < sizeof zero ? (size_t)(hvf_ram_size - o) : sizeof zero;
    if (memcmp(hvf_ram + o, zero, n) == 0) {
      continue;
    }
    if (pwrite(fd, hvf_ram + o, n, at + (off_t)o) != (ssize_t)n) {
      return -1;
    }
  }
  return ftruncate(fd, at + (off_t)hvf_ram_size);
}

// Hvf.snap_write(path, words) -> U32: writes a snapshot of the paused VM:
//   "BVMSNAP1", version u32 = 1, ncpus u32, ram base u64, ram size u64,
//   args (u64 length, NUL-separated argv), machine (u64 count, u32 words),
//   GIC state (u64 size, bytes), per vCPU (u64 size, register entries; 0 when
//   absent), then RAM at the next 16 KiB boundary. 0, or an errno.
Term hvf_snap_write_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  // the machine words
  u64       cap = 1024, nw = 0;
  uint32_t* ws  = io_mem(malloc(cap * 4));
  for (Term t = f[1]; term_aux(t) == CID(Con);) {
    Term fb[2];
    spare_free(e, cls_fit(2), ctr_take(e, t, 2, fb));
    if (nw == cap) {
      cap *= 2;
      ws = io_mem(realloc(ws, cap * 4));
    }
    ws[nw++] = (uint32_t)fb[0];
    t        = fb[1];
  }
  // every created vCPU saves its registers on its own thread
  int live = 0;
  pthread_mutex_lock(&hvf_gate_mu);
  hvf_save_gen++;
  for (int i = 0; i < HVF_MAX_CPUS; i++) {
    live += hvf_cpus[i].live && hvf_cpus[i].created;
  }
  hvf_saving = live;
  pthread_cond_broadcast(&hvf_gate_cv);
  pthread_mutex_unlock(&hvf_gate_mu);
  for (int i = 0; i < HVF_MAX_CPUS; i++) {
    if (hvf_cpus[i].live) {
      pthread_mutex_lock(&hvf_cpus[i].mu);
      pthread_cond_signal(&hvf_cpus[i].cv);
      pthread_mutex_unlock(&hvf_cpus[i].mu);
    }
  }
  pthread_mutex_lock(&hvf_gate_mu);
  while (hvf_saving > 0) {
    pthread_cond_wait(&hvf_gate_cv, &hvf_gate_mu);
  }
  pthread_mutex_unlock(&hvf_gate_mu);
  // the GIC
  void*          gic  = NULL;
  size_t         ngic = 0;
  hv_gic_state_t st   = hv.gic_state_create ? hv.gic_state_create() : NULL;
  if (st && hv.gic_state_size(st, &ngic) == HV_SUCCESS) {
    gic = io_mem(malloc(ngic ? ngic : 1));
    if (hv.gic_state_data(st, gic) != HV_SUCCESS) {
      ngic = 0;
    }
  }
  if (st) {
    os_release(st);
  }
  // argv
  int    argc = *_NSGetArgc();
  char** argv = *_NSGetArgv();
  int    err  = 0;
  int    fd   = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  free(path);
  if (fd < 0) {
    err = errno;
  } else {
    uint32_t ncpus = 0;
    for (int i = 0; i < HVF_MAX_CPUS; i++) {
      if (hvf_cpus[i].created) {
        ncpus = (uint32_t)i + 1;
      }
    }
    uint64_t alen = 0;
    for (int i = 0; i < argc; i++) {
      alen += strlen(argv[i]) + 1;
    }
    uint32_t ver = 1;
    int      bad = hvf_put(fd, "BVMSNAP1", 8) || hvf_put(fd, &ver, 4) || hvf_put(fd, &ncpus, 4)
      || hvf_fput64(fd, hvf_ram_base) || hvf_fput64(fd, hvf_ram_size) || hvf_fput64(fd, alen);
    for (int i = 0; !bad && i < argc; i++) {
      bad = hvf_put(fd, argv[i], strlen(argv[i]) + 1);
    }
    bad = bad || hvf_fput64(fd, nw) || hvf_put(fd, ws, nw * 4) || hvf_fput64(fd, ngic) || hvf_put(fd, gic, ngic);
    for (uint32_t i = 0; !bad && i < ncpus; i++) {
      HvfCpu* c  = &hvf_cpus[i];
      size_t  sz = c->created ? c->nsaved : 0;
      bad = hvf_fput64(fd, sz) || hvf_put(fd, c->saved, sz);
    }
    off_t at = lseek(fd, 0, SEEK_CUR);
    at       = (at + 16383) & ~(off_t)16383;
    bad      = bad || hvf_put_ram(fd, at) != 0;
    err      = bad ? (errno ? errno : EIO) : 0;
    if (fsync(fd) != 0 && !err) {
      err = errno;
    }
    close(fd);
  }
  free(ws);
  free(gic);
  return (Term)(u32)err;
}

static int hvf_get(int fd, void* p, size_t n) {
  return read(fd, p, n) == (ssize_t)n ? 0 : -1;
}

// Hvf.snap_open(path) -> U32: reads a snapshot for a restore (the RAM is
// mapped later, by Hvf.init). 0, or an errno (EINVAL for a bad file).
Term hvf_snap_open_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  int   fd   = open(path, O_RDONLY);
  free(path);
  if (fd < 0) {
    return (Term)(u32)errno;
  }
  char     magic[8];
  uint32_t ver;
  if (hvf_get(fd, magic, 8) || memcmp(magic, "BVMSNAP1", 8) || hvf_get(fd, &ver, 4) || ver != 1
      || hvf_get(fd, &hvf_snap.ncpus, 4) || hvf_snap.ncpus > 64 || hvf_get(fd, &hvf_snap.ram_base, 8)
      || hvf_get(fd, &hvf_snap.ram_size, 8) || hvf_get(fd, &hvf_snap.nargs, 8) || hvf_snap.nargs > 1u << 20) {
    close(fd);
    return (Term)(u32)EINVAL;
  }
  hvf_snap.args = io_mem(malloc(hvf_snap.nargs + 1));
  int bad = hvf_get(fd, hvf_snap.args, hvf_snap.nargs) || hvf_get(fd, &hvf_snap.nwords, 8) || hvf_snap.nwords > 1u << 28;
  if (!bad) {
    hvf_snap.words = io_mem(malloc(hvf_snap.nwords * 4 + 4));
    bad = hvf_get(fd, hvf_snap.words, hvf_snap.nwords * 4) || hvf_get(fd, &hvf_snap.ngic, 8) || hvf_snap.ngic > 1u << 26;
  }
  if (!bad) {
    hvf_snap.gic = io_mem(malloc(hvf_snap.ngic + 1));
    bad = hvf_get(fd, hvf_snap.gic, hvf_snap.ngic);
  }
  for (uint32_t i = 0; !bad && i < hvf_snap.ncpus; i++) {
    uint64_t sz;
    bad = hvf_get(fd, &sz, 8) || sz > 1u << 20;
    if (!bad && sz) {
      hvf_snap.cpu[i]  = io_mem(malloc(sz));
      hvf_snap.ncpu[i] = sz;
      bad = hvf_get(fd, hvf_snap.cpu[i], sz);
    }
  }
  if (bad) {
    close(fd);
    return (Term)(u32)EINVAL;
  }
  off_t at         = lseek(fd, 0, SEEK_CUR);
  hvf_snap.ram_off = (uint64_t)((at + 16383) & ~(off_t)16383);
  hvf_snap.fd      = fd;
  hvf_snap.active  = 1;
  return (Term)0;
}

// Hvf.snap_info() -> List<U32>: [ncpus, RAM MiB, then 1 per vCPU that had
// registers saved, 0 otherwise].
Term hvf_snap_info_run(Env e, Term* f, IoWork* w) {
  uint32_t ws[66] = {hvf_snap.ncpus, (uint32_t)(hvf_snap.ram_size >> 20)};
  for (uint32_t i = 0; i < hvf_snap.ncpus; i++) {
    ws[2 + i] = hvf_snap.cpu[i] != NULL;
  }
  return hvf_words(e, ws, 2 + hvf_snap.ncpus);
}

// Hvf.snap_args() -> List<String>: the argv the snapshotted VMM ran with.
Term hvf_snap_args_run(Env e, Term* f, IoWork* w) {
  Term   xs = term_pak(CID(Nil), 0);
  size_t starts[4096], k = 0;
  for (size_t i = 0; i < hvf_snap.nargs && k < 4096; i += strlen(hvf_snap.args + i) + 1) {
    starts[k++] = i;
  }
  while (k > 0) {
    k--;
    const char* a = hvf_snap.args + starts[k];
    xs = io_node(e, CID(Con), io_str(e, a, strlen(a)), xs);
  }
  return xs;
}

// Hvf.snap_machine() -> List<U32>: the encoded machine (src/vmm/snapshot.bend).
Term hvf_snap_machine_run(Env e, Term* f, IoWork* w) {
  return hvf_words(e, hvf_snap.words, hvf_snap.nwords);
}

// Hvf.snap_gic() -> U32: restores the GIC state, once every vCPU exists.
Term hvf_snap_gic_run(Env e, Term* f, IoWork* w) {
  if (!hvf_snap.ngic) {
    return (Term)0;
  }
  return (Term)(hv.gic_set_state && hv.gic_set_state(hvf_snap.gic, hvf_snap.ngic) == HV_SUCCESS ? 0 : HVF_ERR);
}

// The control socket
// ==================
//
// --control PATH listens on a Unix socket; each connection sends one command
// line and gets one reply line (`echo pause | nc -U PATH`).

#include <sys/un.h>

static int hvf_ctl_fd = -1;
static int hvf_ctl_client = -1;

// Hvf.ctl_listen(path) -> U32: 0, or an errno.
Term hvf_ctl_listen_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  struct sockaddr_un a = {0};
  a.sun_family = AF_UNIX;
  if (n >= sizeof a.sun_path) {
    free(path);
    return (Term)(u32)ENAMETOOLONG;
  }
  memcpy(a.sun_path, path, n + 1);
  unlink(path);
  free(path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0 || bind(fd, (struct sockaddr*)&a, sizeof a) != 0 || listen(fd, 4) != 0) {
    int err = errno;
    if (fd >= 0) {
      close(fd);
    }
    return (Term)(u32)err;
  }
  fcntl(fd, F_SETFL, O_NONBLOCK);
  hvf_ctl_fd = fd;
  return (Term)0;
}

static Term hvf_ctl_line(Env e, IoWork* w);

static Term hvf_ctl_accept(Env e, IoWork* w) {
  int c = accept(hvf_ctl_fd, NULL, NULL);
  if (c < 0) {
    return io_wait_on(w, hvf_ctl_fd, POLLIN, 0, hvf_ctl_accept);
  }
  fcntl(c, F_SETFL, O_NONBLOCK);
  hvf_ctl_client = c;
  w->made        = 0;
  return hvf_ctl_line(e, w);
}

// Reads one line from the client into w->data.
static Term hvf_ctl_line(Env e, IoWork* w) {
  char ch;
  for (;;) {
    ssize_t k = read(hvf_ctl_client, &ch, 1);
    if (k < 0 && errno == EAGAIN) {
      return io_wait_on(w, hvf_ctl_client, POLLIN, 0, hvf_ctl_line);
    }
    if (k <= 0 || ch == '\n' || w->made >= 1023) {
      break;
    }
    w->data[w->made++] = ch;
  }
  Term t = io_list(e, w->data, (u64)w->made);
  free(w->data);
  return t;
}

// Hvf.ctl_next() -> List<U32>: parks until a client connects and sends a
// line; the line's bytes. The client stays open for Hvf.ctl_reply.
Term hvf_ctl_next_run(Env e, Term* f, IoWork* w) {
  if (hvf_ctl_fd < 0) {
    return term_pak(CID(Nil), 0);
  }
  w->data = io_mem(malloc(1024));
  return hvf_ctl_accept(e, w);
}

// Hvf.ctl_reply(text) -> U32: answers the client with a line and closes it.
Term hvf_ctl_reply_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* text = io_cstr(e, f[0], &n);
  if (hvf_ctl_client >= 0) {
    fcntl(hvf_ctl_client, F_SETFL, 0);
    (void)!write(hvf_ctl_client, text, n);
    (void)!write(hvf_ctl_client, "\n", 1);
    close(hvf_ctl_client);
    hvf_ctl_client = -1;
  }
  free(text);
  return (Term)0;
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
#ifdef CID(Hvf.share_open)
  io_eff(CID(Hvf.share_open), hvf_share_open_run);
#endif
#ifdef CID(Hvf.fs)
  io_eff(CID(Hvf.fs), hvf_fs_run);
#endif
#ifdef CID(Hvf.pause)
  io_eff(CID(Hvf.pause), hvf_pause_run);
#endif
#ifdef CID(Hvf.resume)
  io_eff(CID(Hvf.resume), hvf_resume_run);
#endif
#ifdef CID(Hvf.pause_state)
  io_eff(CID(Hvf.pause_state), hvf_pause_state_run);
#endif
#ifdef CID(Hvf.snap_write)
  io_eff(CID(Hvf.snap_write), hvf_snap_write_run);
#endif
#ifdef CID(Hvf.snap_open)
  io_eff(CID(Hvf.snap_open), hvf_snap_open_run);
#endif
#ifdef CID(Hvf.snap_info)
  io_eff(CID(Hvf.snap_info), hvf_snap_info_run);
#endif
#ifdef CID(Hvf.snap_args)
  io_eff(CID(Hvf.snap_args), hvf_snap_args_run);
#endif
#ifdef CID(Hvf.snap_machine)
  io_eff(CID(Hvf.snap_machine), hvf_snap_machine_run);
#endif
#ifdef CID(Hvf.snap_gic)
  io_eff(CID(Hvf.snap_gic), hvf_snap_gic_run);
#endif
#ifdef CID(Hvf.ctl_listen)
  io_eff(CID(Hvf.ctl_listen), hvf_ctl_listen_run);
#endif
#ifdef CID(Hvf.ctl_next)
  io_eff(CID(Hvf.ctl_next), hvf_ctl_next_run);
#endif
#ifdef CID(Hvf.ctl_reply)
  io_eff(CID(Hvf.ctl_reply), hvf_ctl_reply_run);
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
