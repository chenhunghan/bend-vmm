// bend-vmm host layer: hypervisor effects for Bend on arm64, over
// Hypervisor.framework on macOS and KVM on Linux (the "Backends" section;
// everything else is shared POSIX code).
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
#include <sys/file.h>
#include <sys/uio.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdatomic.h>
#include <signal.h>
#ifdef __APPLE__
#include <Hypervisor/Hypervisor.h>
#include <crt_externs.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#else
#include <linux/kvm.h>
#include <sys/ioctl.h>
#endif

#define HVF_MAX_CPUS 64

#ifdef __APPLE__
#define HVF_ATIME(st) (st).st_atimespec.tv_sec
#define HVF_MTIME(st) (st).st_mtimespec.tv_sec
#define HVF_CTIME(st) (st).st_ctimespec.tv_sec
#else
#define HVF_ATIME(st) (st).st_atim.tv_sec
#define HVF_MTIME(st) (st).st_mtim.tv_sec
#define HVF_CTIME(st) (st).st_ctim.tv_sec
#endif
#define HVF_ERR      0xFFFFFFFFu

#ifdef __APPLE__
// Hypervisor.framework entry points, resolved once.
static struct {
  void* lib;
  __typeof__(&hv_vm_create) vm_create;
  __typeof__(&hv_vm_map) vm_map;
  __typeof__(&hv_vm_unmap) vm_unmap;
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
  HV_SYM(vm_unmap, hv_vm_unmap);
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

#endif

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
  _Atomic int     state;    // 0 idle, 1 a request waits, 2 its answer is ready
  _Atomic int     parked;   // the Bend side sleeps on the pipe for the answer
  _Atomic int     sleeping; // the vCPU thread sleeps on cv for a request
  int             op;
  uint64_t        a, b;
  uint32_t        out[20];  // the answer, in words
  u64             nout;
  HvfQueued       queue[HVF_QUEUE];
  int             nqueue;   // under mu
  int             created;  // the hv vCPU exists
  int             saved_gen;
  uint64_t        pause_applied; // the part of hvf_pause_total in this vCPU's vtimer offset
  uint8_t*        saved;    // the last snapshot of this vCPU's registers
  size_t          nsaved;
  const uint8_t*  icc;      // GIC CPU registers to restore before the first run
  size_t          nicc;
#ifdef __APPLE__
  hv_vcpu_t       vcpu;
  hv_vcpu_exit_t* exit;
#else
  int             fd;       // the KVM vCPU
  struct kvm_run* run;
  pthread_t       tid;      // its thread, for kicks
  int             in_mmio;  // the last exit was KVM_EXIT_MMIO: the machine's
                            // X0 write is the load's data, its PC advance KVM's
#endif
} HvfCpu;

static HvfCpu hvf_cpus[HVF_MAX_CPUS];

// BEND_VMM_TRACE: bit 1 prints every exception exit on stderr, bit 2 the
// console input, interrupt line changes and TCP holds, bit 4 staged
// transmit data, bit 8 shared-folder reads and writes.
static int hvf_trace;

static void hvf_put64(HvfCpu* c, uint64_t v) {
  c->out[c->nout++] = (uint32_t)(v >> 32);
  c->out[c->nout++] = (uint32_t)v;
}

// Backends
// ========
//
// The hypervisor behind a small interface, in our register numbering (0..30
// Xn, 31 PC, 32 CPSR):
//   vmb_create(gicd, gicr, ncpus)   the VM and its GICv3
//   vmb_map(host, gpa, size, prot)  guest memory (prot: VMB_R | VMB_W | VMB_X)
//   vmb_unmap(gpa, size)
//   vmb_vcpu_create(c, cpu)         on the vCPU's thread
//   vmb_get(c, r), vmb_set(c, r, v), vmb_advance_pc(c)
//   vmb_exit(c)                     runs the guest, encodes the exit (hvf_run)
//   vmb_vtimer_mask(c, on), vmb_spi(intid, level), vmb_kick(c)

enum { VMB_R = 1, VMB_W = 2, VMB_X = 4 };

static uint64_t hvf_ns(void);
static inline void hvf_relax(void);

#ifdef __APPLE__

static uint64_t hvf_reg(HvfCpu* c, hv_reg_t r) {
  uint64_t v = 0;
  hv.get_reg(c->vcpu, r, &v);
  return v;
}

static hv_reg_t hvf_reg_of(uint64_t r) {
  return r <= 30 ? (hv_reg_t)(HV_REG_X0 + r) : r == 31 ? HV_REG_PC : HV_REG_CPSR;
}

static uint64_t vmb_get(HvfCpu* c, uint64_t r) {
  return hvf_reg(c, hvf_reg_of(r));
}

static int vmb_set(HvfCpu* c, uint64_t r, uint64_t v) {
  return hv.set_reg(c->vcpu, hvf_reg_of(r), v) == HV_SUCCESS ? 0 : -1;
}

static void vmb_advance_pc(HvfCpu* c) {
  hv.set_reg(c->vcpu, HV_REG_PC, hvf_reg(c, HV_REG_PC) + 4);
}

static int vmb_open(void) {
  return hvf_open();
}

static int vmb_create(uint64_t gicd, uint64_t gicr, uint32_t ncpus) {
  if (hv.vm_create(NULL) != HV_SUCCESS) {
    return 2;
  }
  hv_gic_config_t gic = hv.gic_config_create();
  if (hv.gic_set_dist(gic, gicd) != HV_SUCCESS || hv.gic_set_redist(gic, gicr) != HV_SUCCESS
      || hv.gic_create(gic) != HV_SUCCESS) {
    return 3;
  }
  return 0;
}

static int vmb_map(void* host, uint64_t gpa, uint64_t size, int prot) {
  hv_memory_flags_t fl = ((prot & VMB_R) ? HV_MEMORY_READ : 0) | ((prot & VMB_W) ? HV_MEMORY_WRITE : 0)
                         | ((prot & VMB_X) ? HV_MEMORY_EXEC : 0);
  return hv.vm_map(host, gpa, size, fl) == HV_SUCCESS ? 0 : -1;
}

static int vmb_unmap(uint64_t gpa, uint64_t size) {
  return hv.vm_unmap(gpa, size) == HV_SUCCESS ? 0 : -1;
}

static int vmb_vcpu_create(HvfCpu* c, int cpu) {
  hv_return_t r = hv.vcpu_create(&c->vcpu, &c->exit, NULL);
  if (r == HV_SUCCESS) {
    // Aff0 = cpu index; bit 31 is RES1. The GIC routes by affinity.
    r = hv.set_sys_reg(c->vcpu, HV_SYS_REG_MPIDR_EL1, (1ull << 31) | (uint64_t)cpu);
  }
  return r == HV_SUCCESS ? 0 : (int)r;
}

static int vmb_vtimer_mask(HvfCpu* c, int on) {
  return hv.set_vtimer_mask(c->vcpu, on) == HV_SUCCESS ? 0 : -1;
}

static int vmb_spi(uint32_t intid, int level) {
  return hv.gic_set_spi(intid, level) == HV_SUCCESS ? 0 : -1;
}

static int vmb_kick(HvfCpu* c) {
  return hv.vcpus_exit(&c->vcpu, 1) == HV_SUCCESS ? 0 : -1;
}

#else // KVM

static int      kvm_fd = -1, kvm_vm = -1, kvm_gic = -1;
static size_t   kvm_run_size;
static uint32_t kvm_ncpus;

static uint64_t kvm_core(uint64_t off) {
  return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (off / sizeof(uint32_t));
}

static uint64_t kvm_reg_id(uint64_t r) {
  return r <= 30 ? kvm_core(offsetof(struct kvm_regs, regs.regs) + 8 * r)
         : r == 31 ? kvm_core(offsetof(struct kvm_regs, regs.pc))
                   : kvm_core(offsetof(struct kvm_regs, regs.pstate));
}

static uint64_t vmb_get(HvfCpu* c, uint64_t r) {
  uint64_t            v   = 0;
  struct kvm_one_reg  one = {kvm_reg_id(r), (uint64_t)(uintptr_t)&v};
  ioctl(c->fd, KVM_GET_ONE_REG, &one);
  return v;
}

static int vmb_set(HvfCpu* c, uint64_t r, uint64_t v) {
  if (c->in_mmio && r == 0) {
    // the machine answers a trapped load in X0 (SRT 0, see vmb_exit): KVM
    // writes the real target register from mmio.data on the next KVM_RUN
    memcpy(c->run->mmio.data, &v, sizeof c->run->mmio.data);
    return 0;
  }
  struct kvm_one_reg one = {kvm_reg_id(r), (uint64_t)(uintptr_t)&v};
  return ioctl(c->fd, KVM_SET_ONE_REG, &one) == 0 ? 0 : -1;
}

static void vmb_advance_pc(HvfCpu* c) {
  if (!c->in_mmio) {
    vmb_set(c, 31, vmb_get(c, 31) + 4);
  }
}

static int vmb_open(void) {
  if (kvm_fd >= 0) {
    return 0;
  }
  kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
  return kvm_fd >= 0 && ioctl(kvm_fd, KVM_GET_API_VERSION, 0) == KVM_API_VERSION ? 0 : -1;
}

static void kvm_signal(int sig) {
  (void)sig;
}

static int kvm_gic_attr(uint32_t group, uint64_t attr, void* addr) {
  struct kvm_device_attr a = {0, group, attr, (uint64_t)(uintptr_t)addr};
  return ioctl(kvm_gic, KVM_SET_DEVICE_ATTR, &a);
}

// The VM's IPA space is KVM's default 40 bits, so the vCPUs must not claim
// more: ID_AA64MMFR0_EL1's PARange is clamped to 40 bits and the 52-bit
// (LPA2) granule claims dropped. A guest that believed them (edk2 does)
// would build 52-bit page tables. KVM 6.7+ lets userspace lower these
// fields before the first run; older kernels keep the host's values.
static void kvm_clamp_pa(HvfCpu* c) {
  uint64_t           v   = 0;
  struct kvm_one_reg one = {ARM64_SYS_REG(3, 0, 0, 7, 0), (uint64_t)(uintptr_t)&v};
  if (ioctl(c->fd, KVM_GET_ONE_REG, &one) != 0) {
    return;
  }
  uint64_t pa = v & 0xf, tgran16 = (v >> 20) & 0xf, tgran4 = (v >> 28) & 0xf;
  v = (v & ~0xfull) | (pa > 2 ? 2 : pa);
  if (tgran16 == 2) {
    v = (v & ~(0xfull << 20)) | (1ull << 20);
  }
  if (tgran4 == 1) {
    v &= ~(0xfull << 28);
  }
  if (ioctl(c->fd, KVM_SET_ONE_REG, &one) != 0 && (hvf_trace & 1)) {
    fprintf(stderr, "[trace] cannot clamp ID_AA64MMFR0_EL1: %s\n", strerror(errno));
  }
}

// Every vCPU exists before the vGIC initializes, so all ncpus are created
// here (their threads come later); PSCI calls go to the machine (the SMCCC
// filter), as Hypervisor.framework gives them.
static int vmb_create(uint64_t gicd, uint64_t gicr, uint32_t ncpus) {
  kvm_vm = ioctl(kvm_fd, KVM_CREATE_VM, 0);
  if (kvm_vm < 0) {
    return 2;
  }
  kvm_run_size = (size_t)ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
  struct kvm_create_device dev = {KVM_DEV_TYPE_ARM_VGIC_V3, 0, 0};
  if (ioctl(kvm_vm, KVM_CREATE_DEVICE, &dev) != 0) {
    return 3;
  }
  kvm_gic = (int)dev.fd;
  if (kvm_gic_attr(KVM_DEV_ARM_VGIC_GRP_ADDR, KVM_VGIC_V3_ADDR_TYPE_DIST, &gicd) != 0
      || kvm_gic_attr(KVM_DEV_ARM_VGIC_GRP_ADDR, KVM_VGIC_V3_ADDR_TYPE_REDIST, &gicr) != 0) {
    return 3;
  }
  struct kvm_vcpu_init init;
  if (ioctl(kvm_vm, KVM_ARM_PREFERRED_TARGET, &init) != 0) {
    return 6;
  }
  init.features[0] |= 1u << KVM_ARM_VCPU_PSCI_0_2;
  kvm_ncpus = ncpus ? ncpus : 1;
  for (uint32_t i = 0; i < kvm_ncpus && i < HVF_MAX_CPUS; i++) {
    HvfCpu* c = &hvf_cpus[i];
    c->fd     = ioctl(kvm_vm, KVM_CREATE_VCPU, (unsigned long)i);
    if (c->fd < 0 || ioctl(c->fd, KVM_ARM_VCPU_INIT, &init) != 0) {
      return 7;
    }
    c->run = mmap(NULL, kvm_run_size, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd, 0);
    if (c->run == MAP_FAILED) {
      return 7;
    }
    kvm_clamp_pa(c);
  }
  uint32_t nirqs = 256;
  if (kvm_gic_attr(KVM_DEV_ARM_VGIC_GRP_NR_IRQS, 0, &nirqs) != 0
      || kvm_gic_attr(KVM_DEV_ARM_VGIC_GRP_CTRL, KVM_DEV_ARM_VGIC_CTRL_INIT, NULL) != 0) {
    return 8;
  }
#ifdef KVM_ARM_VM_SMCCC_FILTER
  struct kvm_smccc_filter psci32 = {0x84000000u, 32, KVM_SMCCC_FILTER_FWD_TO_USER, {0}};
  struct kvm_smccc_filter psci64 = {0xC4000000u, 32, KVM_SMCCC_FILTER_FWD_TO_USER, {0}};
  struct kvm_device_attr  f32    = {0, KVM_ARM_VM_SMCCC_CTRL, KVM_ARM_VM_SMCCC_FILTER, (uint64_t)(uintptr_t)&psci32};
  struct kvm_device_attr  f64    = {0, KVM_ARM_VM_SMCCC_CTRL, KVM_ARM_VM_SMCCC_FILTER, (uint64_t)(uintptr_t)&psci64};
  if (ioctl(kvm_vm, KVM_SET_DEVICE_ATTR, &f32) != 0 || ioctl(kvm_vm, KVM_SET_DEVICE_ATTR, &f64) != 0) {
    return 9;
  }
#else
  return 9;
#endif
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = kvm_signal;
  sigaction(SIGUSR1, &sa, NULL);
  return 0;
}

// Memory slots by guest base: RAM, the flash banks, the framebuffer.
static uint32_t kvm_slot(uint64_t gpa) {
  return gpa == 0 ? 1 : gpa == 0x4000000ull ? 2 : gpa == 0x10000000ull ? 3 : 0;
}

static int vmb_map(void* host, uint64_t gpa, uint64_t size, int prot) {
  struct kvm_userspace_memory_region m = {kvm_slot(gpa), (prot & VMB_W) ? 0 : KVM_MEM_READONLY, gpa, size,
                                          (uint64_t)(uintptr_t)host};
  return ioctl(kvm_vm, KVM_SET_USER_MEMORY_REGION, &m) == 0 ? 0 : -1;
}

static int vmb_unmap(uint64_t gpa, uint64_t size) {
  struct kvm_userspace_memory_region m = {kvm_slot(gpa), 0, gpa, 0, 0};
  (void)size;
  return ioctl(kvm_vm, KVM_SET_USER_MEMORY_REGION, &m) == 0 ? 0 : -1;
}

static int vmb_vcpu_create(HvfCpu* c, int cpu) {
  if ((uint32_t)cpu >= kvm_ncpus || c->fd <= 0) {
    return -1;
  }
  c->tid = pthread_self();
  // MPIDR: Aff0 = cpu index (bit 31 RES1), as the device tree numbers CPUs
  uint64_t           mpidr = (1ull << 31) | (uint64_t)cpu;
  struct kvm_one_reg one   = {ARM64_SYS_REG(3, 0, 0, 0, 5), (uint64_t)(uintptr_t)&mpidr};
  ioctl(c->fd, KVM_SET_ONE_REG, &one);
  return 0;
}

static int vmb_vtimer_mask(HvfCpu* c, int on) {
  (void)c;
  (void)on;
  return 0; // KVM drives the virtual timer itself
}

static int vmb_spi(uint32_t intid, int level) {
  struct kvm_irq_level l;
  l.irq   = (KVM_ARM_IRQ_TYPE_SPI << KVM_ARM_IRQ_TYPE_SHIFT) | intid;
  l.level = level ? 1 : 0;
  return ioctl(kvm_vm, KVM_IRQ_LINE, &l) == 0 ? 0 : -1;
}

static int vmb_kick(HvfCpu* c) {
  if (!c->run) {
    return -1;
  }
  c->run->immediate_exit = 1;
  return pthread_kill(c->tid, SIGUSR1) == 0 ? 0 : -1;
}

#endif

// Applies one queued register write or PC advance.
static void hvf_apply(HvfCpu* c, HvfQueued* q) {
  if (q->op == OP_SET_REG) {
    vmb_set(c, q->a, q->b);
  } else if (q->op == OP_ADVANCE_PC) {
    vmb_advance_pc(c);
  }
}

