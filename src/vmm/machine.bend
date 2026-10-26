import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../arm64/esr.bend as E
import ../arm64/psci.bend as P
import ../dev/pl011.bend as Uart
import ../virtio/device.bend as D
import ./layout.bend as L
import ./abi.bend as V

# The machine: every device model behind the MMIO bus, and the exit handler
# that turns one vCPU exit into a Vm program for the host.
#
# Bus: device 0 is the PL011 at L.Layout.uart_base() (4 KiB); device n+1 is
# virtio slot n at L.Layout.virtio_slot(n) (512 bytes), one per entry of devs.
#
# Machine.on_exit(cpu, m, exit), by exit:
#   Exception: decode with E.Trap.decode(esr, ipa, xt), then by trap:
#     Mmio read:  the device's 32-bit read at the offset; the value is masked
#                 to the access size, then, when sse is set, sign-extended from
#                 size*8 bits to 64 bits (sf) or 32 bits (not sf). It goes to
#                 register srt (VmSetReg) unless srt is 31. Then VmAdvancePc.
#     Mmio write: the device's write of the low 32 bits of value (UART output
#                 goes to VmConsole). Then VmAdvancePc.
#     Mmio at an address no device holds: reads give 0, writes are dropped,
#                 a VmLog line names the access; then VmAdvancePc. Run.
#     After any device access: for each interrupt line whose level changed,
#                 VmIrq(intid, level) (UART L.Layout.uart_intid(), slot n
#                 L.Layout.virtio_intid(n)) and the new level is recorded.
#     MmioNoIsv:  VmLog, Stop{2}.
#     Hvc{0}:     PSCI: P.Psci.decode(x0, x1, x2, x3) then P.Psci.handle(cpu,
#                 ...). VmSetReg(0, result x0). Effects: StartCpu -> VmCpuOn,
#                 Run; StopCpu -> CpuStop; Off -> VmPower(PowerOff),
#                 Stop{0}; Reset -> VmPower(PowerReset), Stop{1}; none ->
#                 Run. The trapped PC already points past an HVC.
#     Hvc{imm}, imm != 0: VmSetReg(0, NOT_SUPPORTED = 2^64 - 1). Run.
#     Smc{_}:     as Hvc{0}, then VmAdvancePc (an SMC trap returns to the SMC).
#     Wfx:        VmAdvancePc, Idle.
#     SysReg:     a read (MRS) sets register rt to 0 unless rt is 31; both
#                 directions VmLog the register; VmAdvancePc. Run.
#     InsnAbort:  VmLog, Stop{3}.
#     Other{ec}:  VmLog, Stop{4}.
#   VtimerActivated, Canceled: Run, no effects.
#   UnknownExit: VmLog, Stop{5}.

type Control is Data:
  Run{}
  # WFI/WFE: the vCPU may sleep until an interrupt or its timer.
  Idle{}
  # PSCI CPU_OFF: this vCPU stops; the VM goes on.
  CpuStop{}
  # The VM stops: 0 power off, 1 reset, 2.. an error the VMM cannot handle.
  Stop{code: U32}

type Machine is Data:
  Machine{psci: P.PsciState, uart: Uart.Pl011, uart_irq: Bool, devs: +List<D.Dev>, dev_irqs: +List<Bool>}

# ncpus CPUs (only CPU 0 on), a fresh UART, one virtio device per kind in
# slot order, every interrupt line low.
def Machine.new(ncpus: Nat, kinds: +List<D.DevKind>) -> Machine:
  ?TODO

def Machine.bus(m: Machine) -> +List<L.Region>:
  ?TODO

# One handled exit: the machine after it and what the vCPU does next.
type Step is Data:
  Step{machine: Machine, control: Control}

def Machine.on_exit(cpu: U32, m: Machine, e: V.RawExit) -> V.Vm<Step>:
  ?TODO

# Bytes typed on the host console: queued in the UART (Uart.Pl011.push_rx),
# then the UART interrupt line is updated as after a device access.
def Machine.input(m: Machine, bytes: +List<U32>) -> V.Vm<Machine>:
  ?TODO
