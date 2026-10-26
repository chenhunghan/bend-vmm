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