// Pause, snapshots and restore
// =============================
//
// A paused VM keeps every vCPU out of the guest: a vCPU about to run waits at
// a gate, and pause kicks the running ones out (hv_vcpus_exit). While paused
// the guest's virtual counter stands still: resume adds the pause's length to
// a total, and every vCPU, before it next runs, moves its vtimer offset by
// whatever part of that total it has not applied yet. So every vCPU's counter
// moves by the same amount, whether or not it waited at the gate (a vCPU busy
// in an exit through a whole pause applies it later), and the counters stay
// in step. A snapshot asks each vCPU thread to save its own registers (only
// the owning thread may read them) and waits for all.

static pthread_mutex_t hvf_gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  hvf_gate_cv = PTHREAD_COND_INITIALIZER;
static int             hvf_paused;
static int             hvf_running;     // vCPUs inside hv_vcpu_run
static uint64_t        hvf_pause_start; // the host clock at pause (mach_absolute_time on macOS)
static uint64_t        hvf_pause_total; // the length of every pause so far, in the same units
static int             hvf_save_gen;    // bumped by each snapshot
static int             hvf_saving;      // vCPU threads still to save

#ifdef __APPLE__

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

// The host clock a restore counts from: one instant for every vCPU, so their
// virtual counters come back in step (set when the snapshot is opened).
static uint64_t hvf_restore_now;

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
      hv.set_vtimer_offset(c->vcpu, hvf_restore_now - e[i].val);
    }
  }
  for (uint32_t q = 0; q < 32; q++) {
    hv_simd_fp_uchar16_t v;
    memcpy(&v, &half[2 * q], 16);
    hv.set_simd(c->vcpu, (hv_simd_fp_reg_t)(HV_SIMD_FP_REG_Q0 + q), v);
  }
}

// The in-kernel GIC's state, as Hypervisor.framework serializes it.
static void vmb_gic_save(uint8_t** out, size_t* nout) {
  void*          gic  = NULL;
  size_t         ngic = 0;
  hv_gic_state_t st   = hv.gic_state_create ? hv.gic_state_create() : NULL;
  if (st && hv.gic_state_size(st, &ngic) == HV_SUCCESS) {
    gic = io_mem(malloc(ngic ? ngic : 1));
    if (hv.gic_state_data(st, gic) != HV_SUCCESS) {
      ngic = 0;
    }
  }
#if !defined(__OBJC__) || !__has_feature(objc_arc)
  if (st) {
    os_release(st);
  }
#else
  st = nil; // ARC releases it
#endif
  *out  = gic;
  *nout = ngic;
}

static int vmb_gic_restore(const uint8_t* blob, size_t size) {
  return hv.gic_set_state && hv.gic_set_state(blob, size) == HV_SUCCESS ? 0 : -1;
}

#define HVF_SNAP_VER 1

#else

// A vCPU's registers as KVM lists them (KVM_GET_REG_LIST): entries
// {u64 id, value}, each value as wide as its id says (KVM_REG_SIZE). A load
// trapped as MMIO completes first (KVM_RUN with immediate_exit writes the
// answer into its register), so the snapshot holds the finished exit.
static size_t kvm_reg_size(uint64_t id) {
  return (size_t)1 << ((id & KVM_REG_SIZE_MASK) >> KVM_REG_SIZE_SHIFT);
}

static void hvf_save_regs(HvfCpu* c) {
  free(c->saved);
  c->saved  = NULL;
  c->nsaved = 0;
  if (c->in_mmio) {
    c->run->immediate_exit = 1;
    ioctl(c->fd, KVM_RUN, 0);
    c->run->immediate_exit = 0;
    c->in_mmio             = 0;
  }
  struct kvm_reg_list probe = {0};
  ioctl(c->fd, KVM_GET_REG_LIST, &probe); // E2BIG, with the count
  struct kvm_reg_list* list = io_mem(malloc(sizeof *list + probe.n * sizeof(uint64_t)));
  list->n                   = probe.n;
  if (ioctl(c->fd, KVM_GET_REG_LIST, list) != 0) {
    free(list);
    return;
  }
  size_t   cap = 0, n = 0;
  for (uint64_t i = 0; i < list->n; i++) {
    cap += 8 + kvm_reg_size(list->reg[i]);
  }
  uint8_t* b = io_mem(malloc(cap ? cap : 1));
  for (uint64_t i = 0; i < list->n; i++) {
    uint64_t           id  = list->reg[i];
    size_t             sz  = kvm_reg_size(id);
    struct kvm_one_reg one = {id, (uint64_t)(uintptr_t)(b + n + 8)};
    if (sz <= 256 && ioctl(c->fd, KVM_GET_ONE_REG, &one) == 0) {
      memcpy(b + n, &id, 8);
      n += 8 + sz;
    }
  }
  free(list);
  c->saved  = b;
  c->nsaved = n;
}

// Sets every saved register; KVM refuses the few it keeps fixed (some ID
// registers), which already hold the saved values on the same host.
static void hvf_load_regs(HvfCpu* c, const uint8_t* blob, size_t size) {
  for (size_t at = 0; at + 8 <= size;) {
    uint64_t id;
    memcpy(&id, blob + at, 8);
    size_t sz = kvm_reg_size(id);
    if (at + 8 + sz > size) {
      break;
    }
    uint8_t            v[256];
    if (sz > sizeof v) {
      break; // no register is wider (the save side keeps to 256 bytes)
    }
    memcpy(v, blob + at + 8, sz);
    struct kvm_one_reg one = {id, (uint64_t)(uintptr_t)v};
    ioctl(c->fd, KVM_SET_ONE_REG, &one);
    at += 8 + sz;
  }
}

// The vGIC's state as a replay: entries {u32 group, u32 width, u64 attr,
// u64 value}, written back in order with KVM_SET_DEVICE_ATTR. Each set of
// enable, pending or active bits comes after a write of all ones to its
// clear register, so the restored bits are exactly the saved ones. The order
// follows the architecture's dependencies: distributor control,
// redistributors (SGIs, PPIs), SPIs (configuration, routing, line levels,
// then pending, active, enabled), the CPU interfaces.
typedef struct {
  uint32_t group, width;
  uint64_t attr, val;
} __attribute__((packed)) KvmGicEntry;

typedef struct {
  KvmGicEntry* e;
  size_t       n, cap;
} KvmGicSave;

static void kvm_gic_put(KvmGicSave* g, uint32_t group, uint32_t width, uint64_t attr, uint64_t val) {
  if (g->n == g->cap) {
    g->cap = g->cap ? g->cap * 2 : 512;
    g->e   = io_mem(realloc(g->e, g->cap * sizeof *g->e));
  }
  g->e[g->n++] = (KvmGicEntry){group, width, attr, val};
}

// Reads one register into the replay; one KVM does not have is left out.
static void kvm_gic_keep(KvmGicSave* g, uint32_t group, uint32_t width, uint64_t attr) {
  uint64_t               v = 0;
  struct kvm_device_attr a = {0, group, attr, (uint64_t)(uintptr_t)&v};
  if (ioctl(kvm_gic, KVM_GET_DEVICE_ATTR, &a) == 0) {
    kvm_gic_put(g, group, width, attr, width == 4 ? (uint32_t)v : v);
  }
}

// clear-all at off_clear, then the saved bits of off_set
static void kvm_gic_bits(KvmGicSave* g, uint32_t group, uint64_t base, uint64_t off_set, uint64_t off_clear) {
  kvm_gic_put(g, group, 4, base | off_clear, 0xffffffffu);
  kvm_gic_keep(g, group, 4, base | off_set);
}

#define KVM_GIC_SYSREG(op0, op1, crn, crm, op2)                                                         \
  (((uint64_t)(op0) << KVM_REG_ARM64_SYSREG_OP0_SHIFT) | ((uint64_t)(op1) << KVM_REG_ARM64_SYSREG_OP1_SHIFT) \
   | ((uint64_t)(crn) << KVM_REG_ARM64_SYSREG_CRN_SHIFT) | ((uint64_t)(crm) << KVM_REG_ARM64_SYSREG_CRM_SHIFT) \
   | ((uint64_t)(op2) << KVM_REG_ARM64_SYSREG_OP2_SHIFT))

static void vmb_gic_save(uint8_t** out, size_t* nout) {
  KvmGicSave g     = {0};
  uint32_t   nirqs = 0;
  struct kvm_device_attr a = {0, KVM_DEV_ARM_VGIC_GRP_NR_IRQS, 0, (uint64_t)(uintptr_t)&nirqs};
  if (ioctl(kvm_gic, KVM_GET_DEVICE_ATTR, &a) != 0 || nirqs > 1024) {
    nirqs = 256;
  }
  const uint32_t D = KVM_DEV_ARM_VGIC_GRP_DIST_REGS, R = KVM_DEV_ARM_VGIC_GRP_REDIST_REGS;
  kvm_gic_keep(&g, D, 4, 0x0000); // GICD_CTLR
  for (uint32_t cpu = 0; cpu < kvm_ncpus; cpu++) {
    uint64_t m = (uint64_t)cpu << KVM_DEV_ARM_VGIC_V3_MPIDR_SHIFT;
    kvm_gic_keep(&g, R, 4, m | 0x10080); // IGROUPR0
    kvm_gic_keep(&g, R, 4, m | 0x10c00); // ICFGR0
    kvm_gic_keep(&g, R, 4, m | 0x10c04); // ICFGR1
    for (uint64_t i = 0; i < 8; i++) {
      kvm_gic_keep(&g, R, 4, m | (0x10400 + 4 * i)); // IPRIORITYR
    }
    kvm_gic_bits(&g, R, m, 0x10200, 0x10280); // ISPENDR0 / ICPENDR0
    kvm_gic_bits(&g, R, m, 0x10300, 0x10380); // ISACTIVER0 / ICACTIVER0
    kvm_gic_bits(&g, R, m, 0x10100, 0x10180); // ISENABLER0 / ICENABLER0
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 32) {
    kvm_gic_keep(&g, D, 4, 0x0080 + irq / 8); // IGROUPR
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 4) {
    kvm_gic_keep(&g, D, 4, 0x0400 + irq); // IPRIORITYR
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 16) {
    kvm_gic_keep(&g, D, 4, 0x0c00 + irq / 4); // ICFGR
  }
  for (uint32_t irq = 32; irq < nirqs; irq++) {
    kvm_gic_keep(&g, D, 4, 0x6000 + 8 * (uint64_t)irq);     // IROUTER, low half
    kvm_gic_keep(&g, D, 4, 0x6000 + 8 * (uint64_t)irq + 4); // and high
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 32) {
    kvm_gic_keep(&g, KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, 4,
                 ((uint64_t)VGIC_LEVEL_INFO_LINE_LEVEL << KVM_DEV_ARM_VGIC_LINE_LEVEL_INFO_SHIFT) | irq);
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 32) {
    kvm_gic_bits(&g, D, 0, 0x0200 + irq / 8, 0x0280 + irq / 8); // ISPENDR / ICPENDR
    kvm_gic_bits(&g, D, 0, 0x0300 + irq / 8, 0x0380 + irq / 8); // ISACTIVER / ICACTIVER
  }
  for (uint32_t irq = 32; irq < nirqs; irq += 32) {
    kvm_gic_bits(&g, D, 0, 0x0100 + irq / 8, 0x0180 + irq / 8); // ISENABLER / ICENABLER
  }
  const uint32_t C = KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS;
  const uint64_t icc[] = {
    KVM_GIC_SYSREG(3, 0, 12, 12, 5), // ICC_SRE_EL1
    KVM_GIC_SYSREG(3, 0, 12, 12, 4), // ICC_CTLR_EL1
    KVM_GIC_SYSREG(3, 0, 4, 6, 0),   // ICC_PMR_EL1
    KVM_GIC_SYSREG(3, 0, 12, 8, 3),  // ICC_BPR0_EL1
    KVM_GIC_SYSREG(3, 0, 12, 12, 3), // ICC_BPR1_EL1
    KVM_GIC_SYSREG(3, 0, 12, 8, 4),  // ICC_AP0R0_EL1 .. 3
    KVM_GIC_SYSREG(3, 0, 12, 8, 5),
    KVM_GIC_SYSREG(3, 0, 12, 8, 6),
    KVM_GIC_SYSREG(3, 0, 12, 8, 7),
    KVM_GIC_SYSREG(3, 0, 12, 9, 0),  // ICC_AP1R0_EL1 .. 3
    KVM_GIC_SYSREG(3, 0, 12, 9, 1),
    KVM_GIC_SYSREG(3, 0, 12, 9, 2),
    KVM_GIC_SYSREG(3, 0, 12, 9, 3),
    KVM_GIC_SYSREG(3, 0, 12, 12, 6), // ICC_IGRPEN0_EL1
    KVM_GIC_SYSREG(3, 0, 12, 12, 7), // ICC_IGRPEN1_EL1
  };
  for (uint32_t cpu = 0; cpu < kvm_ncpus; cpu++) {
    for (size_t i = 0; i < sizeof icc / sizeof *icc; i++) {
      kvm_gic_keep(&g, C, 8, ((uint64_t)cpu << KVM_DEV_ARM_VGIC_V3_MPIDR_SHIFT) | icc[i]);
    }
  }
  *out  = (uint8_t*)g.e;
  *nout = g.n * sizeof *g.e;
}

static int vmb_gic_restore(const uint8_t* blob, size_t size) {
  const KvmGicEntry* e   = (const KvmGicEntry*)blob;
  int                bad = 0;
  for (size_t i = 0; i < size / sizeof *e; i++) {
    uint64_t               v32 = (uint32_t)e[i].val, v64 = e[i].val;
    struct kvm_device_attr a   = {0, e[i].group, e[i].attr, (uint64_t)(uintptr_t)(e[i].width == 4 ? &v32 : &v64)};
    if (ioctl(kvm_gic, KVM_SET_DEVICE_ATTR, &a) != 0) {
      if (bad++ == 0 || (hvf_trace & 1)) {
        fprintf(stderr, "bend-vmm: vGIC restore: group %u attr %#llx: %s\n", e[i].group, (unsigned long long)e[i].attr,
                strerror(errno));
        for (uint32_t c = 0; bad == 1 && c < kvm_ncpus; c++) {
          uint64_t           mp  = 0;
          struct kvm_one_reg one = {ARM64_SYS_REG(3, 0, 0, 0, 5), (uint64_t)(uintptr_t)&mp};
          int                r   = ioctl(hvf_cpus[c].fd, KVM_GET_ONE_REG, &one);
          fprintf(stderr, "bend-vmm:   vCPU %u (fd %d): MPIDR %#llx (%d)\n", c, hvf_cpus[c].fd, (unsigned long long)mp, r);
        }
      }
    }
  }
  return bad;
}

#define HVF_SNAP_VER 2

#endif

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
#ifdef __APPLE__
  const HvfRegEntry* e = (const HvfRegEntry*)c->icc;
  size_t             n = c->nicc / sizeof *e;
  for (size_t i = 0; hv.set_icc && i < n; i++) {
    if (e[i].key >> 16 == 5) {
      hv.set_icc(c->vcpu, (hv_gic_icc_reg_t)(e[i].key & 0xffff), e[i].val);
    }
  }
#endif
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
  uint64_t total = hvf_pause_total;
  hvf_running++;
  pthread_mutex_unlock(&hvf_gate_mu);
  (void)waited;
#ifdef __APPLE__
  if (total != c->pause_applied) {
    uint64_t off = 0;
    hv.get_vtimer_offset(c->vcpu, &off);
    hv.set_vtimer_offset(c->vcpu, off + (total - c->pause_applied));
    c->pause_applied = total;
  }
#else
  (void)total; // KVM's counter keeps running through a pause
#endif
}

static void hvf_ungate(void) {
  pthread_mutex_lock(&hvf_gate_mu);
  hvf_running--;
  pthread_cond_broadcast(&hvf_gate_cv);
  pthread_mutex_unlock(&hvf_gate_mu);
}

#ifdef __APPLE__

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

#else

static void hvf_put_exception(HvfCpu* c, uint64_t esr, uint64_t ipa, const uint64_t x[4], uint64_t xt) {
  c->out[c->nout++] = 0;
  hvf_put64(c, esr);
  hvf_put64(c, 0);
  hvf_put64(c, ipa);
  for (int i = 0; i < 4; i++) {
    hvf_put64(c, x[i]);
  }
  hvf_put64(c, xt);
  if (hvf_trace & 1) {
    fprintf(stderr, "[trace] esr=%08llx ipa=%09llx x0=%llx xt=%llx pc=%llx\n", (unsigned long long)esr,
      (unsigned long long)ipa, (unsigned long long)x[0], (unsigned long long)xt,
      (unsigned long long)vmb_get(c, 31));
  }
}

