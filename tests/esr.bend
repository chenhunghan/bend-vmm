import Base
import ../src/lib/u64.bend as U
import ../src/arm64/esr.bend as E
import ./t.bend as T

# Tests for src/arm64/esr.bend beyond its laws. Each syndrome is decimal with
# its hex in the comment.

def b(x: Bool) -> String:
  match x:
    case True{}:
      "T"
    case False{}:
      "F"

def h(a: U.U64) -> String:
  U.U64.show_hex(a)

def u(x: U32) -> String:
  U32.show(x)

def show(t: E.Trap) -> String:
  match t:
    case E.Mmio{ipa, w, size, srt, value, sse, sf}:
      "Mmio " ++ h(ipa) ++ " w=" ++ b(w) ++ " size=" ++ u(size) ++ " srt=" ++ u(srt) ++ " value=" ++ h(value) ++ " sse=" ++ b(sse) ++ " sf=" ++ b(sf)
    case E.MmioNoIsv{ipa}:
      "MmioNoIsv " ++ h(ipa)
    case E.Hvc{imm}:
      "Hvc " ++ u(imm)
    case E.Smc{imm}:
      "Smc " ++ u(imm)
    case E.Wfx{wfe}:
      "Wfx " ++ b(wfe)
    case E.SysReg{op0, op1, crn, crm, op2, rt, read}:
      "SysReg " ++ u(op0) ++ " " ++ u(op1) ++ " " ++ u(crn) ++ " " ++ u(crm) ++ " " ++ u(op2) ++ " rt=" ++ u(rt) ++ " read=" ++ b(read)
    case E.InsnAbort{ipa}:
      "InsnAbort " ++ h(ipa)
    case E.Other{ec}:
      "Other " ++ u(ec)

def dec(esr: U32, ipa: U32, xt: U.U64) -> String:
  show(E.Trap.decode(U.U64{0, esr}, U.U64{0, ipa}, xt))

# x = 0x1122334455667788
def x() -> U.U64:
  U.U64{287454020, 1432778632}

def main() -> IO(Unit):
  do IO<Unit>:
    # Field extraction.
    T.eq_u32("ec dabt", E.Esr.ec(U.U64{0, 2474704960}), 36)
    T.eq_u32("ec all ones", E.Esr.ec(U.U64{4294967295, 4294967295}), 63)
    T.eq_u32("ec ignores IL and ISS", E.Esr.ec(U.U64{0, 67108863}), 0)
    T.eq_u32("iss drops IL and EC", E.Esr.iss(U.U64{4294967295, 4294967295}), 33554431)
    # HVC / SMC: imm is ISS[15:0]; other ISS bits are ignored.
    # 0x5A00FFFF
    T.eq_str("hvc max imm", dec(1510014975, 0, x()), "Hvc 65535")
    # 0x5A01FFFF: ISS bit 16 set
    T.eq_str("hvc imm masks iss", dec(1510080511, 0, x()), "Hvc 65535")
    # 0x5E000001
    T.eq_str("smc 1", dec(1577058305, 0, x()), "Smc 1")
    # 0x16000000: HVC from AArch32 is not handled
    T.eq_str("hvc32 other", dec(369098752, 0, x()), "Other 5")
    # WFx: TI[1:0]; WFIT (2) is a WFI, WFET (3) a WFE.
    # 0x06000002
    T.eq_str("wfit", dec(100663298, 0, x()), "Wfx F")
    # 0x06000003
    T.eq_str("wfet", dec(100663299, 0, x()), "Wfx T")
    # 0x04000001: 16-bit instruction (IL clear)
    T.eq_str("wfe il0", dec(67108865, 0, x()), "Wfx T")
    # Data aborts: store sizes truncate xt.
    # 0x93000040: strb w0 (SAS 0, SRT 0, WnR)
    T.eq_str("store8", dec(2466250816, 4096, x()), "Mmio 0x1000 w=T size=1 srt=0 value=0x88 sse=F sf=F")
    # 0x93410040: strh w1 (SAS 1, SRT 1)
    T.eq_str("store16", dec(2470510656, 4096, x()), "Mmio 0x1000 w=T size=2 srt=1 value=0x7788 sse=F sf=F")
    # 0x93C48040: str x4 (SAS 3, SRT 4, SF, WnR)
    T.eq_str("store64", dec(2479128640, 4096, x()), "Mmio 0x1000 w=T size=8 srt=4 value=0x1122334455667788 sse=F sf=T")
    # 0x93DF8040: str xzr (SRT 31) stores zero whatever xt holds
    T.eq_str("store xzr", dec(2480898112, 4096, x()), "Mmio 0x1000 w=T size=8 srt=31 value=0x0 sse=F sf=T")
    # 0x93610000: ldrsh w1 (SAS 1, SSE, SRT 1): read value is zero
    T.eq_str("load16 signed", dec(2472607744, 4096, x()), "Mmio 0x1000 w=F size=2 srt=1 value=0x0 sse=T sf=F")
    # 0x93E38000: SAS 3, SSE, SRT 3, SF
    T.eq_str("load sse sf", dec(2481160192, 4096, x()), "Mmio 0x1000 w=F size=8 srt=3 value=0x0 sse=T sf=T")
    # ipa high word is kept: 0x93810040 at IPA 0x1_0000_2000
    T.eq_str("ipa high", show(E.Trap.decode(U.U64{0, 2474704960}, U.U64{1, 8192}, x())), "Mmio 0x100002000 w=T size=4 srt=1 value=0x55667788 sse=F sf=F")
    # 0x92000000: no ISV, read
    T.eq_str("no isv read", dec(2449473536, 8192, x()), "MmioNoIsv 0x2000")
    # 0x96000040: data abort from the same EL is not a guest exit
    T.eq_str("dabt same el", dec(2516582464, 4096, x()), "Other 37")
    # 0x86000000: instruction abort from the same EL
    T.eq_str("iabt same el", dec(2248146944, 4096, x()), "Other 33")
    # 0x82000000 with the ESR high word set: still an instruction abort
    T.eq_str("iabt high word", show(E.Trap.decode(U.U64{5, 2181038080}, U.U64{0, 12288}, x())), "InsnAbort 0x3000")
    # Sysreg: MSR CNTV_CTL_EL0, x2 = op0 3 op1 3 CRn 14 CRm 3 op2 1, write:
    # ISS = 3<<20 | 1<<17 | 3<<14 | 14<<10 | 2<<5 | 3<<1 = 0x32F846 -> 0x6232F846
    T.eq_str("sysreg msr", dec(1647507526, 0, x()), "SysReg 3 3 14 3 1 rt=2 read=F")
    # All fields at their maximum: ISS = 0x3FFFFF -> 0x623FFFFF
    T.eq_str("sysreg max", dec(1648361471, 0, x()), "SysReg 3 7 15 15 7 rt=31 read=T")
    T.eq_str("ec zero", dec(0, 0, x()), "Other 0")
    T.eq_str("ec max", dec(4227858432, 0, x()), "Other 63")
