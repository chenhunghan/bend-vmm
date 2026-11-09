import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/arm64/kvmexit.bend as K

# Spec for src/arm64/kvmexit.bend: KVM's exits in the machine's terms.

def z() -> U.U64:
  U.U64{0, 0}

# A 4-byte store of 0x12345678 (305419896) to 0x9000000 (150994944): EC 0x24,
# IL, ISV, SAS 2, WnR (0x93800040 = 2474639424); the value as xt.
law kvmexit.mmio_store:
  {K.KvmExit.decode(2006, [4, 1, 0, 150994944, 0, 305419896]) == V.Exception{U.U64{0, 2474639424}, z(), U.U64{0, 150994944}, z(), z(), z(), z(), U.U64{0, 305419896}} : V.RawExit}

# An 8-byte load: SAS 3 and SF, no WnR (0x93c08000 = 2478866432), xt zero.
law kvmexit.mmio_load64:
  {K.KvmExit.decode(2006, [8, 0, 1, 0, 0, 0]) == V.Exception{U.U64{0, 2478866432}, z(), U.U64{1, 0}, z(), z(), z(), z(), z()} : V.RawExit}

# A byte load: SAS 0 (0x93000000 = 2466250752).
law kvmexit.mmio_byte:
  {K.KvmExit.decode(2006, [1, 0, 0, 4096, 0, 0]) == V.Exception{U.U64{0, 2466250752}, z(), U.U64{0, 4096}, z(), z(), z(), z(), z()} : V.RawExit}

# An HVC (EC 0x16, IL: 0x5a000000 = 1509949440) with its X0..X3.
law kvmexit.hvc:
  {K.KvmExit.decode(2003, [0, 0, 2214592515, 0, 1, 0, 2, 0, 3]) == V.Exception{U.U64{0, 1509949440}, z(), z(), U.U64{0, 2214592515}, U.U64{0, 1}, U.U64{0, 2}, U.U64{0, 3}, z()} : V.RawExit}

# An SMC (EC 0x17, IL: 0x5e000000 = 1577058304).
law kvmexit.smc:
  {K.KvmExit.decode(2003, [1, 0, 2214592512, 0, 0, 0, 0, 0, 0]) == V.Exception{U.U64{0, 1577058304}, z(), z(), U.U64{0, 2214592512}, z(), z(), z(), z()} : V.RawExit}

# KVM_SYSTEM_EVENT_RESET (2) is an HVC of SYSTEM_RESET (0x84000009).
law kvmexit.reset:
  {K.KvmExit.decode(2024, [2]) == V.Exception{U.U64{0, 1509949440}, z(), z(), U.U64{0, 2214592521}, z(), z(), z(), z()} : V.RawExit}

# Any other event (KVM_SYSTEM_EVENT_SHUTDOWN, 1) is an HVC of SYSTEM_OFF
# (0x84000008).
law kvmexit.shutdown:
  {K.KvmExit.decode(2024, [1]) == V.Exception{U.U64{0, 1509949440}, z(), z(), U.U64{0, 2214592520}, z(), z(), z(), z()} : V.RawExit}

# Another kind is unknown, as is a short record.
law kvmexit.unknown:
  {K.KvmExit.decode(2010, []) == V.UnknownExit{2010} : V.RawExit}

law kvmexit.short:
  {K.KvmExit.decode(2006, [4, 1]) == V.UnknownExit{4294967295} : V.RawExit}