// KVM's exits in Hypervisor.framework's terms, so the machine sees one
// hypervisor: an MMIO exit becomes a data abort with a valid syndrome (the
// access size, direction, SRT 0 and the stored value), a forwarded PSCI call
// an HVC (or SMC) with X0..X3, a PSCI system event (kernels without the
// SMCCC filter) an HVC of SYSTEM_OFF or SYSTEM_RESET, a signal a cancel.
static void hvf_run(HvfCpu* c) {
  hvf_gate(c);
  c->in_mmio = 0;
  int r   = ioctl(c->fd, KVM_RUN, 0);
  int err = errno;
  hvf_ungate();
  c->run->immediate_exit = 0;
  if (r < 0) {
    if (hvf_trace & 1) {
      // the guest's EL1 state: ESR, ELR, FAR, SCTLR, TCR, TTBR0, MMFR0
      static const char* names[] = {"esr", "elr", "far", "sctlr", "tcr", "ttbr0", "mmfr0"};
      uint64_t           ids[7]  = {ARM64_SYS_REG(3, 0, 5, 2, 0), ARM64_SYS_REG(3, 0, 4, 0, 1),
                  ARM64_SYS_REG(3, 0, 6, 0, 0), ARM64_SYS_REG(3, 0, 1, 0, 0), ARM64_SYS_REG(3, 0, 2, 0, 2),
                  ARM64_SYS_REG(3, 0, 2, 0, 0), ARM64_SYS_REG(3, 0, 0, 7, 0)};
      fprintf(stderr, "[trace] kvm_run: %s, pc=%llx lr=%llx", strerror(err), (unsigned long long)vmb_get(c, 31),
        (unsigned long long)vmb_get(c, 30));
      for (int i = 0; i < 7; i++) {
        uint64_t           v   = 0;
        struct kvm_one_reg one = {ids[i], (uint64_t)(uintptr_t)&v};
        ioctl(c->fd, KVM_GET_ONE_REG, &one);
        fprintf(stderr, " %s=%llx", names[i], (unsigned long long)v);
      }
      fprintf(stderr, "\n");
    }
    c->out[c->nout++] = err == EINTR || err == EAGAIN ? 2 : 1000 + (uint32_t)err;
    return;
  }
  uint64_t x[4] = {0, 0, 0, 0};
  switch (c->run->exit_reason) {
    case KVM_EXIT_MMIO: {
      uint32_t len = c->run->mmio.len;
      uint64_t sas = len == 1 ? 0 : len == 2 ? 1 : len == 4 ? 2 : 3;
      uint64_t esr = (0x24ull << 26) | (1ull << 25) | (1ull << 24) | (sas << 22) | (len == 8 ? 1ull << 15 : 0)
                     | (c->run->mmio.is_write ? 1ull << 6 : 0);
      uint64_t xt = 0;
      if (c->run->mmio.is_write) {
        memcpy(&xt, c->run->mmio.data, len <= 8 ? len : 8);
      }
      c->in_mmio = 1;
      hvf_put_exception(c, esr, c->run->mmio.phys_addr, x, xt);
      break;
    }
    case KVM_EXIT_HYPERCALL: {
      int smc = 0;
#ifdef KVM_HYPERCALL_EXIT_SMC
      smc = (c->run->hypercall.flags & KVM_HYPERCALL_EXIT_SMC) != 0;
#endif
      for (int i = 0; i < 4; i++) {
        x[i] = vmb_get(c, (uint64_t)i);
      }
      hvf_put_exception(c, ((smc ? 0x17ull : 0x16ull) << 26) | (1ull << 25), 0, x, 0);
      break;
    }
    case KVM_EXIT_SYSTEM_EVENT:
      x[0] = c->run->system_event.type == KVM_SYSTEM_EVENT_RESET ? 0x84000009u : 0x84000008u;
      hvf_put_exception(c, (0x16ull << 26) | (1ull << 25), 0, x, 0);
      break;
    case KVM_EXIT_INTR:
      c->out[c->nout++] = 2;
      break;
    default:
      c->out[c->nout++] = 3 + c->run->exit_reason;
      break;
  }
}

#endif

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
      int r = vmb_vcpu_create(c, cpu);
      if (r == 0) {
        c->created = 1;
        pthread_mutex_lock(&hvf_gate_mu);
        c->saved_gen = hvf_save_gen;
        pthread_mutex_unlock(&hvf_gate_mu);
        hvf_restore_cpu(c, cpu);
      }
      c->out[c->nout++] = (uint32_t)r;
      break;
    }
    case OP_RUN:
      hvf_run(c);
      break;
    case OP_SET_REG:
      // a: our register number (0..30 Xn, 31 PC, 32 CPSR), b: value
      c->out[c->nout++] = vmb_set(c, c->a, c->b) == 0 ? 0 : HVF_ERR;
      break;
    case OP_GET_REG:
      hvf_put64(c, vmb_get(c, c->a));
      break;
    case OP_SET_VTIMER_MASK:
      c->out[c->nout++] = vmb_vtimer_mask(c, c->a != 0) == 0 ? 0 : HVF_ERR;
      break;
  }
}

// The handoff between the Bend event loop and a vCPU thread spins briefly
// before it sleeps: an MMIO exit usually comes back within microseconds, and
// a futex or pipe round trip costs more than that.
#define HVF_SPIN_NS 40000

static inline void hvf_relax(void) {
  __asm__ volatile("yield");
}

static uint64_t hvf_ns(void) {
#ifdef __APPLE__
  static mach_timebase_info_data_t tb;
  if (!tb.denom) {
    mach_timebase_info(&tb);
  }
  return mach_absolute_time() * tb.numer / tb.denom;
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
#endif
}

static void* hvf_thread(void* arg) {
  int     cpu = (int)(intptr_t)arg;
  HvfCpu* c   = &hvf_cpus[cpu];
  for (;;) {
    uint64_t until = hvf_ns() + HVF_SPIN_NS;
    while (atomic_load(&c->state) != 1) {
      if (hvf_ns() < until) {
        hvf_relax();
        continue;
      }
      // idle: answer snapshot requests, then sleep until a request
      hvf_service(c);
      pthread_mutex_lock(&c->mu);
      atomic_store(&c->sleeping, 1);
      if (atomic_load(&c->state) != 1) {
        struct timespec t;
        clock_gettime(CLOCK_REALTIME, &t);
        t.tv_nsec += 20000000;
        if (t.tv_nsec >= 1000000000) {
          t.tv_sec++;
          t.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&c->cv, &c->mu, &t);
      }
      atomic_store(&c->sleeping, 0);
      pthread_mutex_unlock(&c->mu);
    }
    hvf_do(c, cpu);
    atomic_store(&c->state, 2);
    if (atomic_load(&c->parked)) {
      char b = 1;
      (void)!write(c->pipe[1], &b, 1);
    }
  }
  return NULL;
}

// Effects
// =======

// Hvf.init(ram_mb, gicd_hi, gicd_lo, gicr_hi, gicr_lo, ram_hi, ram_lo, cpus)
// -> U32: creates the VM, its GICv3 and RAM. 0 on success, else a step code.
Term hvf_init_run(Env e, Term* f, IoWork* w) {
  if (vmb_open() != 0) {
    return (Term)1;
  }
  hvf_trace = getenv("BEND_VMM_TRACE") ? atoi(getenv("BEND_VMM_TRACE")) : 0;
  if ((u32)f[7] == 0 || (u32)f[7] > HVF_MAX_CPUS) {
    return (Term)6; // 1 to 64 vCPUs
  }
  int rc = vmb_create(hvf_u64(f[1], f[2]), hvf_u64(f[3], f[4]), (u32)f[7]);
  if (rc != 0) {
    return (Term)(u32)rc;
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
  if (vmb_map(hvf_ram, hvf_ram_base, hvf_ram_size, VMB_R | VMB_W | VMB_X) != 0) {
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

// Inflates n bytes at src into dst (room bytes): a gzip file (bits 31) or a
// raw deflate stream (bits -12, as qcow2's compressed clusters). The output
// size, or -1 (room filling up is no error for a raw stream).
static int64_t hvf_inflate(const uint8_t* src, uint64_t n, uint8_t* dst, uint64_t room, int bits) {
  if (!hvf_z.lib) {
#ifdef __APPLE__
    hvf_z.lib = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW);
#else
    hvf_z.lib = dlopen("libz.so.1", RTLD_NOW);
#endif
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
  if (!hvf_z.init2 || hvf_z.init2(&z, bits, "1.2.12", (int)sizeof z) != HVF_Z_OK) {
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
  return r == HVF_Z_STREAM_END || (bits < 0 && out > 0) ? (int64_t)out : -1;
}

static int64_t hvf_gunzip(uint8_t* src, uint64_t n, uint8_t* dst, uint64_t room) {
  // windowBits 15 + 16: a gzip wrapper
  return hvf_inflate(src, n, dst, room, 31);
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

// This program's arguments, NUL-separated, as the Bend side gave them
// (Hvf.set_args): for snapshots and the restart after a reset, with no need
// of /proc (absent in some chroots and containers).
static char*    hvf_argbuf;
static uint64_t hvf_arglen;

// Hvf.set_args(bytes) -> U32: the arguments, each followed by a 0 byte.
Term hvf_set_args_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* b = io_cbuf(e, f[0], &n, CID(Con));
  free(hvf_argbuf);
  hvf_argbuf = b;
  hvf_arglen = b ? n : 0;
  return (Term)0;
}

// Hvf.reexec() -> U32: restarts this program with its original arguments
// (PSCI SYSTEM_RESET: a fresh VM is the simplest correct reset).
Term hvf_reexec_run(Env e, Term* f, IoWork* w) {
  char     path[4096] = "";
  uint32_t size       = sizeof path;
  hvf_tty_restore();
  fflush(stdout);
  char* argv[1024];
  int   argc = 0;
  for (uint64_t at = 0; at < hvf_arglen && argc < 1023; at += strlen(hvf_argbuf + at) + 1) {
    argv[argc++] = hvf_argbuf + at;
  }
  argv[argc] = NULL;
#ifdef __APPLE__
  if (_NSGetExecutablePath(path, &size) != 0) {
    path[0] = 0;
  }
#else
  (void)size;
  ssize_t pl = readlink("/proc/self/exe", path, sizeof path - 1);
  path[pl > 0 ? pl : 0] = 0; // readlink does not end the string
#endif
  if (!path[0] && argc > 0) {
    // no executable path from the system: argv[0], from this cwd
    snprintf(path, sizeof path, "%s", argv[0]);
  }
  if (argc > 0 && path[0]) {
    execv(path, argv);
  }
  fprintf(stderr, "bend-vmm: cannot re-execute %s: %s\n", path, strerror(errno));
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
  char    b[16];
  while (read(c->pipe[0], b, sizeof b) > 0) {
  }
  if (atomic_load(&c->state) != 2) {
    // a stale wakeup from an earlier answer taken by spinning
    return io_wait_on(w, c->pipe[0], POLLIN, 0, hvf_vcpu_more);
  }
  atomic_store(&c->parked, 0);
  atomic_store(&c->state, 0);
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
  c->op = (int)(u32)f[1];
  c->a  = hvf_u64(f[2], f[3]);
  c->b  = hvf_u64(f[4], f[5]);
  atomic_store(&c->state, 1);
  if (atomic_load(&c->sleeping)) {
    pthread_mutex_lock(&c->mu);
    pthread_cond_signal(&c->cv);
    pthread_mutex_unlock(&c->mu);
  }
  // spin for a quick answer; else sleep on the pipe
  uint64_t until = hvf_ns() + HVF_SPIN_NS;
  while (hvf_ns() < until) {
    if (atomic_load(&c->state) == 2) {
      atomic_store(&c->state, 0);
      return hvf_words(e, c->out, c->nout);
    }
    hvf_relax();
  }
  atomic_store(&c->parked, 1);
  if (atomic_load(&c->state) == 2) {
    atomic_store(&c->parked, 0);
    atomic_store(&c->state, 0);
    return hvf_words(e, c->out, c->nout);
  }
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
  int r = vmb_spi((u32)f[0], (u32)f[1] != 0);
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] irq %u -> %u (%d)\n", (u32)f[0], (u32)f[1], r);
  }
  return (Term)(r == 0 ? 0 : HVF_ERR);
}

// Hvf.kick(cpu) -> U32: forces a running vCPU out of the guest.
Term hvf_kick_run(Env e, Term* f, IoWork* w) {
  u32 cpu = (u32)f[0];
  if (cpu >= HVF_MAX_CPUS || !hvf_cpus[cpu].live) {
    return (Term)HVF_ERR;
  }
  return (Term)(vmb_kick(&hvf_cpus[cpu]) == 0 ? 0 : HVF_ERR);
}

// Console and disks
// =================

// Console output is buffered and written by a flusher thread within a
// millisecond, so a guest printing byte by byte costs no syscall per byte.
static pthread_mutex_t hvf_out_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  hvf_out_cv = PTHREAD_COND_INITIALIZER;
#define HVF_OUT_MAX ((size_t)16 << 20)
static char*           hvf_obuf;
static size_t          hvf_on, hvf_ocap;
static int             hvf_out_started;

// Serializes writers, so the flush at exit waits for one in flight.
static pthread_mutex_t hvf_out_wmu = PTHREAD_MUTEX_INITIALIZER;

static void hvf_out_flush(void) {
  pthread_mutex_lock(&hvf_out_wmu);
  pthread_mutex_lock(&hvf_out_mu);
  char*  buf = hvf_obuf;
  size_t n   = hvf_on;
  hvf_obuf = NULL;
  hvf_on = hvf_ocap = 0;
  pthread_mutex_unlock(&hvf_out_mu);
  // stdout may be non-blocking (the runtime's IO loop) and a slow pipe
  // reader fills it: wait until it drains rather than drop output.
  for (size_t at = 0; at < n;) {
    ssize_t k = write(1, buf + at, n - at);
    if (k < 0 && (errno == EAGAIN || errno == EINTR)) {
      struct pollfd p = {1, POLLOUT, 0};
      poll(&p, 1, 100);
      continue;
    }
    if (k <= 0) {
      break;
    }
    at += (size_t)k;
  }
  free(buf);
  pthread_mutex_unlock(&hvf_out_wmu);
}

static void* hvf_out_thread(void* arg) {
  for (;;) {
    pthread_mutex_lock(&hvf_out_mu);
    while (hvf_on == 0) {
      pthread_cond_wait(&hvf_out_cv, &hvf_out_mu);
    }
    pthread_mutex_unlock(&hvf_out_mu);
    usleep(1000);
    hvf_out_flush();
  }
  return NULL;
}

// Hvf.out(bytes) -> U32: queues raw bytes for stdout (guest console output
// is bytes, not text: IO.write would re-encode them as UTF-8).
Term hvf_out_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* buf = io_cbuf(e, f[0], &n, CID(Con));
  if (buf == NULL) {
    return (Term)HVF_ERR;
  }
  pthread_mutex_lock(&hvf_out_mu);
  if (!hvf_out_started) {
    pthread_t t;
    hvf_out_started = 1;
    pthread_create(&t, NULL, hvf_out_thread, NULL);
    atexit(hvf_out_flush);
  }
  // nobody draining stdout (a stalled pipe) must not grow the VMM without
  // bound: past 16 MiB waiting, console output is dropped
  if (hvf_on + n > HVF_OUT_MAX) {
    n = 0;
  }
  if (hvf_on + n > hvf_ocap) {
    hvf_ocap = (hvf_on + n) * 2 + 4096;
    hvf_obuf = io_mem(realloc(hvf_obuf, hvf_ocap));
  }
  if (n) {
    memcpy(hvf_obuf + hvf_on, buf, n);
    hvf_on += n;
  }
  pthread_cond_signal(&hvf_out_cv);
  pthread_mutex_unlock(&hvf_out_mu);
  free(buf);
  return (Term)0;
}

// Hvf.log_gate() -> U32: whether a VMM message may go to stderr, so a guest
// that traps in a loop (an unmapped access, an unknown register) cannot
// flood it: up to 200 at once, then 20 a second. 0 drops the message;
// otherwise 1 + the messages dropped since the last one printed.
Term hvf_log_gate_run(Env e, Term* f, IoWork* w) {
  static double   tokens = 200, last;
  static uint64_t dropped;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double now = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
  tokens     = last == 0 ? tokens : tokens + (now - last) * 20;
  tokens     = tokens > 200 ? 200 : tokens;
  last       = now;
  if (tokens < 1) {
    dropped++;
    return (Term)0;
  }
  tokens -= 1;
  uint64_t d = dropped;
  dropped    = 0;
  return (Term)(u32)(d + 1 > 0xFFFFFFFFull ? 0xFFFFFFFFull : d + 1);
}

// Hvf.out_flush() -> U32: writes the queued console output now, so a
// message on stderr after it keeps its place in a merged log.
Term hvf_out_flush_run(Env e, Term* f, IoWork* w) {
  hvf_out_flush();
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
// guest) and is restored at exit.
static struct termios hvf_tty;
static int            hvf_raw;

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

// Signals. SIGTERM, SIGINT and SIGHUP go to one thread of their own (every
// other thread blocks them from the start, so no vCPU run and no poll sees
// them), which hands their number to Hvf.signal_wait through a pipe. Until
// Bend waits on them they end the VMM as before, with the terminal restored.
static int        hvf_sig_pipe[2] = {-1, -1};
static atomic_int hvf_sig_armed;
static sigset_t   hvf_sig_set;

static void* hvf_sig_thread(void* arg) {
  (void)arg;
  for (;;) {
    int sig;
    if (sigwait(&hvf_sig_set, &sig) != 0) {
      continue;
    }
    if (!atomic_load(&hvf_sig_armed)) {
      hvf_tty_restore();
      signal(sig, SIG_DFL);
      sigset_t one;
      sigemptyset(&one);
      sigaddset(&one, sig);
      pthread_sigmask(SIG_UNBLOCK, &one, NULL);
      raise(sig);
    }
    char c = (char)sig;
    (void)!write(hvf_sig_pipe[1], &c, 1);
  }
  return NULL;
}

__attribute__((constructor)) static void hvf_sig_init(void) {
  sigemptyset(&hvf_sig_set);
  sigaddset(&hvf_sig_set, SIGTERM);
  sigaddset(&hvf_sig_set, SIGINT);
  sigaddset(&hvf_sig_set, SIGHUP);
  if (pipe(hvf_sig_pipe) != 0) {
    return;
  }
  for (int i = 0; i < 2; i++) {
    fcntl(hvf_sig_pipe[i], F_SETFD, FD_CLOEXEC);
    fcntl(hvf_sig_pipe[i], F_SETFL, fcntl(hvf_sig_pipe[i], F_GETFL) | O_NONBLOCK);
  }
  pthread_t t;
  pthread_sigmask(SIG_BLOCK, &hvf_sig_set, NULL);
  if (pthread_create(&t, NULL, hvf_sig_thread, NULL) == 0) {
    pthread_detach(t);
  } else {
    pthread_sigmask(SIG_UNBLOCK, &hvf_sig_set, NULL);
  }
}

static Term hvf_signal_more(Env e, IoWork* w) {
  char c;
  if (read(hvf_sig_pipe[0], &c, 1) != 1) {
    return io_wait_on(w, hvf_sig_pipe[0], POLLIN, 0, hvf_signal_more);
  }
  return (Term)(u32)(unsigned char)c;
}

// Hvf.signal_wait() -> U32: from the first call on, SIGTERM, SIGINT and
// SIGHUP no longer end the VMM; parks until one comes and answers its
// number (0xFFFFFFFF when signals could not be set up).
Term hvf_signal_wait_run(Env e, Term* f, IoWork* w) {
  if (hvf_sig_pipe[0] < 0) {
    return (Term)HVF_ERR;
  }
  atomic_store(&hvf_sig_armed, 1);
  return io_wait_on(w, hvf_sig_pipe[0], POLLIN, 0, hvf_signal_more);
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
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] stdin %zd bytes\n", k);
  }
  return io_list(e, buf, (u64)k);
}

