import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ./hvf.bend as H

# Host smoke test: boots a bare-metal payload (tests/guest/hello.S) on one
# vCPU with just enough exit handling to print its UART stores and stop at
# PSCI SYSTEM_OFF. It exercises every host effect without the pure machine,
# so a host regression shows up apart from a device bug.
#   usage: smoke <payload.bin>

def ram() -> U.U64:
  U.U64{0, 1073741824}

def char_of(x: U.U64) -> String:
  SCon{Char.from_u32((U.U64.lo(x) .&. 255 : U32)), SNil{}}

# Past the trapped store (on KVM the completed MMIO access already moves it).
def advance(+cpu: U32) -> IO(U32):
  H.Host.advance_pc(cpu)

# What one exception exit means here: 0 keep going, 1 powered off, 2 unknown.
def on_exception.pick(dabt: Bool, hvc: Bool, x0: U.U64, xt: U.U64) -> IO(U32):
  match dabt hvc:
    case True{} _:
      do IO<U32>:
        IO.write(char_of(xt))
        _ : U32 <- advance(0)
        return 0
    case False{} True{}:
      # HVC: the trapped PC already points past it
      IO.pure(U32, Bool.pick(U32, U.U64.is_eq(x0, U.U64{0, 2214592520}), 1, 0))
    case False{} False{}:
      IO.pure(U32, 2)

def on_exception(+ec: U32, x0: U.U64, xt: U.U64) -> IO(U32):
  on_exception.pick(U32.is_eq(ec, 36), U32.is_eq(ec, 22), x0, xt)

def step(e: V.RawExit) -> IO(U32):
  match e:
    case V.Exception{+esr, far, ipa, x0, x1, x2, x3, xt}:
      on_exception(U.U64.bits(esr, 26n, 6n), x0, xt)
    case V.VtimerActivated{}:
      IO.pure(U32, 0)
    case V.Canceled{}:
      IO.pure(U32, 0)
    case V.UnknownExit{r}:
      do IO<U32>:
        IO.print_err("unknown exit " ++ U32.show(r))
        return 2

# Runs exits until one is not "keep going", for at most fuel exits.
def loop(fuel: Nat, go: Bool, last: U32) -> IO(U32):
  match fuel go:
    case _ False{}:
      IO.pure(U32, last)
    case 0n True{}:
      do IO<U32>:
        IO.print_err("smoke: out of exits")
        return 3
    case 1n+p True{}:
      do IO<U32>:
        e : V.RawExit <- H.Host.run(0)
        +r : U32 <- step(e)
        loop(p, U32.is_zero(r), r)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    path : String = Maybe.default(&1, String, List.get(&1, String, args, 1n), "tests/guest/hello.bin")
    rc : U32 <- H.Host.vm_init(64, U.U64{0, 134217728}, U.U64{0, 201326592}, ram(), 1)
    IO.print_err("vm_init " ++ U32.show(rc))
    n : U32 <- H.Host.load(path, ram())
    IO.print_err("loaded " ++ U32.show(n) ++ " bytes")
    c : U32 <- H.Host.vcpu_create(0)
    _ : U32 <- H.Host.set_reg(0, V.Reg.pc(), ram())
    _ : U32 <- H.Host.set_reg(0, H.Reg.cpsr(), U.U64{0, 965})
    IO.print_err("vcpu " ++ U32.show(c))
    r : U32 <- loop(64n, True{}, 0)
    IO.print_err("smoke: done " ++ U32.show(r))
