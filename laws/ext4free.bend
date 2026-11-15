import Base
import ../src/lib/u64.bend as U
import ../src/disk/ext4free.bend as E

# Spec for src/disk/ext4free.bend: an ext4 file system's free space, for
# bend-vmm sparsify.

# A bitmap's clear bits are free blocks: runs of them, newest first, from
# the group's first block.
law ext4free.runs_low_half:
  {E.Ext.runs([240], 8, 100) == [E.Run{100, 4}] : +List<E.Run>}

law ext4free.runs_across_bytes:
  {E.Ext.runs([0, 255, 0], 24, 0) == [E.Run{16, 8}, E.Run{0, 8}] : +List<E.Run>}

# Only the first n bits count (the last group may be short).
law ext4free.runs_cut:
  {E.Ext.runs([5], 3, 10) == [E.Run{11, 1}] : +List<E.Run>}

law ext4free.runs_none:
  {E.Ext.runs([255], 8, 0) == [] : +List<E.Run>}

# A run as the whole 4 KiB blocks inside it: 1 KiB blocks 1..7 give the
# block at 4096 alone.
law ext4free.range_whole_blocks:
  {E.Fs.range(E.Fs{U.U64{0, 0}, 0, 8192, 1, 8192, 1, 32, True{}}, E.Run{1, 7}) == (U.U64{0, 4096}, U.U64{0, 4096}) : U.U64 & U.U64}

law ext4free.range_none:
  {E.Fs.range(E.Fs{U.U64{0, 0}, 0, 8192, 1, 8192, 1, 32, True{}}, E.Run{1, 2}) == (U.U64{0, 4096}, U.U64{0, 0}) : U.U64 & U.U64}

# An MBR's partition (type 0x83 at sector 2048) at 1 MiB; a GPT's
# protective MBR lists none itself.
law ext4free.mbr:
  {E.Part.mbr(List.append(&2, U32, List.replicate(U32, 446n, 0), List.append(&2, U32, [0, 0, 0, 0, 131, 0, 0, 0, 0, 8, 0, 0, 0, 0, 1, 0], List.append(&2, U32, List.replicate(U32, 48n, 0), [85, 170])))) == [U.U64{0, 1048576}] : +List<U.U64>}

law ext4free.gpt_protective:
  {E.Part.mbr(List.append(&2, U32, List.replicate(U32, 446n, 0), List.append(&2, U32, [0, 0, 0, 0, 238, 0, 0, 0, 1, 0, 0, 0, 255, 255, 255, 255], List.append(&2, U32, List.replicate(U32, 48n, 0), [85, 170])))) == [] : +List<U.U64>}