// Hvf.stdin_tty() -> U32: 1 when stdin is a terminal (now raw: every key,
// Ctrl-C included, goes to the guest, and src/dev/escape.bend reads the
// Ctrl-A keys), else 0.
Term hvf_stdin_tty_run(Env e, Term* f, IoWork* w) {
  hvf_tty_raw();
  return (Term)(u32)hvf_raw;
}

// Hvf.stdin_wait(max) -> List<U32>: parks until stdin has bytes and answers
// up to max of them, as typed; [] at end of input (or on an error).
Term hvf_stdin_wait_run(Env e, Term* f, IoWork* w) {
  hvf_tty_raw();
  fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
  w->made = (u32)f[0] < 256 ? (intptr_t)(u32)f[0] : 256;
  return io_wait_on(w, 0, POLLIN, 0, hvf_stdin_more);
}

#define HVF_MAX_DISKS 8
static int hvf_disks[HVF_MAX_DISKS];
static int hvf_ndisks;

// Opens a disk image for the guest, read-write (read-only when ro, or when
// the file allows no more), and locks it the way its use needs: a writer
// alone, readers together, so a second bend-vmm cannot write an image this
// one reads or writes (two writers corrupt a qcow2 image at once). Its index,
// or 0xFFFFFFFF.
static Term hvf_disk_open_as(Env e, Term path_t, int kind) {
  int   ro = kind != 0;
  u64   n;
  char* path = io_cstr(e, path_t, &n);
  int   fd   = -1;
  if (hvf_ndisks < HVF_MAX_DISKS) {
    fd = ro ? -1 : open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0 && (ro || errno == EACCES || errno == EROFS || errno == EPERM)) {
      fd = open(path, O_RDONLY | O_CLOEXEC); // a read-only file (a qcow2 backing image)
      ro = 1;
    }
  }
  // a backing file named inside an image is a regular file, never a device
  // or a FIFO
  struct stat st;
  if (fd >= 0 && kind == 2 && (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))) {
    fprintf(stderr, "bend-vmm: %s: a backing file must be a regular file\n", path);
    close(fd);
    fd = -1;
  }
  // a file system without locks (some network ones) answers ENOTSUP: go on
  if (fd >= 0 && flock(fd, (ro ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 && errno == EWOULDBLOCK) {
    fprintf(stderr, "bend-vmm: %s is in use by another process\n", path);
    close(fd);
    fd = -1;
  }
  free(path);
  if (fd < 0) {
    return (Term)HVF_ERR;
  }
  hvf_disks[hvf_ndisks] = fd;
  return (Term)(u32)hvf_ndisks++;
}

// Hvf.disk_open(path) -> U32: a disk image the guest may write.
Term hvf_disk_open_run(Env e, Term* f, IoWork* w) {
  return hvf_disk_open_as(e, f[0], 0);
}

// Hvf.disk_open_ro(path) -> U32: a disk image only read (a :ro disk).
Term hvf_disk_open_ro_run(Env e, Term* f, IoWork* w) {
  return hvf_disk_open_as(e, f[0], 1);
}

// Hvf.disk_open_backing(path) -> U32: a qcow2 image's backing file, read
// only, and a regular file.
Term hvf_disk_open_backing_run(Env e, Term* f, IoWork* w) {
  return hvf_disk_open_as(e, f[0], 2);
}

// A failed host read or write of each image since the guest's device last
// asked (Hvf.disk_status): virtio-blk answers that request with IOERR, so a
// full host disk or an I/O error never passes for success.
static int hvf_disk_err[HVF_MAX_DISKS];

static Term hvf_disk_mark(Term id, Term r) {
  if (r == (Term)HVF_ERR && (u32)id < HVF_MAX_DISKS) {
    hvf_disk_err[(u32)id] = 1;
  }
  return r;
}

// Hvf.disk_status(disk) -> U32: 1 when an operation on the image failed
// since the last call, else 0; clears it.
Term hvf_disk_status_run(Env e, Term* f, IoWork* w) {
  u32 i = (u32)f[0];
  if (i >= HVF_MAX_DISKS) {
    return (Term)0;
  }
  int r          = hvf_disk_err[i];
  hvf_disk_err[i] = 0;
  return (Term)(u32)r;
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

// Hvf.disk_flush(disk) -> U32: the image's writes on stable storage; 0, or
// 0xFFFFFFFF. macOS's fsync only hands them to the drive, which may keep
// them in its cache across a power loss: F_FULLFSYNC empties that too (and
// fsync stays for file systems that refuse it).
Term hvf_disk_flush_run(Env e, Term* f, IoWork* w) {
  int fd = hvf_disk(f[0]);
#ifdef F_FULLFSYNC
  if (fd >= 0 && fcntl(fd, F_FULLFSYNC) == 0) {
    return (Term)0;
  }
#endif
  return hvf_disk_mark(f[0], (Term)(fd >= 0 && fsync(fd) == 0 ? 0 : HVF_ERR));
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
  hvf_disk_mark(f[0], k < 0 ? (Term)HVF_ERR : 0);
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
  return hvf_disk_mark(f[0], (Term)(k == (ssize_t)n ? 0 : HVF_ERR));
}

// Pieces of guest memory as the effects below take them: each an address
// (8 bytes) and a length (4), little-endian. Fills hva/len with at most max
// of them; the count, or -1 when one leaves RAM or the list is malformed.
static int hvf_iovs(const char* b, u64 nb, uint8_t** hva, u64* len, int max) {
  if (b == NULL || nb % 12 != 0 || nb / 12 > (u64)max) {
    return -1;
  }
  int n = (int)(nb / 12);
  for (int i = 0; i < n; i++) {
    const uint8_t* p   = (const uint8_t*)b + 12 * i;
    uint64_t       gpa = 0;
    uint32_t       l   = 0;
    for (int j = 0; j < 8; j++) {
      gpa |= (uint64_t)p[j] << (8 * j);
    }
    for (int j = 0; j < 4; j++) {
      l |= (uint32_t)p[8 + j] << (8 * j);
    }
    len[i] = l;
    hva[i] = hvf_ptr(gpa, l);
    if (hva[i] == NULL) {
      return -1;
    }
  }
  return n;
}
#define HVF_MAX_IOVS 1024

// Moves bytes between fd at off and the pieces, in order: out writes them to
// fd, else reads fd into them, stopping at the end of the file (fill: zeros
// the rest). The count moved; -1 (errno set) when nothing could be.
static int64_t hvf_iov_io(int fd, int out, off_t off, uint8_t** hva, u64* len, int n, int fill) {
  int64_t done = 0, skip = 0;
  int     eof  = 0;
  // several pieces (a request of many segments) go in one call; what it
  // leaves (a short read at the end of the file, a short write) goes piece
  // by piece below
  if (n > 1) {
    struct iovec v[HVF_MAX_IOVS];
    u64          total = 0;
    for (int i = 0; i < n; i++) {
      v[i].iov_base = hva[i];
      v[i].iov_len  = len[i];
      total += len[i];
    }
    ssize_t k;
    do {
      k = out ? pwritev(fd, v, n, off) : preadv(fd, v, n, off);
    } while (k < 0 && errno == EINTR);
    if (k >= 0 && (u64)k == total) {
      return k;
    }
    skip = k > 0 ? k : 0;
  }
  for (int i = 0; i < n; i++) {
    u64 got = 0;
    if (skip > 0) {
      got = (u64)skip < len[i] ? (u64)skip : len[i];
      skip -= (int64_t)got;
      done += (int64_t)got;
    }
    while (!eof && got < len[i]) {
      ssize_t k = out ? pwrite(fd, hva[i] + got, len[i] - got, off + (off_t)done)
                      : pread(fd, hva[i] + got, len[i] - got, off + (off_t)done);
      if (k < 0 && errno == EINTR) {
        continue;
      }
      if (k < 0 && done == 0) {
        return -1;
      }
      if (k <= 0) {
        eof = 1;
        break;
      }
      got += (u64)k;
      done += k;
    }
    if (fill && got < len[i]) {
      memset(hva[i] + got, 0, len[i] - got);
    }
  }
  return done;
}

// Hvf.disk_copy(disk, dir, off_hi, off_lo, iovs) -> U32: moves bytes between
// disk image `disk` from the offset and the pieces of guest memory iovs, none
// of them through Bend: dir 0 reads the disk into RAM (zeros past the
// image's end), 1 writes RAM to the disk. 0, or 0xFFFFFFFF (a piece leaves
// RAM, or an IO error).
Term hvf_disk_copy_run(Env e, Term* f, IoWork* w) {
  static uint8_t* hva[HVF_MAX_IOVS];
  static u64      len[HVF_MAX_IOVS];
  int             fd  = hvf_disk(f[0]);
  int             out = (u32)f[1] != 0;
  off_t           off = (off_t)hvf_u64(f[2], f[3]);
  u64             nb;
  char*           b = io_cbuf(e, f[4], &nb, CID(Con));
  int             n = hvf_iovs(b, nb, hva, len, HVF_MAX_IOVS);
  free(b);
  if (fd < 0 || n < 0) {
    return hvf_disk_mark(f[0], (Term)HVF_ERR);
  }
  u64 want = 0;
  for (int i = 0; i < n; i++) {
    want += len[i];
  }
  int64_t k = hvf_iov_io(fd, out, off, hva, len, n, !out);
  return hvf_disk_mark(f[0], (Term)(k < 0 || (out && (u64)k < want) ? HVF_ERR : 0));
}

// Disk images by layout (src/disk)
// ================================

// Hvf.zero_ram(iovs) -> U32: zeros over the pieces of guest memory.
Term hvf_zero_ram_run(Env e, Term* f, IoWork* w) {
  static uint8_t* hva[HVF_MAX_IOVS];
  static u64      len[HVF_MAX_IOVS];
  u64             nb;
  char*           b = io_cbuf(e, f[0], &nb, CID(Con));
  int             n = hvf_iovs(b, nb, hva, len, HVF_MAX_IOVS);
  free(b);
  for (int i = 0; i < n; i++) {
    memset(hva[i], 0, len[i]);
  }
  return (Term)(n < 0 ? HVF_ERR : 0);
}

// Hvf.disk_alloc(disk, len) -> List<U32>: grows the image by len zero bytes
// from the first multiple of len at or past its end: [hi, lo] of that start,
// or [] when it cannot.
Term hvf_disk_alloc_run(Env e, Term* f, IoWork* w) {
  int         fd  = hvf_disk(f[0]);
  u64         len = (u32)f[1];
  struct stat st;
  if (fd < 0 || len == 0 || fstat(fd, &st) != 0) {
    hvf_disk_mark(f[0], (Term)HVF_ERR);
    return term_pak(CID(Nil), 0);
  }
  uint64_t at = ((uint64_t)st.st_size + len - 1) / len * len;
  if (ftruncate(fd, (off_t)(at + len)) != 0) {
    hvf_disk_mark(f[0], (Term)HVF_ERR);
    return term_pak(CID(Nil), 0);
  }
  uint32_t ws[2] = {(uint32_t)(at >> 32), (uint32_t)at};
  return hvf_words(e, ws, 2);
}

// Hvf.disk_xcopy(src, soff_hi, soff_lo, dst, doff_hi, doff_lo, len) -> U32:
// copies len bytes between images (zeros past src's end); 0, or 0xFFFFFFFF.
Term hvf_disk_xcopy_run(Env e, Term* f, IoWork* w) {
  int      sfd = hvf_disk(f[0]), dfd = hvf_disk(f[3]);
  uint64_t so = hvf_u64(f[1], f[2]), dof = hvf_u64(f[4], f[5]);
  u64      n   = (u32)f[6];
  if (sfd < 0 || dfd < 0) {
    return hvf_disk_mark(f[3], (Term)HVF_ERR);
  }
  uint8_t* buf = io_mem(calloc(1, n ? n : 1));
  ssize_t  k   = pread(sfd, buf, n, (off_t)so);
  int      ok  = k >= 0 && pwrite(dfd, buf, n, (off_t)dof) == (ssize_t)n;
  free(buf);
  return hvf_disk_mark(f[3], (Term)(ok ? 0 : HVF_ERR));
}

// The raw-deflate stream of clen bytes at off in image fd, inflated into a
// new buffer of room bytes (zeros past its end); NULL on an error.
static uint8_t* hvf_inflate_at(int fd, uint64_t off, u64 clen, u64 room) {
  uint8_t* in  = io_mem(malloc(clen ? clen : 1));
  uint8_t* out = io_mem(calloc(1, room ? room : 1));
  ssize_t  k   = fd >= 0 ? pread(fd, in, clen, (off_t)off) : -1;
  int64_t  m   = k > 0 ? hvf_inflate(in, (uint64_t)k, out, room, -12) : -1;
  free(in);
  if (m < 0) {
    free(out);
    return NULL;
  }
  return out;
}

// Hvf.inflate_ram(disk, off_hi, off_lo, clen, skip, iovs) -> U32: inflates
// a compressed cluster and copies its bytes from skip on over the pieces of
// guest memory; 0, or 0xFFFFFFFF.
Term hvf_inflate_ram_run(Env e, Term* f, IoWork* w) {
  static uint8_t* hva[HVF_MAX_IOVS];
  static u64      len[HVF_MAX_IOVS];
  u64             nb;
  char*           b = io_cbuf(e, f[5], &nb, CID(Con));
  int             n = hvf_iovs(b, nb, hva, len, HVF_MAX_IOVS);
  free(b);
  u64 skip = (u32)f[4], total = 0;
  for (int i = 0; i < n; i++) {
    total += len[i];
  }
  uint8_t* c = n < 0 ? NULL : hvf_inflate_at(hvf_disk(f[0]), hvf_u64(f[1], f[2]), (u32)f[3], skip + total);
  if (!c) {
    return hvf_disk_mark(f[0], (Term)HVF_ERR);
  }
  u64 at = 0;
  for (int i = 0; i < n; at += len[i], i++) {
    memcpy(hva[i], c + skip + at, len[i]);
  }
  free(c);
  return (Term)0;
}

// Hvf.inflate_disk(disk, off_hi, off_lo, clen, dst, doff_hi, doff_lo, skip,
// len) -> U32: inflates a compressed cluster into image dst: its len bytes
// from skip on, at doff.
Term hvf_inflate_disk_run(Env e, Term* f, IoWork* w) {
  u64      skip = (u32)f[7], n = (u32)f[8];
  int      dfd  = hvf_disk(f[4]);
  uint8_t* c    = hvf_inflate_at(hvf_disk(f[0]), hvf_u64(f[1], f[2]), (u32)f[3], skip + n);
  int      ok   = c && dfd >= 0 && pwrite(dfd, c + skip, n, (off_t)hvf_u64(f[5], f[6])) == (ssize_t)n;
  free(c);
  return hvf_disk_mark(f[4], (Term)(ok ? 0 : HVF_ERR));
}

// Network (the host end of src/net/nat.bend)
// ============================================
//
// TCP connections are keyed by the NAT's connection number, UDP flows by a
// flow number of their own (one connected socket per guest port, address
// and port). Addresses here are the host's: the Bend side maps the guest's
// view to them and back (src/net/addr.bend).
//
// No effect here waits in its run function: the event loop serves every
// vCPU. Guest data a TCP socket does not take at once waits in the socket's
// pending buffer, sent by a flusher (Hvf.tcp_flush) as the socket turns
// writable; a shutdown or close the NAT asks for meanwhile happens once the
// data is out.

#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/resource.h>

#define HVF_MAX_SOCKS 1024

#ifdef MSG_NOSIGNAL
#define HVF_NOSIG MSG_NOSIGNAL
#else
#define HVF_NOSIG 0 // macOS: SO_NOSIGPIPE on the socket
#endif

// Pending guest data per TCP connection: past HVF_WCAP the NAT stops taking
// the guest's data (TcpBlocked) until it drains to half; past HVF_WHARD (the
// guest sent on regardless), or with no byte taken for HVF_WSTALL ns, the
// connection is reset. The flusher looks again every HVF_WTICK ns.
#define HVF_WCAP   (4ull << 20)
#define HVF_WHARD  (32ull << 20)
#define HVF_WSTALL (60ull * 1000000000ull)
#define HVF_WTICK  (100ull * 1000000ull)

// Pending guest data over all connections: past HVF_WBUDGET the flusher of
// each connection that holds some tells the NAT TcpBlocked; a send that
// would take the total past HVF_WALL resets its connection instead, so the
// pending bytes never pass HVF_WALL.
#define HVF_WBUDGET (64ull << 20)
#define HVF_WALL    (96ull << 20)

// A close (V.TcpClose) with data still pending sends it for at most
// HVF_WLINGER ns, and at most HVF_WLINGER_MAX connections do so at once:
// past either the socket is reset. A guest RST (V.TcpAbort) resets it at
// once.
#define HVF_WLINGER     (30ull * 1000000000ull)
#define HVF_WLINGER_MAX 64

// UDP flows: at most HVF_UDP_MAX (the least recently used goes first), each
// closed after HVF_UDP_IDLE ns without a datagram either way.
#define HVF_UDP_MAX  128
#define HVF_UDP_IDLE (60ull * 1000000000ull)

typedef struct {
  int      used;
  uint32_t key;     // conn id (TCP, vsock) or flow number (UDP)
  int      udp;
  int      fd;
  int      parked;  // how many effects wait on this socket in the event loop
  int      closing; // closed while parked: the last parked effect closes fd
  // TCP data held for the guest (Hvf.tcp_fill): rlen bytes, copied into
  // guest memory by Hvf.net_copy (perhaps more than once) until
  // Hvf.tcp_release empties the hold and writes to wake[1]
  uint8_t* rbuf;
  uint32_t rlen;
  int      wake[2];
  // guest data not yet sent: wbuf[woff..wlen) of wsize; wlast: when the
  // socket last took a byte
  uint8_t* wbuf;
  u64      woff, wlen, wsize, wlast;
  uint8_t  flushing; // a flusher runs (Hvf.tcp_flush)
  uint8_t  blocked;  // the NAT was told TcpBlocked
  uint8_t  wshut;    // shut down once the data is out
  uint8_t  wclose;   // closed once the data is out
  uint8_t  wreset;   // over HVF_WHARD or HVF_WALL: the flusher resets it
  u64      wdead;    // wclose: the socket is reset at this time
  int      fds;      // descriptors counted for it (hvf_fd_used)
  // UDP: the guest's port, the host's address and port, the last datagram
  uint32_t uport, uip, urport;
  u64      ulast;
} HvfSock;

static HvfSock  hvf_socks[HVF_MAX_SOCKS];
static uint32_t hvf_dns;

// The host's resolver (src/net/addr.bend reads /etc/resolv.conf), kept here
// for the Bend side's address mapping (Hvf.set_dns, Hvf.dns).
static uint32_t hvf_dns = 0x01010101u;

// Hvf.set_dns(ip) -> U32
Term hvf_set_dns_run(Env e, Term* f, IoWork* w) {
  hvf_dns = (u32)f[0];
  return (Term)0;
}

// Hvf.dns() -> U32
Term hvf_dns_run(Env e, Term* f, IoWork* w) {
  return (Term)hvf_dns;
}

// Descriptors. Bend's runtime waits on parked effects with select(). On
// Linux it sizes its fd sets by the top descriptor, so any descriptor is
// fine and the soft limit is raised to min(hard, HVF_FD_TOP) (never
// lowered). On macOS select() fails with EINVAL for nfds > FD_SETSIZE
// (1024) and the runtime then aborts ("the poller failed"), so the soft
// limit is min(hard, FD_SETSIZE), raised or lowered to it, and the kernel
// never hands out a larger descriptor. Either way the socket table (NAT
// connections and flows, vsock) holds at most hvf_fd_room descriptors: the
// rest (HVF_FD_SPARE, or half of a small limit) stays for disks, the control
// socket, shares, pipes and the runtime. A new guest flow past hvf_fd_room
// is refused (a RST, or a dropped datagram) before socket() could fail with
// EMFILE. A NAT connection counts 3 (its socket and the wake pipe
// Hvf.tcp_fill may make), anything else 1.
#ifdef __APPLE__
#define HVF_FD_TOP 1024 // FD_SETSIZE
#else
#define HVF_FD_TOP 65536
#endif
#define HVF_FD_SPARE 128

static int hvf_fd_room = 1024 - HVF_FD_SPARE;
static int hvf_fd_used;

static void __attribute__((constructor)) hvf_nofile(void) {
  struct rlimit r;
  rlim_t        lim = 1024;
  if (getrlimit(RLIMIT_NOFILE, &r) == 0) {
    rlim_t want = r.rlim_max != RLIM_INFINITY && r.rlim_max < HVF_FD_TOP ? r.rlim_max : HVF_FD_TOP;
#ifdef __APPLE__
    int set = r.rlim_cur != want;
#else
    int set = r.rlim_cur == RLIM_INFINITY ? 0 : r.rlim_cur < want;
#endif
    if (set) {
      r.rlim_cur = want;
      if (setrlimit(RLIMIT_NOFILE, &r) != 0) {
        getrlimit(RLIMIT_NOFILE, &r);
      }
    }
    // The budget counts at most HVF_FD_TOP, even when Linux's soft limit is
    // higher (the table, HVF_MAX_SOCKS, bounds it below that anyway).
    lim = r.rlim_cur != RLIM_INFINITY && r.rlim_cur < HVF_FD_TOP ? r.rlim_cur : HVF_FD_TOP;
  }
  hvf_fd_room = (int)lim - ((int)lim / 2 < HVF_FD_SPARE ? (int)lim / 2 : HVF_FD_SPARE);
}

// Whether the socket table may take n more descriptors.
static int hvf_fd_has(int n) {
  return hvf_fd_used + n <= hvf_fd_room;
}

static HvfSock* hvf_sock(uint32_t key, int udp) {
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    if (hvf_socks[i].used && !hvf_socks[i].closing && hvf_socks[i].key == key && hvf_socks[i].udp == udp) {
      return &hvf_socks[i];
    }
  }
  return NULL;
}

// Files socket fd under key, counting fds descriptors for it (hvf_fd_has);
// NULL when the table is full.
static HvfSock* hvf_sock_new(uint32_t key, int udp, int fd, int fds) {
  if (!hvf_fd_has(fds)) {
    return NULL;
  }
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    if (!hvf_socks[i].used) {
      hvf_socks[i] = (HvfSock){.used = 1, .key = key, .udp = udp, .fd = fd, .wake = {-1, -1}, .fds = fds};
      hvf_fd_used += fds;
      return &hvf_socks[i];
    }
  }
  return NULL;
}

