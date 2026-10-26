import Base
import ../src/lib/u64.bend as U
import ../src/virtio/device.bend as D
import ../src/vmm/layout.bend as L
import ../src/vmm/machine.bend as M
import ../src/vmm/abi.bend as V

# Frozen spec for src/vmm/machine.bend (exit handling is pinned by the
# FROZEN SPEC test tests/machine.bend on the simulator).

def w(x: U32) -> U.U64:
  U.U64{0, x}

law machine.bus:
  {M.Machine.bus(M.Machine.new(1n, [D.RngKind{}, D.BlkKind{0, w(8)}])) == [L.Region{w(150994944), w(4096), 0}, L.Region{w(167772160), w(512), 1}, L.Region{w(167772672), w(512), 2}] : +List<L.Region>}

law machine.bus_no_virtio:
  {M.Machine.bus(M.Machine.new(1n, [])) == [L.Region{w(150994944), w(4096), 0}] : +List<L.Region>}

# Proposed: a timer or a forced exit changes nothing and lets the vCPU run.
law machine.vtimer_runs:
  for cpu: U32
  for m: M.Machine
  {M.Machine.on_exit(cpu, m, V.VtimerActivated{}) == V.VmRet{M.Step{m, M.Run{}}} : V.Vm<M.Step>}

law machine.canceled_runs:
  for cpu: U32
  for m: M.Machine
  {M.Machine.on_exit(cpu, m, V.Canceled{}) == V.VmRet{M.Step{m, M.Run{}}} : V.Vm<M.Step>}
