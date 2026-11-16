import Base
import ../src/lib/u64.bend as U
import ../src/x86/layout.bend as X

# Spec for src/x86/layout.bend: the x86_64 guest's memory map and lines.

# Proposed: (a new module; every law here is proposed)

law x86layout.low_2g:
  {X.X86.low_size(U.U64{0, 2147483648}) == U.U64{0, 2147483648} : U.U64}

law x86layout.low_4g:
  {X.X86.low_size(U.U64{1, 0}) == U.U64{0, 3221225472} : U.U64}

law x86layout.high_4g:
  {X.X86.high_size(U.U64{1, 0}) == U.U64{0, 1073741824} : U.U64}

law x86layout.high_none:
  {X.X86.high_size(U.U64{0, 2147483648}) == U.U64{0, 0} : U.U64}

# virtio slot 3 (0xD000_0600) on the machine's bus (0x0A00_0600)
law x86layout.to_bus_slot3:
  {X.X86.to_bus(U.U64{0, 3489662464}) == U.U64{0, 167773696} : U.U64}

# past the last slot: no device
law x86layout.to_bus_outside:
  {X.X86.to_bus(U.U64{0, 3489677312}) == U.U64{0, 0} : U.U64}

law x86layout.to_bus_below:
  {X.X86.to_bus(U.U64{0, 3489660927}) == U.U64{0, 0} : U.U64}

law x86layout.gsi_uart:
  {X.X86.gsi_at(33) == 4 : U32}

law x86layout.gsi_slot0:
  {X.X86.gsi_at(48) == 5 : U32}

law x86layout.gsi_slot3:
  {X.X86.gsi_at(51) == 10 : U32}

law x86layout.gsi_slot16:
  {X.X86.gsi_at(64) == 23 : U32}

law x86layout.gsi_slot17_none:
  {X.X86.gsi_at(65) == 255 : U32}

law x86layout.gsi_rtc_none:
  {X.X86.gsi_at(34) == 255 : U32}

law x86layout.lines:
  {X.X86.slots_with_lines() == 17 : U32}