static u64 hvf_wtotal; // pending guest data over all connections

// The bytes the socket has not taken yet.
static u64 hvf_wpend(HvfSock* k) {
  return k->wlen - k->woff;
}

static void hvf_wdrop(HvfSock* k) {
  hvf_wtotal -= hvf_wpend(k);
  free(k->wbuf);
  k->wbuf = NULL;
  k->woff = k->wlen = k->wsize = 0;
}

// Closing a socket that an effect is parked on would pull the fd out from
// under the event loop's poll. Instead it is shut down, which wakes the
// parked effects, and the last of them closes it (hvf_sock_woke).
static void hvf_sock_release(HvfSock* k) {
  close(k->fd);
  if (k->wake[0] >= 0) {
    close(k->wake[0]);
    close(k->wake[1]);
  }
  free(k->rbuf);
  hvf_wdrop(k);
  hvf_fd_used -= k->fds;
  *k = (HvfSock){.wake = {-1, -1}};
}

static void hvf_sock_free(HvfSock* k) {
  if (k->parked) {
    shutdown(k->fd, SHUT_RDWR);
    if (k->wake[1] >= 0) {
      (void)!write(k->wake[1], "x", 1); // an effect may wait on wake[0]
    }
    k->closing = 1;
    k->key     = 0xffffffffu; // no longer found by key
    return;
  }
  hvf_sock_release(k);
}

// A parked effect woke: if its socket was closed meanwhile, answer 1 (the
// effect then reports EOF), the last one to wake finishing the close.
static int hvf_sock_woke(HvfSock* k) {
  k->parked--;
  if (k->closing) {
    if (k->parked == 0) {
      hvf_sock_release(k);
    }
    return 1;
  }
  return 0;
}

// The table entry a parked effect stored by index (w->made).
static HvfSock* hvf_sock_at(IoWork* w) {
  return &hvf_socks[w->made];
}

static struct sockaddr_in hvf_addr(uint32_t ip, uint32_t port) {
  struct sockaddr_in a = {0};
  a.sin_family      = AF_INET;
  a.sin_port        = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(ip);
  return a;
}

// Hvf.tcp_connect(conn, ip, port) -> U32: starts a non-blocking connect; 0,
// or an errno. Hvf.tcp_wait answers when it completes.
Term hvf_tcp_connect_run(Env e, Term* f, IoWork* w) {
  if (!hvf_fd_has(3)) {
    return (Term)(u32)EMFILE;
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd >= 0) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  if (fd < 0) {
    return (Term)(u32)errno;
  }
  fcntl(fd, F_SETFL, O_NONBLOCK);
  int one = 1;
#ifdef SO_NOSIGPIPE
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a = hvf_addr((u32)f[1], (u32)f[2]);
  if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0 && errno != EINPROGRESS) {
    int err = errno;
    close(fd);
    return (Term)(u32)err;
  }
  if (!hvf_sock_new((u32)f[0], 0, fd, 3)) {
    close(fd);
    return (Term)(u32)EMFILE;
  }
  return (Term)0;
}

static Term hvf_tcp_wait_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  if (hvf_sock_woke(k)) {
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
  w->made = (intptr_t)(k - hvf_socks);
  k->parked++;
  return io_wait_on(w, k->fd, POLLOUT, 0, hvf_tcp_wait_more);
}

static Term hvf_tcp_recv_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  if (hvf_sock_woke(k)) {
    return term_pak(CID(Nil), 0);
  }
  char    buf[16384];
  ssize_t n = recv(k->fd, buf, sizeof buf, 0);
  if (n < 0 && errno == EAGAIN) {
    k->parked++;
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
  w->made = (intptr_t)(k - hvf_socks);
  k->parked++;
  return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_recv_more);
}

// The most the host holds for a TCP connection: four of the largest
// segments to the guest (65495 bytes: its IPv4 packet, 20 + 20 header bytes,
// stays within 65535), so the NAT sends the next ones while the guest
// acknowledges the first (one segment at a time held the download to about
// 360 MB/s on an M2 Pro; four reach about 650).
#define HVF_RBUF (4 * 65495)

static Term hvf_tcp_fill_read(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  if (hvf_sock_woke(k)) {
    return (Term)0;
  }
  ssize_t n = recv(k->fd, k->rbuf, HVF_RBUF, 0);
  if (n < 0 && errno == EAGAIN) {
    k->parked++;
    return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_fill_read);
  }
  k->rlen = n > 0 ? (uint32_t)n : 0;
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] tcp %u: holds %u\n", k->key, k->rlen);
  }
  return (Term)k->rlen;
}

static Term hvf_tcp_fill_taken(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  char     b[64];
  while (read(k->wake[0], b, sizeof b) > 0) {
  }
  if (hvf_sock_woke(k)) {
    return (Term)0;
  }
  k->parked++;
  if (k->rlen) {
    return io_wait_on(w, k->wake[0], POLLIN, 0, hvf_tcp_fill_taken);
  }
  return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_fill_read);
}

// Hvf.tcp_fill(conn) -> U32: once the hold is released (Hvf.tcp_release),
// parks until the socket has data and holds up to HVF_RBUF
// bytes of it for the guest: their count; 0 at EOF, on an error, or once the
// connection is closed.
Term hvf_tcp_fill_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (!k) {
    return (Term)0;
  }
  if (!k->rbuf) {
    k->rbuf = io_mem(malloc(HVF_RBUF));
    if (pipe(k->wake) != 0) {
      return (Term)0;
    }
    for (int i = 0; i < 2; i++) {
      fcntl(k->wake[i], F_SETFD, FD_CLOEXEC);
      fcntl(k->wake[i], F_SETFL, O_NONBLOCK);
    }
  }
  w->made = (intptr_t)(k - hvf_socks);
  k->parked++;
  if (k->rlen) {
    return io_wait_on(w, k->wake[0], POLLIN, 0, hvf_tcp_fill_taken);
  }
  return io_wait_on(w, k->fd, POLLIN, 0, hvf_tcp_fill_read);
}

// Hvf.net_copy(conn, off, iovs) -> U32: copies the bytes from offset off of
// what the host holds for TCP connection conn into the pieces of guest
// memory (as Hvf.disk_copy takes them), in order, zeros where they run out.
// The hold stays: the NAT may send those bytes again until the guest
// acknowledges them (Hvf.tcp_release). The count copied.
Term hvf_net_copy_run(Env e, Term* f, IoWork* w) {
  static uint8_t* hva[HVF_MAX_IOVS];
  static u64      len[HVF_MAX_IOVS];
  HvfSock*        k   = hvf_sock((u32)f[0], 0);
  uint32_t        off = (u32)f[1];
  u64             nb;
  char*           b = io_cbuf(e, f[2], &nb, CID(Con));
  int             n = hvf_iovs(b, nb, hva, len, HVF_MAX_IOVS);
  free(b);
  uint32_t have = k && k->rbuf && off < k->rlen ? k->rlen - off : 0, at = 0;
  for (int i = 0; i < n; i++) {
    u64 m = have - at < len[i] ? have - at : len[i];
    if (m) {
      memcpy(hva[i], k->rbuf + off + at, m);
    }
    memset(hva[i] + m, 0, len[i] - m);
    at += (uint32_t)m;
  }
  if (hvf_trace & 2) {
    fprintf(stderr, "[trace] tcp %u: %u bytes from %u of %u to the guest\n", (u32)f[0], at, off, k ? k->rlen : 0);
  }
  return (Term)at;
}

// Hvf.tcp_release(conn) -> U32: the guest acknowledged all the host held for
// the connection: the hold empties and Hvf.tcp_fill reads on.
Term hvf_tcp_release_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (k && k->rbuf) {
    k->rlen = 0;
    (void)!write(k->wake[1], "x", 1);
  }
  return (Term)0;
}

// Staged transmit data: TCP payloads copied out of guest memory when the
// guest hands a segment over (Hvf.stage), sent or freed later on the NAT's
// word (Hvf.tcp_send_staged, Hvf.stage_drop).
#define HVF_STAGES 4096
static struct {
  uint8_t* buf;
  uint32_t len;
} hvf_stages[HVF_STAGES];
static uint32_t hvf_stage_next;

// Hvf.stage(iovs) -> U32: copies the pieces of guest memory, in order, into
// a new slot; the slot, or 0xFFFFFFFF.
Term hvf_stage_run(Env e, Term* f, IoWork* w) {
  static uint8_t* hva[HVF_MAX_IOVS];
  static u64      len[HVF_MAX_IOVS];
  u64             nb;
  char*           b = io_cbuf(e, f[0], &nb, CID(Con));
  int             n = hvf_iovs(b, nb, hva, len, HVF_MAX_IOVS);
  free(b);
  if (n < 0) {
    return (Term)HVF_ERR;
  }
  u64 total = 0;
  for (int i = 0; i < n; i++) {
    total += len[i];
  }
  for (uint32_t tries = 0; tries < HVF_STAGES; tries++) {
    uint32_t s = hvf_stage_next++ % HVF_STAGES;
    if (hvf_stages[s].buf == NULL) {
      uint8_t* p = io_mem(malloc(total ? total : 1));
      u64 at = 0;
      for (int i = 0; i < n; at += len[i], i++) {
        memcpy(p + at, hva[i], len[i]);
      }
      hvf_stages[s].buf = p;
      hvf_stages[s].len = (uint32_t)total;
      if (hvf_trace & 4) {
        fprintf(stderr, "[trace] stage %u: %llu bytes in %d pieces\n", s, (unsigned long long)total, n);
      }
      return (Term)s;
    }
  }
  return (Term)HVF_ERR;
}

static void hvf_stage_free(uint32_t s) {
  if (s < HVF_STAGES) {
    free(hvf_stages[s].buf);
    hvf_stages[s].buf = NULL;
  }
}

