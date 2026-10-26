import Base

# The project's spec. Each module's laws live in laws/<module>.bend; this file
# gathers them. Laws are architect-owned: agents never edit an existing law.

import ./laws/lib.bend as Laws_lib
import ./laws/esr.bend as Laws_esr
import ./laws/psci.bend as Laws_psci
import ./laws/fdt.bend as Laws_fdt
import ./laws/pl011.bend as Laws_pl011
import ./laws/virtio_mmio.bend as Laws_virtio_mmio
import ./laws/virtio_queue.bend as Laws_virtio_queue
import ./laws/image.bend as Laws_image
import ./laws/layout.bend as Laws_layout
import ./laws/dtb.bend as Laws_dtb
import ./laws/device.bend as Laws_device
import ./laws/rng.bend as Laws_rng
import ./laws/blk.bend as Laws_blk
import ./laws/machine.bend as Laws_machine
import ./laws/pl031.bend as Laws_pl031
import ./laws/console.bend as Laws_console
import ./laws/wire.bend as Laws_wire
import ./laws/dhcp.bend as Laws_dhcp
import ./laws/nat.bend as Laws_nat
import ./laws/net.bend as Laws_net
import ./laws/p9wire.bend as Laws_p9wire
import ./laws/p9.bend as Laws_p9
import ./laws/snapshot.bend as Laws_snapshot
import ./laws/vsock.bend as Laws_vsock
import ./laws/input.bend as Laws_input
import ./laws/keymap.bend as Laws_keymap
import ./laws/pflash.bend as Laws_pflash
