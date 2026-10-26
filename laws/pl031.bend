import Base
import ../src/dev/pl031.bend as R

# Frozen spec for src/dev/pl031.bend. now is the host clock in seconds.

def val(r: R.Pl031 & U32) -> U32:
  match r:
    case (s, v):
      v

def rd(s: R.Pl031, off: U32, now: U32) -> U32:
  val(R.Pl031.read(s, off, now))

law pl031.dr_is_now:
  {rd(R.Pl031.new(), 0, 1700000000) == 1700000000 : U32}

law pl031.lr_sets_time:
  # set to 100 at host time 1000, read at host time 1005
  {rd(R.Pl031.write(R.Pl031.new(), 8, 100, 1000), 0, 1005) == 105 : U32}

law pl031.lr_reads_back:
  {rd(R.Pl031.write(R.Pl031.new(), 8, 100, 1000), 8, 2000) == 100 : U32}

law pl031.cr_running:
  {rd(R.Pl031.new(), 12, 5) == 1 : U32}

law pl031.mr_roundtrip:
  {rd(R.Pl031.write(R.Pl031.new(), 4, 77, 0), 4, 0) == 77 : U32}

law pl031.periph_id0:
  {rd(R.Pl031.new(), 4064, 0) == 49 : U32}

law pl031.cell_id1:
  {rd(R.Pl031.new(), 4084, 0) == 240 : U32}

law pl031.no_irq_masked:
  {R.Pl031.irq(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 20) == False{} : Bool}

law pl031.irq_on_match:
  {R.Pl031.irq(R.Pl031.write(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 16, 1, 0), 20) == True{} : Bool}

law pl031.no_irq_before_match:
  {R.Pl031.irq(R.Pl031.write(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 16, 1, 0), 5) == False{} : Bool}

law pl031.unknown_reads_zero:
  {rd(R.Pl031.new(), 32, 9) == 0 : U32}

# Proposed:

law pl031.icr_clears_irq:
  # alarm at 10, unmasked, acknowledged at 20: the line stays low after
  {R.Pl031.irq(R.Pl031.write(R.Pl031.write(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 16, 1, 0), 28, 1, 20), 30) == False{} : Bool}

law pl031.mr_rearms:
  # after the acknowledgement, a new MR of 40 fires at 40
  {R.Pl031.irq(R.Pl031.write(R.Pl031.write(R.Pl031.write(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 16, 1, 0), 28, 1, 20), 4, 40, 21), 40) == True{} : Bool}

law pl031.ris_latches:
  # RIS stays set after the time moves back below MR
  {rd(R.Pl031.write(R.Pl031.write(R.Pl031.new(), 4, 10, 0), 8, 0, 20), 20, 21) == 1 : U32}