// Hvf.stage_drop(slot) -> U32: frees a slot unsent.
Term hvf_stage_drop_run(Env e, Term* f, IoWork* w) {
  hvf_stage_free((u32)f[0]);
  return (Term)0;
}

// Sends what the socket takes of the pending bytes; 0, or an errno (not
// EAGAIN: the socket is full).
static int hvf_wsend(HvfSock* k) {
  while (k->woff < k->wlen) {
    ssize_t m = send(k->fd, k->wbuf + k->woff, k->wlen - k->woff, HVF_NOSIG);
    if (m > 0) {
      k->woff += (u64)m;
      hvf_wtotal -= (u64)m;
      k->wlast = io_tick();
    } else if (m < 0 && errno == EINTR) {
      continue;
    } else if (m < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return 0;
    } else {
      return m < 0 ? errno : EPIPE;
    }
  }
  hvf_wdrop(k);
  return 0;
}

// Keeps n bytes after the pending ones.
static void hvf_wkeep(HvfSock* k, const uint8_t* p, u64 n) {
  if (k->wlen + n > k->wsize) {
    u64 have = hvf_wpend(k);
    if (k->woff) {
      memmove(k->wbuf, k->wbuf + k->woff, have);
      k->woff = 0;
      k->wlen = have;
    }
    if (have + n > k->wsize) {
      u64 size = k->wsize ? k->wsize : 65536;
      while (size < have + n) {
        size *= 2;
      }
      k->wbuf  = io_mem(realloc(k->wbuf, size));
      k->wsize = size;
    }
  }
  memcpy(k->wbuf + k->wlen, p, n);
  k->wlen += n;
  hvf_wtotal += n;
}

// Sends n bytes of guest data on a NAT connection without waiting: what the
// socket does not take waits, after anything already pending. 1 when a
// flusher must start (Hvf.tcp_flush), else 0. Data after a close or a reset
// is dropped; a failed socket drops it too (its reader sees the failure).
static u32 hvf_nat_send(HvfSock* k, const uint8_t* buf, u64 n) {
  if (k->wclose || k->wreset) {
    return 0;
  }
  u64 at = 0;
  if (hvf_wpend(k) == 0) {
    while (at < n) {
      ssize_t m = send(k->fd, buf + at, n - at, HVF_NOSIG);
      if (m > 0) {
        at += (u64)m;
      } else if (m < 0 && errno == EINTR) {
        continue;
      } else if (m < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        break;
      } else {
        return 0;
      }
    }
    if (at == n) {
      return 0;
    }
    k->wlast = io_tick();
  }
  if (hvf_wpend(k) + (n - at) > HVF_WHARD || hvf_wtotal + (n - at) > HVF_WALL) {
    k->wreset = 1;
    hvf_wdrop(k);
  } else {
    hvf_wkeep(k, buf + at, n - at);
  }
  if (k->flushing) {
    return 0;
  }
  k->flushing = 1;
  return 1;
}

// Hvf.tcp_send_staged(conn, slot) -> U32: sends a slot's bytes on a NAT
// connection as hvf_nat_send does and frees it; 1 when a flusher must
// start, else 0.
Term hvf_tcp_send_staged_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  u32      s = (u32)f[1];
  u32      r = !k || s >= HVF_STAGES || !hvf_stages[s].buf ? 0 : hvf_nat_send(k, hvf_stages[s].buf, hvf_stages[s].len);
  hvf_stage_free(s);
  return (Term)r;
}

// The flusher's step: sends what the socket takes, then answers
//   0  the pending data drained to HVF_WCAP / 2 after TcpBlocked: the NAT
//      gets TcpUnblocked, and the flusher goes on (Hvf.tcp_flush again);
//   3  the pending data passed HVF_WCAP: the NAT gets TcpBlocked, and the
//      flusher goes on;
//   2  the connection was reset (over HVF_WHARD, no byte taken for
//      HVF_WSTALL, or the socket failed): the NAT gets TcpReset;
//   1  nothing is pending (or the socket is gone): the flusher ends.
// Otherwise it parks until the socket takes more, looking again every
// HVF_WTICK. A shutdown or close the NAT asked for meanwhile happens once
// the data is out.
static Term hvf_tcp_flush_more(Env e, IoWork* w);

static Term hvf_tcp_flush_step(HvfSock* k, IoWork* w) {
  int err   = k->wreset ? 0 : hvf_wsend(k);
  u64 now   = io_tick();
  int late  = hvf_wpend(k) && k->wclose && now >= k->wdead;
  int stall = hvf_wpend(k) && now - k->wlast >= HVF_WSTALL;
  if (k->wreset || err || stall || late) {
    if (hvf_trace & 2) {
      fprintf(stderr, "[trace] tcp %u: reset (%s, %llu pending)\n", k->key, k->wreset ? "over the cap" : err ? strerror(err) : late ? "closed too long" : "stalled", (unsigned long long)hvf_wpend(k));
    }
    int           closed = k->wclose;
    struct linger l      = {1, 0};
    setsockopt(k->fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
    hvf_wdrop(k);
    k->flushing = 0;
    hvf_sock_free(k);
    return (Term)(u32)(closed ? 1 : 2);
  }
  if (hvf_wpend(k) == 0) {
    if (k->wclose) {
      k->flushing = 0;
      hvf_sock_free(k);
      return (Term)1;
    }
    if (k->wshut) {
      k->wshut = 0;
      shutdown(k->fd, SHUT_WR);
    }
    if (k->blocked) {
      k->blocked = 0;
      return (Term)0;
    }
    k->flushing = 0;
    return (Term)1;
  }
  if (!k->wclose && !k->blocked && (hvf_wpend(k) > HVF_WCAP || hvf_wtotal > HVF_WBUDGET)) {
    k->blocked = 1;
    return (Term)3;
  }
  if (!k->wclose && k->blocked && hvf_wpend(k) <= HVF_WCAP / 2 && hvf_wtotal <= HVF_WBUDGET / 2) {
    k->blocked = 0;
    return (Term)0;
  }
  u64 until = k->wlast + HVF_WSTALL < now + HVF_WTICK ? k->wlast + HVF_WSTALL : now + HVF_WTICK;
  k->parked++;
  return io_wait_on(w, k->fd, POLLOUT, until, hvf_tcp_flush_more);
}

static Term hvf_tcp_flush_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  if (hvf_sock_woke(k)) {
    return (Term)1;
  }
  return hvf_tcp_flush_step(k, w);
}

// Hvf.tcp_flush(conn) -> U32: the flusher of a NAT connection (started when
// Hvf.nat_send or Hvf.tcp_send_staged answers 1): see hvf_tcp_flush_step.
Term hvf_tcp_flush_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (!k) {
    return (Term)1;
  }
  w->made = (intptr_t)(k - hvf_socks);
  return hvf_tcp_flush_step(k, w);
}

// Hvf.net_holds() -> List<U32>: for each TCP connection holding data for the
// guest, [conn, bytes held, parked] (the control socket's net command).
Term hvf_net_holds_run(Env e, Term* f, IoWork* w) {
  uint32_t ws[4 * 64];
  int      n = 0;
  for (int i = 0; i < HVF_MAX_SOCKS && n + 3 <= 64 * 4; i++) {
    HvfSock* k = &hvf_socks[i];
    if (k->used && !k->udp && k->rbuf) {
      ws[n++] = k->key;
      ws[n++] = k->rlen;
      ws[n++] = (uint32_t)k->parked;
    }
  }
  return hvf_words(e, ws, (u64)n);
}

// Hvf.nat_send(conn, bytes) -> U32: sends guest data on a NAT connection
// as hvf_nat_send does: 1 when a flusher must start (Hvf.tcp_flush), else 0.
Term hvf_nat_send_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  u64      n;
  char*    buf = io_cbuf(e, f[1], &n, CID(Con));
  u32      r   = !k || !buf ? 0 : hvf_nat_send(k, (const uint8_t*)buf, n);
  free(buf);
  return (Term)r;
}

// Hvf.tcp_shutdown(conn) -> U32: no more data from the guest (once what is
// pending is out).
Term hvf_tcp_shutdown_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (k && hvf_wpend(k)) {
    k->wshut = 1;
    return (Term)0;
  }
  return (Term)(k && shutdown(k->fd, SHUT_WR) == 0 ? 0 : HVF_ERR);
}

// Resets k's socket at once: what is pending is dropped (SO_LINGER 0).
static void hvf_tcp_reset(HvfSock* k) {
  struct linger l = {1, 0};
  setsockopt(k->fd, SOL_SOCKET, SO_LINGER, &l, sizeof l);
  hvf_wdrop(k);
  hvf_sock_free(k);
}

// How many closed connections still send what is pending.
static int hvf_wlingering(void) {
  int n = 0;
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    if (hvf_socks[i].used && !hvf_socks[i].closing && !hvf_socks[i].udp && hvf_socks[i].wclose) {
      n++;
    }
  }
  return n;
}

// Hvf.tcp_close(conn) -> U32: closes now, or once what is pending is out
// (the flusher closes it; reading stops at once), within HVF_WLINGER; with
// HVF_WLINGER_MAX closes already waiting so, it resets at once.
Term hvf_tcp_close_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (k && hvf_wpend(k) && !k->wreset && hvf_wlingering() >= HVF_WLINGER_MAX) {
    hvf_tcp_reset(k);
    return (Term)0;
  }
  if (k && hvf_wpend(k) && !k->wreset) {
    k->wclose = 1;
    k->wdead  = io_tick() + HVF_WLINGER;
    shutdown(k->fd, SHUT_RD);
    if (k->wake[1] >= 0) {
      (void)!write(k->wake[1], "x", 1);
    }
    return (Term)0;
  }
  if (k) {
    hvf_sock_free(k);
  }
  return (Term)0;
}

// Hvf.tcp_abort(conn) -> U32: the guest reset the connection: its socket is
// reset at once, what is pending dropped.
Term hvf_tcp_abort_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 0);
  if (k) {
    hvf_tcp_reset(k);
  }
  return (Term)0;
}

static uint32_t hvf_udp_next;

// The UDP flow of guest port sport to host address ip:port, if open.
static HvfSock* hvf_udp_flow(uint32_t sport, uint32_t ip, uint32_t port) {
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    HvfSock* k = &hvf_socks[i];
    if (k->used && k->udp && !k->closing && k->uport == sport && k->uip == ip && k->urport == port) {
      return k;
    }
  }
  return NULL;
}

// Makes room for a new UDP flow: past HVF_UDP_MAX the least recently used
// one closes (its receiver ends).
static void hvf_udp_room(void) {
  int      n   = 0;
  HvfSock* old = NULL;
  for (int i = 0; i < HVF_MAX_SOCKS; i++) {
    HvfSock* k = &hvf_socks[i];
    if (k->used && k->udp && !k->closing) {
      n++;
      if (!old || k->ulast < old->ulast) {
        old = k;
      }
    }
  }
  if (n >= HVF_UDP_MAX && old) {
    hvf_sock_free(old);
  }
}

// Hvf.udp_send(sport, ip, port, bytes) -> U32: sends from the flow of guest
// port sport to ip:port, a socket connected to ip:port (so only ip:port
// answers it), opening it on first use: its flow number when it was opened
// (the caller starts its receiver, Hvf.udp_recv), 0 otherwise, 0xFFFFFFFF
// on failure.
Term hvf_udp_send_run(Env e, Term* f, IoWork* w) {
  u32   sport = (u32)f[0], ip = (u32)f[1], port = (u32)f[2];
  u64   n;
  char* buf = io_cbuf(e, f[3], &n, CID(Con));
  if (!buf) {
    return (Term)HVF_ERR;
  }
  HvfSock* k     = hvf_udp_flow(sport, ip, port);
  u32      fresh = 0;
  if (!k) {
    hvf_udp_room();
    int fd = hvf_fd_has(1) ? socket(AF_INET, SOCK_DGRAM, 0) : -1;
    if (fd < 0) {
      free(buf);
      return (Term)HVF_ERR;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_in a = hvf_addr(ip, port);
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) {
      close(fd);
      free(buf);
      return (Term)HVF_ERR;
    }
    do {
      fresh = ++hvf_udp_next;
    } while (fresh == 0 || fresh == HVF_ERR);
    k = hvf_sock_new(fresh, 1, fd, 1);
    if (!k) {
      close(fd);
      free(buf);
      return (Term)HVF_ERR;
    }
    k->uport  = sport;
    k->uip    = ip;
    k->urport = port;
  }
  send(k->fd, buf, n, HVF_NOSIG);
  free(buf);
  k->ulast = io_tick();
  return (Term)fresh;
}

static Term hvf_udp_recv_more(Env e, IoWork* w) {
  HvfSock* k = hvf_sock_at(w);
  if (hvf_sock_woke(k)) {
    return term_pak(CID(Nil), 0);
  }
  char    buf[65536];
  ssize_t n   = recv(k->fd, buf, sizeof buf, 0);
  u64     now = io_tick();
  if (n < 0) {
    // nothing yet, or an ICMP error from the peer (a connected socket reports
    // it once): wait on, unless the flow has been idle too long
    if (now - k->ulast >= HVF_UDP_IDLE) {
      if (hvf_trace & 2) {
        fprintf(stderr, "[trace] udp %u: idle, closed\n", k->key);
      }
      hvf_sock_free(k);
      return term_pak(CID(Nil), 0);
    }
    k->parked++;
    return io_wait_on(w, k->fd, POLLIN, k->ulast + HVF_UDP_IDLE, hvf_udp_recv_more);
  }
  k->ulast = now;
  // [ip, port, bytes...]
  Term xs = io_list(e, buf, (u64)n);
  xs = io_node(e, CID(Con), (Term)k->urport, xs);
  return io_node(e, CID(Con), (Term)k->uip, xs);
}

// Hvf.udp_recv(flow) -> List<U32>: parks until a datagram arrives on the
// flow; [ip, port, bytes...], or [] once the flow is closed (idle for
// HVF_UDP_IDLE, or the least recently used past HVF_UDP_MAX).
Term hvf_udp_recv_run(Env e, Term* f, IoWork* w) {
  HvfSock* k = hvf_sock((u32)f[0], 1);
  if (!k) {
    return term_pak(CID(Nil), 0);
  }
  w->made = (intptr_t)(k - hvf_socks);
  k->parked++;
  return io_wait_on(w, k->fd, POLLIN, k->ulast + HVF_UDP_IDLE, hvf_udp_recv_more);
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
#ifdef __APPLE__
#include <sys/mount.h>
#else
#include <sys/vfs.h>
#endif
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
  int         k     = slash ? snprintf(parent, sizeof parent, "%s/%.*s", root, (int)(slash - rel), rel)
                            : snprintf(parent, sizeof parent, "%s", root);
  if (k < 0 || k >= (int)sizeof parent) {
    return ENAMETOOLONG;
  }
  char real[PATH_MAX];
  if (!realpath(parent, real)) {
    return errno;
  }
  // a share of "/" holds every path (its prefix is the empty string)
  size_t rl = strcmp(root, "/") == 0 ? 0 : strlen(root);
  if (strncmp(real, root, rl) != 0 || (real[rl] != 0 && real[rl] != '/')) {
    return EACCES;
  }
  k = snprintf(out, PATH_MAX, "%s/%s", real, slash ? slash + 1 : rel);
  return k < 0 || k >= PATH_MAX ? ENAMETOOLONG : 0;
}

// Open files for reads and writes, by share, relative path and direction:
// resolving and opening a path costs more than moving a 512 KiB block, and a
// guest reads a file in many requests. An entry stays bound to the file it
// opened, so every operation that can change what a path names (create,
// mkdir, remove, rename, symlink) empties the share's entries first.
#define HVF_FDC 16
typedef struct {
  int      fd, wr;
  u32      sh;
  uint64_t used;
  char     rel[PATH_MAX];
} HvfFdc;
static HvfFdc   hvf_fdc[HVF_FDC];
static uint64_t hvf_fdc_tick;

static int hvf_fdc_find(u32 sh, const char* rel, int wr) {
  for (int i = 0; i < HVF_FDC; i++) {
    HvfFdc* c = &hvf_fdc[i];
    if (c->used && c->sh == sh && c->wr == wr && !strcmp(c->rel, rel)) {
      c->used = ++hvf_fdc_tick;
      return c->fd;
    }
  }
  return -1;
}

static void hvf_fdc_put(u32 sh, const char* rel, int wr, int fd) {
  HvfFdc* lru = &hvf_fdc[0];
  for (int i = 0; i < HVF_FDC; i++) {
    if (hvf_fdc[i].used < lru->used) {
      lru = &hvf_fdc[i];
    }
  }
  if (lru->used) {
    close(lru->fd);
  }
  lru->fd   = fd;
  lru->wr   = wr;
  lru->sh   = sh;
  lru->used = ++hvf_fdc_tick;
  snprintf(lru->rel, PATH_MAX, "%s", rel);
}

