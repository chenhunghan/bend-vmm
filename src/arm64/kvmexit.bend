import Base
import ../lib/u64.bend as U
import ../vmm/abi.bend as V
import ./psci.bend as P

# KVM's exits as the machine sees exits (laws/kvmexit.bend): one hypervisor's
# terms for both (host/hvf.c reports KVM's own facts; Hypervisor.framework's
# exits already come as these). The kind is 2000 plus KVM's exit reason; the
# words after it:
#   2006  MMIO: [length, is a write, address (hi, lo), stored value (hi, lo)]
#       -> a data abort (EC 0x24) with a valid syndrome: IL, ISV, the access
#          size (SAS), SF for 8 bytes, WnR for a store, SRT 0; the value as xt
#   2003  a forwarded PSCI call: [is an SMC, X0..X3 (hi, lo each)]
#       -> an HVC (EC 0x16) or SMC (EC 0x17) with IL
#   2024  a PSCI system event (kernels without the SMCCC filter): [its type]
#       -> an HVC of SYSTEM_RESET (KVM_SYSTEM_EVENT_RESET, 2) or SYSTEM_OFF
# Any other kind is an unknown exit.

def KvmExit.mmio_kind() -> U32:
  2006

def KvmExit.call_kind() -> U32:
  2003

def KvmExit.event_kind() -> U32:
  2024

# SAS: 0 byte, 1 halfword, 2 word, 3 doubleword.
def KvmExit.sas(+len: U32) -> U32:
  Bool.pick(U32, U32.is_eq(len, 1), 0, Bool.pick(U32, U32.is_eq(len, 2), 1, Bool.pick(U32, U32.is_eq(len, 4), 2, 3)))

# EC 0x24 << 26 | IL | ISV = 0x93000000.
def KvmExit.mmio_esr(+len: U32, +write: Bool) -> U.U64:
  U.U64{0, (((2466250752 .|. (KvmExit.sas(len) << 22n : U32) : U32) .|. Bool.pick(U32, U32.is_eq(len, 8), 32768, 0) : U32) .|. Bool.pick(U32, write, 64, 0) : U32)}

# EC 0x16 (HVC) or 0x17 (SMC) << 26 | IL.
def KvmExit.call_esr(+smc: Bool) -> U.U64:
  U.U64{0, Bool.pick(U32, smc, 1577058304, 1509949440)}

def KvmExit.zero() -> U.U64:
  U.U64.zero()

def KvmExit.mmio(ws: +List<U32>) -> V.RawExit:
  match ws:
    case Con{+len, Con{wr, Con{ah, Con{al, Con{dh, Con{dl, rest}}}}}}:
      V.Exception{KvmExit.mmio_esr(len, U32.is_ne(wr, 0)), KvmExit.zero(), U.U64{ah, al}, KvmExit.zero(), KvmExit.zero(), KvmExit.zero(), KvmExit.zero(), U.U64{dh, dl}}
    case _:
      V.UnknownExit{4294967295}

def KvmExit.call(ws: +List<U32>) -> V.RawExit:
  match ws:
    case Con{smc, Con{ah, Con{al, Con{bh, Con{bl, Con{ch, Con{cl, Con{dh, Con{dl, rest}}}}}}}}}:
      V.Exception{KvmExit.call_esr(U32.is_ne(smc, 0)), KvmExit.zero(), KvmExit.zero(), U.U64{ah, al}, U.U64{bh, bl}, U.U64{ch, cl}, U.U64{dh, dl}, KvmExit.zero()}
    case _:
      V.UnknownExit{4294967295}

def KvmExit.event(ws: +List<U32>) -> V.RawExit:
  match ws:
    case Con{+t, rest}:
      V.Exception{KvmExit.call_esr(False{}), KvmExit.zero(), KvmExit.zero(), U.U64{0, Bool.pick(U32, U32.is_eq(t, 2), P.Fid.system_reset(), P.Fid.system_off())}, KvmExit.zero(), KvmExit.zero(), KvmExit.zero(), KvmExit.zero()}
    case _:
      V.UnknownExit{4294967295}

def KvmExit.pick_event(hit: Bool, +kind: U32, ws: +List<U32>) -> V.RawExit:
  match hit:
    case True{}:
      KvmExit.event(ws)
    case False{}:
      V.UnknownExit{kind}

def KvmExit.pick_call(hit: Bool, +kind: U32, ws: +List<U32>) -> V.RawExit:
  match hit:
    case True{}:
      KvmExit.call(ws)
    case False{}:
      KvmExit.pick_event(U32.is_eq(kind, KvmExit.event_kind()), kind, ws)

def KvmExit.pick_mmio(hit: Bool, +kind: U32, ws: +List<U32>) -> V.RawExit:
  match hit:
    case True{}:
      KvmExit.mmio(ws)
    case False{}:
      KvmExit.pick_call(U32.is_eq(kind, KvmExit.call_kind()), kind, ws)

# A KVM exit of this kind, from its words.
def KvmExit.decode(+kind: U32, ws: +List<U32>) -> V.RawExit:
  KvmExit.pick_mmio(U32.is_eq(kind, KvmExit.mmio_kind()), kind, ws)
