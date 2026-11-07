import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/snapfile.bend as S

# Spec for src/vmm/snapfile.bend: the snapshot file's layout. The writer's
# plan and the reader's walk agree on every offset; the header round-trips;
# a file past any loader bound is refused on both sides.

def w(x: U32) -> U.U64:
  U.U64{0, x}

# A 2-vCPU VM: RAM at 1 GiB, 512 MiB; 2 bytes of argv; 10 machine words; a
# 64-byte GIC state; vCPU 0 with a 100-byte blob, vCPU 1 with none.
def head() -> S.Head:
  S.Head{1, 2, w(1073741824), w(536870912), w(2)}

def layout() -> S.Layout:
  S.Layout{head(), w(40), w(50), w(10), w(98), w(64), [S.Part{w(170), w(100)}, S.Part{w(278), w(0)}], w(16384)}

# The writer: the header at 0, argv at 40, the word count at 42; the words at 50; the
# GIC length at 90 and its state at 98; vCPU 0's length at 162 and blob at
# 170; vCPU 1's at 270 and 278; RAM at 16 KiB.
law snapfile.plan_example:
  {S.Snapf.plan(1, w(1073741824), w(536870912), w(2), w(10), w(64), [w(100), w(0)])
    == Some{[S.PBytes{w(0), S.Snapf.head_bytes(head())}, S.PArgs{w(40)},
             S.PBytes{w(42), B.Bytes.le64(w(10))}, S.PWords{w(50)}, S.PBytes{w(90), B.Bytes.le64(w(64))}, S.PGic{w(98)},
             S.PBytes{w(162), B.Bytes.le64(w(100))}, S.PCpu{w(170), 0},
             S.PBytes{w(270), B.Bytes.le64(w(0))}, S.PCpu{w(278), 1},
             S.PRam{w(16384)}]}
    : Maybe<&2, +List<S.Piece>>}

law snapfile.head_bytes_length:
  {List.length(&2, U32, S.Snapf.head_bytes(head())) == 40n : Nat}

law snapfile.head_roundtrip:
  {S.Snapf.head(1, S.Snapf.head_bytes(head())) == Some{head()} : Maybe<&2, S.Head>}

# The reader, fed the lengths the writer wrote, reads them where the writer
# put them and finds the writer's layout.
law snapfile.need_words:
  {S.Snapf.need(head(), []) == S.NRead{w(42)} : S.Need}

law snapfile.need_gic:
  {S.Snapf.need(head(), [w(10)]) == S.NRead{w(90)} : S.Need}

law snapfile.need_cpu0:
  {S.Snapf.need(head(), [w(10), w(64)]) == S.NRead{w(162)} : S.Need}

law snapfile.need_cpu1:
  {S.Snapf.need(head(), [w(10), w(64), w(100)]) == S.NRead{w(270)} : S.Need}

law snapfile.need_done:
  {S.Snapf.need(head(), [w(10), w(64), w(100), w(0)]) == S.NDone{layout()} : S.Need}

law snapfile.need_extra:
  {S.Snapf.need(head(), [w(10), w(64), w(100), w(0), w(0)]) == S.NBad{} : S.Need}

law snapfile.fits_exact:
  {S.Snapf.fits(layout(), w(536887296)) == True{} : Bool}

law snapfile.fits_short:
  {S.Snapf.fits(layout(), w(536887295)) == False{} : Bool}

# Bounds: what a loader refuses, the writer does not write.
law snapfile.need_words_too_many:
  {S.Snapf.need(head(), [w(67108865)]) == S.NBad{} : S.Need}

law snapfile.need_words_most:
  {S.Snapf.need(head(), [w(67108864)]) == S.NRead{w(268435506)} : S.Need}

law snapfile.need_gic_too_big:
  {S.Snapf.need(head(), [w(10), w(16777217)]) == S.NBad{} : S.Need}

law snapfile.need_cpu_too_big:
  {S.Snapf.need(head(), [w(10), w(64), w(1048577)]) == S.NBad{} : S.Need}

law snapfile.need_words_huge:
  {S.Snapf.need(head(), [U.U64{1, 0}]) == S.NBad{} : S.Need}

law snapfile.plan_words_too_many:
  {S.Snapf.plan(1, w(0), w(536870912), w(2), w(67108865), w(64), [w(100)]) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_gic_too_big:
  {S.Snapf.plan(1, w(0), w(536870912), w(2), w(10), w(16777217), [w(100)]) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_cpu_too_big:
  {S.Snapf.plan(1, w(0), w(536870912), w(2), w(10), w(64), [w(0), w(1048577)]) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_zero_ram:
  {S.Snapf.plan(1, w(0), w(0), w(2), w(10), w(64), [w(100)]) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_too_many_cpus:
  {S.Snapf.plan(1, w(0), w(536870912), w(2), w(10), w(64), List.replicate(U.U64, 65n, w(0))) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.head_bad_magic:
  {S.Snapf.head(1, List.set(&2, U32, S.Snapf.head_bytes(head()), 0n, 67)) == None{} : Maybe<&2, S.Head>}

law snapfile.head_other_hypervisor:
  {S.Snapf.head(2, S.Snapf.head_bytes(head())) == None{} : Maybe<&2, S.Head>}

law snapfile.head_too_many_cpus:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 65, w(0), w(536870912), w(2)})) == None{} : Maybe<&2, S.Head>}

law snapfile.head_zero_ram:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 2, w(0), w(0), w(2)})) == None{} : Maybe<&2, S.Head>}