static void hvf_fdc_flush(u32 sh) {
  for (int i = 0; i < HVF_FDC; i++) {
    if (hvf_fdc[i].used && hvf_fdc[i].sh == sh) {
      close(hvf_fdc[i].fd);
      hvf_fdc[i].used = 0;
    }
  }
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
// 10 symlink(target path2), 11 readlink, 12 statfs, 13 read from offset a
// into the pieces of guest memory bytes lists (as Hvf.disk_copy takes them),
// 14 write them at offset a: both answer the count moved, and no byte passes
// through Bend.
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
  // reads and writes reuse an open file (hvf_fdc) and skip resolving
  int      io    = op == 2 || op == 3 || op == 13 || op == 14;
  int      wr    = op == 3 || op == 14;
  int      fd    = io ? hvf_fdc_find(sh, rel, wr) : -1;
  int      err   = fd >= 0 ? 0 : hvf_resolve(sh, rel, path);
  if (!err && (op == 4 || op == 5 || op == 6 || op == 7 || op == 10)) {
    hvf_fdc_flush(sh);
  }
  if (!err && io && fd < 0) {
    // a regular file only: a FIFO or a device in the share must not block
    // or reach the VMM
    struct stat st = {0};
    fd = open(path, (wr ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
      err = errno;
    } else if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
      err = S_ISDIR(st.st_mode) ? EISDIR : EINVAL;
      close(fd);
      fd = -1;
    } else {
      hvf_fdc_put(sh, rel, wr, fd);
    }
  }
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
      hvf_w64(&out, (uint64_t)HVF_ATIME(st));
      hvf_w64(&out, (uint64_t)HVF_MTIME(st));
      hvf_w64(&out, (uint64_t)HVF_CTIME(st));
      res = hvf_fs_done(e, &out);
    }
  } else if (op == 1) {
    // never through a symlink (O_NOFOLLOW), and the entries are looked at
    // where they are (fstatat), not through a path
    int  dfd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    DIR* d   = dfd >= 0 ? fdopendir(dfd) : NULL;
    if (!d) {
      res = hvf_fs_err(e, errno);
      if (dfd >= 0) {
        close(dfd);
      }
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
      qsort(names, cnt, sizeof(char*), hvf_dir_cmp);
      hvf_w(&out, 5);
      for (size_t i = (size_t)(u32)a; i < cnt && i < (size_t)(u32)a + b; i++) {
        struct stat st;
        int         ok = fstatat(dirfd(d), names[i], &st, AT_SYMLINK_NOFOLLOW) == 0;
        hvf_w64(&out, ok ? (uint64_t)st.st_ino : 0);
        hvf_w(&out, !ok ? 0 : S_ISDIR(st.st_mode) ? 4 : S_ISLNK(st.st_mode) ? 10 : S_ISREG(st.st_mode) ? 8 : 0);
        size_t len = strlen(names[i]);
        hvf_w(&out, (uint32_t)len);
        for (size_t j = 0; j < len; j++) {
          hvf_w(&out, (uint8_t)names[i][j]);
        }
      }
      closedir(d);
      for (size_t i = 0; i < cnt; i++) {
        free(names[i]);
      }
      free(names);
      res = hvf_fs_done(e, &out);
    }
  } else if (op == 2 || op == 3) {
    if (op == 2) {
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
  } else if (op == 13 || op == 14) {
    static uint8_t* hva[HVF_MAX_IOVS];
    static u64      len[HVF_MAX_IOVS];
    int             n = hvf_iovs(bytes, nb, hva, len, HVF_MAX_IOVS);
    if (n < 0) {
      res = hvf_fs_err(e, EFAULT);
    } else {
      int64_t k = hvf_iov_io(fd, op == 14, (off_t)a, hva, len, n, 0);
      if (hvf_trace & 8) {
        fprintf(stderr, "[trace] 9p %s %s at %llu: %lld bytes in %d pieces\n", op == 14 ? "write" : "read", rel,
                (unsigned long long)a, (long long)k, n);
      }
      if (k < 0) {
        res = hvf_fs_err(e, errno);
      } else {
        uint32_t ws[2] = {4, (uint32_t)k};
        res = hvf_words(e, ws, 2);
      }
    }
  } else if (op == 4) {
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, b & 0777);
    res = fd < 0 ? hvf_fs_err(e, errno) : (close(fd), hvf_fs_ok(e));
  } else if (op == 5) {
    res = mkdir(path, b & 0777) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 6) {
    res = (b ? rmdir(path) : unlink(path)) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 7) {
    res = rename(path, path2) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
  } else if (op == 8) {
    int t = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    res   = t < 0 || ftruncate(t, (off_t)a) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
    if (t >= 0) {
      close(t);
    }
  } else if (op == 9) {
    res = lchmod(path, b & 0777) != 0 ? hvf_fs_err(e, errno) : hvf_fs_ok(e);
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
    if (statfs(hvf_shares[sh], &sf) != 0) {
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
      vmb_kick(&hvf_cpus[i]);
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
#ifdef __APPLE__
    hvf_pause_start = mach_absolute_time();
#else
    hvf_pause_start = hvf_ns();
#endif
  }
  pthread_mutex_unlock(&hvf_gate_mu);
  hvf_kick_all();
  return (Term)(u32)was;
}

// Hvf.resume() -> U32: lets every vCPU run again.
Term hvf_resume_run(Env e, Term* f, IoWork* w) {
  pthread_mutex_lock(&hvf_gate_mu);
  if (hvf_paused) {
#ifdef __APPLE__
    hvf_pause_total += mach_absolute_time() - hvf_pause_start;
#else
    hvf_pause_total += hvf_ns() - hvf_pause_start;
#endif
  }
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

// This program's arguments, NUL-separated, in a new buffer; their length.
static uint64_t hvf_args(char** out) {
  char* b = io_mem(malloc(hvf_arglen ? hvf_arglen : 1));
  memcpy(b, hvf_argbuf, hvf_arglen);
  *out = b;
  return hvf_arglen;
}

// Hvf.snap_write(path, words) -> U32: writes a snapshot of the paused VM:
//   "BVMSNAP1", version u32 (HVF_SNAP_VER: 1 Hypervisor.framework, 2 KVM;
//   a snapshot restores only on its own hypervisor), ncpus u32, ram base
//   u64, ram size u64, args (u64 length, NUL-separated argv), machine (u64
//   count, u32 words), GIC state (u64 size, bytes), per vCPU (u64 size,
//   register entries; 0 when absent), then RAM at the next 16 KiB boundary.
//   0, or an errno.
Term hvf_snap_write_run(Env e, Term* f, IoWork* w) {
  u64         n;
  char*       path = io_cstr(e, f[0], &n);
  struct stat dst, src;
  // guest RAM is mapped from the snapshot this VM was restored from: writing
  // over that file would pull the RAM from under the guest
  if (hvf_snap.active && stat(path, &dst) == 0 && fstat(hvf_snap.fd, &src) == 0 && dst.st_dev == src.st_dev
      && dst.st_ino == src.st_ino) {
    free(path);
    return (Term)(u32)EBUSY;
  }
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
  // what the loader takes (hvf_snap_open_run): a larger state is refused
  // here rather than written as a snapshot that cannot be restored
  if (nw > (u64)1 << 26) {
    free(ws);
    free(path);
    return (Term)(u32)EFBIG;
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
  uint8_t* gic  = NULL;
  size_t   ngic = 0;
  vmb_gic_save(&gic, &ngic);
  // argv
  char*    args = NULL;
  uint64_t alen = hvf_args(&args);
  int      err  = 0;
  // the guest's whole RAM: readable by this user alone, and never written
  // through a symlink planted at the path
  int    fd   = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
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
    uint32_t ver = HVF_SNAP_VER;
    int      bad = hvf_put(fd, "BVMSNAP1", 8) || hvf_put(fd, &ver, 4) || hvf_put(fd, &ncpus, 4)
      || hvf_fput64(fd, hvf_ram_base) || hvf_fput64(fd, hvf_ram_size) || hvf_fput64(fd, alen)
      || hvf_put(fd, args, alen);
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
  free(args);
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
  if (hvf_get(fd, magic, 8) || memcmp(magic, "BVMSNAP1", 8) || hvf_get(fd, &ver, 4) || ver != HVF_SNAP_VER
      || hvf_get(fd, &hvf_snap.ncpus, 4) || hvf_snap.ncpus > 64 || hvf_get(fd, &hvf_snap.ram_base, 8)
      || hvf_get(fd, &hvf_snap.ram_size, 8) || hvf_get(fd, &hvf_snap.nargs, 8) || hvf_snap.nargs > 1u << 20) {
    close(fd);
    return (Term)(u32)EINVAL;
  }
  hvf_snap.args = io_mem(malloc(hvf_snap.nargs + 1));
  int bad = hvf_get(fd, hvf_snap.args, hvf_snap.nargs) || hvf_get(fd, &hvf_snap.nwords, 8) || hvf_snap.nwords > 1u << 26;
  hvf_snap.args[hvf_snap.nargs] = 0;
  if (!bad) {
    hvf_snap.words = io_mem(malloc(hvf_snap.nwords * 4 + 4));
    bad = hvf_get(fd, hvf_snap.words, hvf_snap.nwords * 4) || hvf_get(fd, &hvf_snap.ngic, 8) || hvf_snap.ngic > 1u << 24;
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
  off_t       at   = lseek(fd, 0, SEEK_CUR);
  struct stat st;
  hvf_snap.ram_off = (uint64_t)((at + 16383) & ~(off_t)16383);
  // guest RAM is mapped from the file: all of it must be there (a short file
  // would fault the VMM on the first touch past its end)
  if (fstat(fd, &st) != 0 || hvf_snap.ram_size == 0 || hvf_snap.ram_size > (uint64_t)1 << 40
      || (uint64_t)st.st_size < hvf_snap.ram_off + hvf_snap.ram_size) {
    close(fd);
    return (Term)(u32)EINVAL;
  }
  hvf_snap.fd      = fd;
  hvf_snap.active  = 1;
#ifdef __APPLE__
  hvf_restore_now = mach_absolute_time();
#endif
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
  for (size_t i = 0; i < hvf_snap.nargs && k < 4096; i += strnlen(hvf_snap.args + i, hvf_snap.nargs - i) + 1) {
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
  return (Term)(vmb_gic_restore(hvf_snap.gic, hvf_snap.ngic) == 0 ? 0 : HVF_ERR);
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
  if (fd >= 0) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  if (fd < 0 || bind(fd, (struct sockaddr*)&a, sizeof a) != 0 || listen(fd, 4) != 0) {
    int err = errno;
    if (fd >= 0) {
      close(fd);
    }
    return (Term)(u32)err;
  }
  chmod(a.sun_path, 0600); // this user alone
  fcntl(fd, F_SETFL, O_NONBLOCK);
  hvf_ctl_fd = fd;
  return (Term)0;
}

static Term hvf_ctl_line(Env e, IoWork* w);

// One client at a time: one that sends no full line within 5 s is dropped,
// so it cannot hold the control socket from the next.
static uint64_t hvf_ctl_deadline;

static int hvf_accept_full(int err) {
  return err == EMFILE || err == ENFILE || err == ENOBUFS || err == ENOMEM;
}

static Term hvf_ctl_accept(Env e, IoWork* w) {
  int c = accept(hvf_ctl_fd, NULL, NULL);
  if (c < 0) {
    // out of descriptors the listener stays readable: wait, don't spin
    return hvf_accept_full(errno) ? io_wait_on(w, 0, 0, io_tick() + 100000000ull, hvf_ctl_accept)
                                  : io_wait_on(w, hvf_ctl_fd, POLLIN, 0, hvf_ctl_accept);
  }
  fcntl(c, F_SETFD, FD_CLOEXEC);
  fcntl(c, F_SETFL, O_NONBLOCK);
  hvf_ctl_client   = c;
  hvf_ctl_deadline = io_tick() + 5000000000ull;
  w->made          = 0;
  return hvf_ctl_line(e, w);
}

// Reads one line from the client into w->data.
static Term hvf_ctl_line(Env e, IoWork* w) {
  char ch;
  for (;;) {
    ssize_t k = read(hvf_ctl_client, &ch, 1);
    if (k < 0 && errno == EAGAIN) {
      if (io_tick() >= hvf_ctl_deadline) {
        close(hvf_ctl_client);
        hvf_ctl_client = -1;
        return hvf_ctl_accept(e, w);
      }
      return io_wait_on(w, hvf_ctl_client, POLLIN, hvf_ctl_deadline, hvf_ctl_line);
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

// vsock over Unix sockets
// ========================
//
// Guest-initiated: the guest's connection to host port P becomes a
// connection to the Unix socket "<base>_P" (Hvf.unix_connect, then the
// tcp_* effects on the same table). Host-initiated: clients connect to
// "<base>" and send "CONNECT <port>\n" (Firecracker's convention);
// Hvf.vsock_accept answers [conn, port] for each.

static int      hvf_vs_fd = -1;
static char     hvf_vs_base[1024];

// Hvf.vsock_base() -> String: the --vsock base path.
Term hvf_vsock_base_run(Env e, Term* f, IoWork* w) {
  return io_str(e, hvf_vs_base, strlen(hvf_vs_base));
}
static uint32_t hvf_vs_next = 0x80000000u;
// vsock's Unix sockets: macOS gives them a send buffer of a few KiB, so
// guest data would leave a few KiB per wake; 1 MiB lets it stream.
static void hvf_unix_buf(int fd) {
  int sz = 1 << 20;
  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
}


// Hvf.unix_connect(key, path) -> U32: a non-blocking Unix-socket connect
// filed under key; 0, or an errno.
Term hvf_unix_connect_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[1], &n);
  struct sockaddr_un a = {0};
  a.sun_family = AF_UNIX;
  if (n >= sizeof a.sun_path) {
    free(path);
    return (Term)(u32)ENAMETOOLONG;
  }
  memcpy(a.sun_path, path, n + 1);
  free(path);
  if (!hvf_fd_has(1)) {
    return (Term)(u32)EMFILE;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd >= 0) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  if (fd < 0) {
    return (Term)(u32)errno;
  }
  fcntl(fd, F_SETFL, O_NONBLOCK);
  int one = 1;
#ifdef SO_NOSIGPIPE
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  hvf_unix_buf(fd);
  if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0 && errno != EINPROGRESS) {
    int err = errno;
    close(fd);
    return (Term)(u32)err;
  }
  if (!hvf_sock_new((u32)f[0], 0, fd, 1)) {
    close(fd);
    return (Term)(u32)EMFILE;
  }
  return (Term)0;
}

// Hvf.vsock_listen(path) -> U32: 0, or an errno.
Term hvf_vsock_listen_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  struct sockaddr_un a = {0};
  a.sun_family = AF_UNIX;
  if (n >= sizeof a.sun_path) {
    free(path);
    return (Term)(u32)ENAMETOOLONG;
  }
  memcpy(a.sun_path, path, n + 1);
  snprintf(hvf_vs_base, sizeof hvf_vs_base, "%s", path);
  unlink(path);
  free(path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd >= 0) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
  }
  if (fd < 0 || bind(fd, (struct sockaddr*)&a, sizeof a) != 0 || listen(fd, 16) != 0) {
    int err = errno;
    if (fd >= 0) {
      close(fd);
    }
    return (Term)(u32)err;
  }
  chmod(a.sun_path, 0600); // this user alone
  fcntl(fd, F_SETFL, O_NONBLOCK);
  hvf_vs_fd = fd;
  return (Term)0;
}

static Term hvf_vs_line(Env e, IoWork* w);

static uint64_t hvf_vs_deadline;

static Term hvf_vs_accept(Env e, IoWork* w) {
  int c = accept(hvf_vs_fd, NULL, NULL);
  if (c < 0) {
    return hvf_accept_full(errno) ? io_wait_on(w, 0, 0, io_tick() + 100000000ull, hvf_vs_accept)
                                  : io_wait_on(w, hvf_vs_fd, POLLIN, 0, hvf_vs_accept);
  }
  fcntl(c, F_SETFD, FD_CLOEXEC);
  fcntl(c, F_SETFL, O_NONBLOCK);
  int one = 1;
#ifdef SO_NOSIGPIPE
  setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  hvf_unix_buf(c);
  w->hand         = c;
  w->made         = 0;
  hvf_vs_deadline = io_tick() + 5000000000ull;
  return hvf_vs_line(e, w);
}

// Reads the client's "CONNECT <port>\n"; files the socket and answers
// [conn, port] (a bad line closes the client and waits for the next).
static Term hvf_vs_line(Env e, IoWork* w) {
  int  c = (int)w->hand;
  char ch;
  for (;;) {
    ssize_t k = read(c, &ch, 1);
    if (k < 0 && errno == EAGAIN) {
      // a client that names no port within 5 s is dropped (as on the
      // control socket), so it cannot hold the listener
      if (io_tick() >= hvf_vs_deadline) {
        close(c);
        w->made = 0;
        return hvf_vs_accept(e, w);
      }
      return io_wait_on(w, c, POLLIN, hvf_vs_deadline, hvf_vs_line);
    }
    if (k <= 0 || ch == '\n' || w->made >= 63) {
      break;
    }
    w->data[w->made++] = ch;
  }
  w->data[w->made] = 0;
  unsigned port;
  if (sscanf(w->data, "CONNECT %u", &port) != 1) {
    close(c);
    w->made = 0;
    return hvf_vs_accept(e, w);
  }
  uint32_t conn = hvf_vs_next++;
  if (!hvf_sock_new(conn ^ 0x40000000u, 0, c, 1)) {
    close(c);
    w->made = 0;
    return hvf_vs_accept(e, w);
  }
  free(w->data);
  uint32_t ws[2] = {conn, port};
  return hvf_words(e, ws, 2);
}

// Hvf.vsock_accept() -> List<U32>: parks until a host client asks for a
// guest port; [conn, port] ([] without a listener).
Term hvf_vsock_accept_run(Env e, Term* f, IoWork* w) {
  if (hvf_vs_fd < 0) {
    return term_pak(CID(Nil), 0);
  }
  w->data = io_mem(malloc(64));
  w->made = 0;
  return hvf_vs_accept(e, w);
}

// UEFI flash
// ==========
//
// --firmware maps the firmware image as flash bank 0 at guest address 0,
// read-only and executable (it runs in place), padded to 64 MiB with 0xFF.
// Bank 1, the variable store, is 64 MiB of host memory at 0x0400_0000,
// loaded from --vars when given (and written back to it as the guest
// programs it) and erased (0xFF) otherwise. src/dev/pflash.bend models its
// command set; this side holds the bytes and maps them into the guest
// read-only while the bank reads as an array (Hvf.flash op 3).

#define HVF_FLASH_SIZE  0x4000000ull
#define HVF_FLASH1_BASE 0x4000000ull

static uint8_t* hvf_flash0;
static uint8_t* hvf_flash1;
static int      hvf_vars_fd = -1;
static int      hvf_flash1_mapped;

// Reads a file into a 64 MiB 0xFF-filled buffer; 0, or an errno.
static int hvf_flash_file(const char* path, uint8_t* to) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    return errno;
  }
  ssize_t k, at = 0;
  while (at < (ssize_t)HVF_FLASH_SIZE && (k = read(fd, to + at, HVF_FLASH_SIZE - at)) > 0) {
    at += k;
  }
  close(fd);
  return k < 0 ? EIO : 0;
}

