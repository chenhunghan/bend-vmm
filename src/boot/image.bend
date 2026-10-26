import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# Booting an arm64 Linux kernel Image directly (Linux
# Documentation/arch/arm64/booting.rst). The Image starts with a 64-byte
# little-endian header:
#   0  code0 u32      4  code1 u32     8  text_offset u64
#   16 image_size u64 24 flags u64     32 res2 u64  40 res3 u64  48 res4 u64
#   56 magic u32 = 1682788929 (0x644d5241, "ARM\x64")     60 res5 u32
# An image_size of 0 means a kernel older than 3.17: text_offset is then
# 524288 (0x80000) and the image size is unknown (use the file length).
# Flags bit 0 is endianness (must be 0: little-endian).

type ImageInfo is Data:
  ImageInfo{text_offset: U.U64, image_size: U.U64, flags: U.U64}

# Where everything goes in guest RAM.
type Layout is Data:
  Layout{kernel: U.U64, kernel_end: U.U64, dtb: U.U64, initrd: U.U64, initrd_end: U.U64}

# Parses the header; None if shorter than 64 bytes, the magic is wrong or the
# kernel is big-endian.
def Image.parse(header: +List<U32>) -> Maybe<&2, ImageInfo>:
  ?TODO

# Places the kernel, the DTB and the initrd in RAM [ram_base, ram_base+ram_size):
# - kernel at ram_base + text_offset (ram_base is 2 MiB aligned), spanning
#   max(image_size, kernel_len) bytes;
# - the DTB at the first 2 MiB boundary at or after the kernel's end (it must be
#   8-byte aligned and within one 2 MiB region; dtb_len <= 2 MiB);
# - the initrd at the first 4 KiB boundary at or after the end of the DTB's 2 MiB region
#   (initrd_len 0 gives initrd == initrd_end, still placed there).
# None if anything would end past the end of RAM.
def Image.layout(ram_base: U.U64, ram_size: U.U64, info: ImageInfo, kernel_len: U32, dtb_len: U32, initrd_len: U32) -> Maybe<&2, Layout>:
  ?TODO