law snapfile.head_ram_too_big:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 2, w(0), U.U64{256, 1}, w(2)})) == None{} : Maybe<&2, S.Head>}

law snapfile.head_args_too_long:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 2, w(0), w(536870912), w(1048577)})) == None{} : Maybe<&2, S.Head>}

law snapfile.head_short:
  {S.Snapf.head(1, List.take(&2, U32, S.Snapf.head_bytes(head()), 39n)) == None{} : Maybe<&2, S.Head>}

# The host's load: RAM base, size and offset, argv, words, GIC (hi, lo
# each), then the vCPUs' parts.
law snapfile.load_wire:
  {S.Snapf.load.wire(layout()) == [0, 1073741824, 0, 536870912, 0, 16384, 0, 40, 0, 2, 0, 50, 0, 40, 0, 98, 0, 64, 2, 0, 170, 0, 100, 0, 278, 0, 0] : +List<U32>}

law snapfile.piece_wire:
  {S.Snapf.pieces.wire([S.PBytes{w(90), [1, 2]}, S.PWords{w(50)}, S.PGic{w(98)}, S.PCpu{U.U64{1, 2}, 3}, S.PRam{w(16384)}, S.PArgs{w(40)}])
    == [0, 0, 90, 2, 1, 2, 1, 0, 50, 2, 0, 98, 3, 1, 2, 3, 4, 0, 16384, 5, 0, 40] : +List<U32>}

# The host's sizes, as Hvf.snap_save answers them, give the same plan.
law snapfile.plan_of_sizes:
  {S.Snapf.plan_of([1, 0, 1073741824, 0, 536870912, 0, 2, 0, 10, 0, 64, 2, 0, 100, 0, 0])
    == S.Snapf.plan(1, w(1073741824), w(536870912), w(2), w(10), w(64), [w(100), w(0)]) : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_of_short:
  {S.Snapf.plan_of([1, 0, 1073741824, 0, 536870912, 0, 2, 0, 10, 0, 64, 2, 0, 100]) == None{} : Maybe<&2, +List<S.Piece>>}

# Proposed: bounds at their limits are accepted, and a stray word in the
# host's sizes is refused (review of a6fba53).

law snapfile.head_at_limits:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 64, w(0), U.U64{256, 0}, w(1048576)})) == Some{S.Head{1, 64, w(0), U.U64{256, 0}, w(1048576)}} : Maybe<&2, S.Head>}

law snapfile.head_ram_one:
  {S.Snapf.head(1, S.Snapf.head_bytes(S.Head{1, 1, w(0), w(1), w(0)})) == Some{S.Head{1, 1, w(0), w(1), w(0)}} : Maybe<&2, S.Head>}

law snapfile.need_gic_most:
  {S.Snapf.need(head(), [w(10), w(16777216)]) == S.NRead{w(16777314)} : S.Need}

law snapfile.need_cpu_most:
  {S.Snapf.need(head(), [w(10), w(64), w(1048576)]) == S.NRead{w(1048746)} : S.Need}

law snapfile.plan_of_stray_word:
  {S.Snapf.plan_of([1, 0, 1073741824, 0, 536870912, 0, 2, 0, 10, 0, 64, 2, 0, 100, 0, 0, 7]) == None{} : Maybe<&2, +List<S.Piece>>}

law snapfile.plan_of_none_cpus:
  {S.Snapf.plan_of([1, 0, 1073741824, 0, 536870912, 0, 2, 0, 10, 0, 64, 0]) == S.Snapf.plan(1, w(1073741824), w(536870912), w(2), w(10), w(64), []) : Maybe<&2, +List<S.Piece>>}

# Proposed: the header must describe the machine the snapshot's command
# line makes (review of a6fba53).

law snapfile.agrees:
  {S.Snapf.agrees(layout(), w(1073741824), 512, 2) == True{} : Bool}

law snapfile.agrees_fewer_cpus_started:
  {S.Snapf.agrees(layout(), w(1073741824), 512, 4) == True{} : Bool}

law snapfile.agrees_too_many_cpus:
  {S.Snapf.agrees(layout(), w(1073741824), 512, 1) == False{} : Bool}

law snapfile.agrees_other_ram:
  {S.Snapf.agrees(layout(), w(1073741824), 1024, 2) == False{} : Bool}

law snapfile.agrees_other_base:
  {S.Snapf.agrees(layout(), w(0), 512, 2) == False{} : Bool}