// Hvf.fw_load(code, vars) -> U32: 0, or a step code (1 code file, 2 vars
// file, 3 mapping).
Term hvf_fw_load_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* code = io_cstr(e, f[0], &n);
  char* vars = io_cstr(e, f[1], &n);
  hvf_flash0 = mmap(NULL, HVF_FLASH_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  hvf_flash1 = mmap(NULL, HVF_FLASH_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  int rc = 0;
  if (hvf_flash0 == MAP_FAILED || hvf_flash1 == MAP_FAILED) {
    rc = 3;
  } else {
    memset(hvf_flash0, 0xFF, HVF_FLASH_SIZE);
    memset(hvf_flash1, 0xFF, HVF_FLASH_SIZE);
    if (hvf_flash_file(code, hvf_flash0) != 0) {
      rc = 1;
    } else if (vars[0] && (hvf_flash_file(vars, hvf_flash1) != 0 || (hvf_vars_fd = open(vars, O_RDWR)) < 0)) {
      rc = 2;
    } else if (vmb_map(hvf_flash0, 0, HVF_FLASH_SIZE, VMB_R | VMB_X) != 0
               || vmb_map(hvf_flash1, HVF_FLASH1_BASE, HVF_FLASH_SIZE, VMB_R) != 0) {
      rc = 3;
    } else {
      hvf_flash1_mapped = 1;
    }
  }
  free(code);
  free(vars);
  return (Term)(u32)rc;
}

// Persists [off, off+len) of bank 1 to the --vars file.
static void hvf_flash_sync(uint64_t off, uint64_t len) {
  if (hvf_vars_fd >= 0 && pwrite(hvf_vars_fd, hvf_flash1 + off, len, (off_t)off) != (ssize_t)len) {
    fprintf(stderr, "bend-vmm: cannot write the UEFI variables back\n");
  }
}

// Hvf.flash(op, a, b, bytes) -> U32 on bank 1: op 0 reads b bytes at a
// (little-endian), 1 writes bytes at a, 2 erases b bytes at a, 3 maps the
// bank into the guest read-only (a = 1) or unmaps it (a = 0).
Term hvf_flash_run(Env e, Term* f, IoWork* w) {
  u32 op = (u32)f[0], a = (u32)f[1], b = (u32)f[2];
  if (!hvf_flash1) {
    return (Term)(u32)0xFFFFFFFFu;
  }
  switch (op) {
    case 0: {
      u32 v = 0;
      if (a < HVF_FLASH_SIZE && b <= 4 && a + b <= HVF_FLASH_SIZE) {
        memcpy(&v, hvf_flash1 + a, b);
      }
      return (Term)v;
    }
    case 1: {
      u64   n;
      char* buf = io_cbuf(e, f[3], &n, CID(Con));
      if (buf && a < HVF_FLASH_SIZE && n <= HVF_FLASH_SIZE - a) {
        memcpy(hvf_flash1 + a, buf, n);
        hvf_flash_sync(a, n);
      }
      free(buf);
      return (Term)0;
    }
    case 2:
      if (a < HVF_FLASH_SIZE && b <= HVF_FLASH_SIZE - a) {
        memset(hvf_flash1 + a, 0xFF, b);
        hvf_flash_sync(a, b);
      }
      return (Term)0;
    case 3:
      if (a && !hvf_flash1_mapped) {
        hvf_flash1_mapped = vmb_map(hvf_flash1, HVF_FLASH1_BASE, HVF_FLASH_SIZE, VMB_R) == 0;
      } else if (!a && hvf_flash1_mapped) {
        hvf_flash1_mapped = vmb_unmap(HVF_FLASH1_BASE, HVF_FLASH_SIZE) != 0;
      }
      return (Term)0;
  }
  return (Term)0;
}

// The framebuffer and the display window
// =======================================
//
// --display WxH maps 16 MiB of host memory at the guest's framebuffer
// address (src/vmm/layout.bend), which the device tree describes as a
// simple-framebuffer. Hvf.fb_present shows it in a window opened with Bend's
// Window.open: Metal reads the guest's pixels straight from that memory (a
// no-copy buffer) and blits them to the window's drawable, then the window's
// events come back as Bend Events.

static uint8_t* hvf_fb;
static uint32_t hvf_fb_w, hvf_fb_h;
#define HVF_FB_BASE 0x10000000ull
#define HVF_FB_SIZE 0x1000000ull

// Hvf.fb_init(width, height) -> U32: 0, or a step code.
Term hvf_fb_init_run(Env e, Term* f, IoWork* w) {
  uint32_t fw = (u32)f[0], fh = (u32)f[1];
  if (fw == 0 || fh == 0 || (uint64_t)fw * fh * 4 > HVF_FB_SIZE) {
    return (Term)1;
  }
  hvf_fb = mmap(NULL, HVF_FB_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (hvf_fb == MAP_FAILED) {
    hvf_fb = NULL;
    return (Term)2;
  }
  if (vmb_map(hvf_fb, HVF_FB_BASE, HVF_FB_SIZE, VMB_R | VMB_W) != 0) {
    return (Term)3;
  }
  hvf_fb_w = fw;
  hvf_fb_h = fh;
  return (Term)0;
}

// Hvf.fb_dump(path) -> U32: writes the framebuffer as a binary PPM (P6);
// 0, or an errno.
Term hvf_fb_dump_run(Env e, Term* f, IoWork* w) {
  u64   n;
  char* path = io_cstr(e, f[0], &n);
  if (!hvf_fb) {
    free(path);
    return (Term)(u32)ENODEV;
  }
  int   ofd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
  FILE* out = ofd >= 0 ? fdopen(ofd, "wb") : NULL;
  if (!out && ofd >= 0) {
    close(ofd);
  }
  free(path);
  if (!out) {
    return (Term)(u32)errno;
  }
  fprintf(out, "P6\n%u %u\n255\n", hvf_fb_w, hvf_fb_h);
  for (uint32_t y = 0; y < hvf_fb_h; y++) {
    for (uint32_t x = 0; x < hvf_fb_w; x++) {
      const uint8_t* p = hvf_fb + ((size_t)y * hvf_fb_w + x) * 4; // B G R A
      fputc(p[2], out);
      fputc(p[1], out);
      fputc(p[0], out);
    }
  }
  int err = ferror(out) ? EIO : 0;
  fclose(out);
  return (Term)(u32)err;
}

#if defined(__OBJC__) && defined(CID(Window.frame))

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// Events as Bend's Window.frame answers them (five words each: the
// constructor id and its fields); Bend's window.c is spliced after this
// file, so its window_list is not visible here.
static Term hvf_event(Env e, const u32* ev) {
  if (ev[0] == CID(Text)) {
    const char* s = (const char*)(ev + 1);
    return io_box(e, CID(Text), io_str(e, s, strnlen(s, 16)));
  }
  u32 n = cid_arity(ev[0]);
  if (n == 0) {
    return term_pak(ev[0], 0);
  }
  u64 l = heap_alloc(e, cls_fit(n));
  for (u32 j = 0; j < n; j += 1) {
    e.mem[l + j] = ev[1 + j];
  }
  return term_ctr(ev[0], l);
}

static Term hvf_events(Env e, const u32* p, u64 n) {
  Term list = term_pak(CID(Nil), 0);
  for (u64 i = n; i > 0; i -= 1) {
    list = io_node(e, CID(Con), hvf_event(e, p + 5 * (i - 1)), list);
  }
  return list;
}

static id<MTLBuffer>       hvf_fb_buf;
static id<MTLCommandQueue> hvf_fb_que;

// Hvf.fb_present(window) -> Window & List<Event>: shows the framebuffer in
// the window and answers the events since the last call.
Term hvf_fb_present_run(Env e, Term* f, IoWork* w) {
  intptr_t at = (intptr_t)io_hand_v(f[0]);
  Term     list;
  @autoreleasepool {
    for (;;) {
      NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast
        inMode:NSDefaultRunLoopMode dequeue:YES];
      if (ev == nil) {
        break;
      }
      [NSApp sendEvent:ev];
    }
    NSWindow*     win   = (__bridge NSWindow*)(void*)at;
    NSView*       view  = win.contentView;
    CAMetalLayer* layer = (CAMetalLayer*)view.layer;
    if (hvf_fb) {
      id<MTLDevice> dev = layer.device;
      if (hvf_fb_buf == nil) {
        layer.displaySyncEnabled = NO;
        hvf_fb_buf = [dev newBufferWithBytesNoCopy:hvf_fb length:HVF_FB_SIZE
          options:MTLResourceStorageModeShared deallocator:nil];
        hvf_fb_que = [dev newCommandQueue];
      }
      id<CAMetalDrawable> d = [layer nextDrawable];
      if (d != nil && hvf_fb_buf != nil) {
        id<MTLCommandBuffer>      cb = [hvf_fb_que commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        uint32_t                  cw = (uint32_t)d.texture.width < hvf_fb_w ? (uint32_t)d.texture.width : hvf_fb_w;
        uint32_t                  ch = (uint32_t)d.texture.height < hvf_fb_h ? (uint32_t)d.texture.height : hvf_fb_h;
        [bl copyFromBuffer:hvf_fb_buf sourceOffset:0 sourceBytesPerRow:hvf_fb_w * 4
          sourceBytesPerImage:(NSUInteger)hvf_fb_w * 4 * hvf_fb_h sourceSize:MTLSizeMake(cw, ch, 1)
          toTexture:d.texture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
        [bl endEncoding];
        [cb presentDrawable:d];
        [cb commit];
      }
    }
    NSMutableData* evs = [view valueForKey:@"evs"];
    list = hvf_events(e, evs.bytes, evs.length / 20);
    evs.length = 0;
  }
  return io_tup(e, io_hand(at), list);
}

#endif

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
#ifdef CID(Hvf.tcp_release)
  io_eff(CID(Hvf.tcp_release), hvf_tcp_release_run);
#endif
#ifdef CID(Hvf.net_holds)
  io_eff(CID(Hvf.net_holds), hvf_net_holds_run);
#endif
#ifdef CID(Hvf.tcp_fill)
  io_eff(CID(Hvf.tcp_fill), hvf_tcp_fill_run);
#endif
#ifdef CID(Hvf.stage)
  io_eff(CID(Hvf.stage), hvf_stage_run);
#endif
#ifdef CID(Hvf.stage_drop)
  io_eff(CID(Hvf.stage_drop), hvf_stage_drop_run);
#endif
#ifdef CID(Hvf.tcp_send_staged)
  io_eff(CID(Hvf.tcp_send_staged), hvf_tcp_send_staged_run);
#endif
#ifdef CID(Hvf.net_copy)
  io_eff(CID(Hvf.net_copy), hvf_net_copy_run);
#endif
#ifdef CID(Hvf.tcp_shutdown)
  io_eff(CID(Hvf.tcp_shutdown), hvf_tcp_shutdown_run);
#endif
#ifdef CID(Hvf.tcp_flush)
  io_eff(CID(Hvf.tcp_flush), hvf_tcp_flush_run);
#endif
#ifdef CID(Hvf.nat_send)
  io_eff(CID(Hvf.nat_send), hvf_nat_send_run);
#endif
#ifdef CID(Hvf.tcp_close)
  io_eff(CID(Hvf.tcp_close), hvf_tcp_close_run);
#endif
#ifdef CID(Hvf.tcp_abort)
  io_eff(CID(Hvf.tcp_abort), hvf_tcp_abort_run);
#endif
#ifdef CID(Hvf.udp_send)
  io_eff(CID(Hvf.udp_send), hvf_udp_send_run);
#endif
#ifdef CID(Hvf.set_dns)
  io_eff(CID(Hvf.set_dns), hvf_set_dns_run);
#endif
#ifdef CID(Hvf.dns)
  io_eff(CID(Hvf.dns), hvf_dns_run);
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
#ifdef CID(Hvf.vsock_base)
  io_eff(CID(Hvf.vsock_base), hvf_vsock_base_run);
#endif
#ifdef CID(Hvf.unix_connect)
  io_eff(CID(Hvf.unix_connect), hvf_unix_connect_run);
#endif
#ifdef CID(Hvf.vsock_listen)
  io_eff(CID(Hvf.vsock_listen), hvf_vsock_listen_run);
#endif
#ifdef CID(Hvf.vsock_accept)
  io_eff(CID(Hvf.vsock_accept), hvf_vsock_accept_run);
#endif
#ifdef CID(Hvf.fw_load)
  io_eff(CID(Hvf.fw_load), hvf_fw_load_run);
#endif
#ifdef CID(Hvf.flash)
  io_eff(CID(Hvf.flash), hvf_flash_run);
#endif
#ifdef CID(Hvf.fb_init)
  io_eff(CID(Hvf.fb_init), hvf_fb_init_run);
#endif
#ifdef CID(Hvf.fb_dump)
  io_eff(CID(Hvf.fb_dump), hvf_fb_dump_run);
#endif
#if defined(__OBJC__) && defined(CID(Window.frame)) && defined(CID(Hvf.fb_present))
  io_eff(CID(Hvf.fb_present), hvf_fb_present_run);
#endif
#ifdef CID(Hvf.irq)
  io_eff(CID(Hvf.irq), hvf_irq_run);
#endif
#ifdef CID(Hvf.kick)
  io_eff(CID(Hvf.kick), hvf_kick_run);
#endif
#ifdef CID(Hvf.set_args)
  io_eff(CID(Hvf.set_args), hvf_set_args_run);
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
#ifdef CID(Hvf.out_flush)
  io_eff(CID(Hvf.out_flush), hvf_out_flush_run);
#endif
#ifdef CID(Hvf.stdin)
  io_eff(CID(Hvf.stdin), hvf_stdin_run);
#endif
#ifdef CID(Hvf.stdin_tty)
  io_eff(CID(Hvf.stdin_tty), hvf_stdin_tty_run);
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
#ifdef CID(Hvf.signal_wait)
  io_eff(CID(Hvf.signal_wait), hvf_signal_wait_run);
#endif
#ifdef CID(Hvf.log_gate)
  io_eff(CID(Hvf.log_gate), hvf_log_gate_run);
#endif
#ifdef CID(Hvf.disk_status)
  io_eff(CID(Hvf.disk_status), hvf_disk_status_run);
#endif
#ifdef CID(Hvf.disk_open_backing)
  io_eff(CID(Hvf.disk_open_backing), hvf_disk_open_backing_run);
#endif
#ifdef CID(Hvf.disk_open_ro)
  io_eff(CID(Hvf.disk_open_ro), hvf_disk_open_ro_run);
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
#ifdef CID(Hvf.disk_copy)
  io_eff(CID(Hvf.disk_copy), hvf_disk_copy_run);
#endif
#ifdef CID(Hvf.zero_ram)
  io_eff(CID(Hvf.zero_ram), hvf_zero_ram_run);
#endif
#ifdef CID(Hvf.disk_alloc)
  io_eff(CID(Hvf.disk_alloc), hvf_disk_alloc_run);
#endif
#ifdef CID(Hvf.disk_xcopy)
  io_eff(CID(Hvf.disk_xcopy), hvf_disk_xcopy_run);
#endif
#ifdef CID(Hvf.inflate_ram)
  io_eff(CID(Hvf.inflate_ram), hvf_inflate_ram_run);
#endif
#ifdef CID(Hvf.inflate_disk)
  io_eff(CID(Hvf.inflate_disk), hvf_inflate_disk_run);
#endif
}
