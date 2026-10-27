import Base
import ./LAWS.bend as L

# The gate. Each module's proofs live in proofs/<module>.bend; this file
# gathers them. `bend PROOF.bend` prints ALL PROOFS CHECK once every law holds.

import ./proofs/lib.bend as Proofs_lib
import ./proofs/esr.bend as Proofs_esr
import ./proofs/psci.bend as Proofs_psci
import ./proofs/fdt.bend as Proofs_fdt
import ./proofs/pl011.bend as Proofs_pl011
import ./proofs/virtio_mmio.bend as Proofs_virtio_mmio
import ./proofs/virtio_queue.bend as Proofs_virtio_queue
import ./proofs/image.bend as Proofs_image
import ./proofs/layout.bend as Proofs_layout
import ./proofs/dtb.bend as Proofs_dtb
import ./proofs/device.bend as Proofs_device
import ./proofs/rng.bend as Proofs_rng
import ./proofs/blk.bend as Proofs_blk
import ./proofs/machine.bend as Proofs_machine
import ./proofs/pl031.bend as Proofs_pl031
import ./proofs/console.bend as Proofs_console
import ./proofs/wire.bend as Proofs_wire
import ./proofs/dhcp.bend as Proofs_dhcp
import ./proofs/nat.bend as Proofs_nat
import ./proofs/net.bend as Proofs_net
import ./proofs/p9wire.bend as Proofs_p9wire
import ./proofs/p9.bend as Proofs_p9
import ./proofs/snapshot.bend as Proofs_snapshot
import ./proofs/vsock.bend as Proofs_vsock
import ./proofs/input.bend as Proofs_input
import ./proofs/keymap.bend as Proofs_keymap
import ./proofs/pflash.bend as Proofs_pflash
import ./proofs/qcow2.bend as Proofs_qcow2
import ./proofs/escape.bend as Proofs_escape
import ./proofs/addr.bend as Proofs_addr
