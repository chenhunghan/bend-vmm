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

def Image.magic() -> U32:
  1682788929   # 0x644d_5241, "ARM\x64"

def Image.old_text_offset() -> U.U64:
  U.U64{0, 524288}   # 0x8_0000

def Image.mib2() -> U32:
  2097152   # 0x20_0000

# The le64 field at byte off of the header.
def Image.field(bs: +List<U32>, off: Nat) -> U.U64:
  B.Bytes.read_le64(B.Bytes.slice(bs, off, 8n))

# A pre-3.17 kernel (image_size 0) loads at text_offset 0x8_0000.
def Image.text_offset(old: Bool, given: U.U64) -> U.U64:
  match old:
    case True{}:
      Image.old_text_offset()
    case False{}:
      given

def Image.when(-A: Data, ok: Bool, x: A) -> Maybe<&2, A>:
  match ok:
    case True{}:
      Some{x}
    case False{}:
      None{}

# The fields of a header of at least 64 bytes.
def Image.parse.fields(+bs: +List<U32>) -> Maybe<&2, ImageInfo>:
  +size +flags = Image.field(bs, 16n) Image.field(bs, 24n)
  magic = B.Bytes.read_le32(B.Bytes.slice(bs, 56n, 4n))
  le = U32.is_zero((U.U64.lo(flags) .&. 1 : U32))
  text = Image.text_offset(U.U64.is_zero(size), Image.field(bs, 8n))
  Image.when(ImageInfo, U32.is_eq(magic, Image.magic()) && le, ImageInfo{text, size, flags})

def Image.parse.go(long: Bool, bs: +List<U32>) -> Maybe<&2, ImageInfo>:
  match long:
    case True{}:
      Image.parse.fields(bs)
    case False{}:
      None{}

# Parses the header; None if shorter than 64 bytes, the magic is wrong or the
# kernel is big-endian.
def Image.parse(header: +List<U32>) -> Maybe<&2, ImageInfo>:
  +header = header
  Image.parse.go(Nat.is_le(64n, List.length(&2, U32, header)), header)

# a + b, or None when the sum wraps past 2^64.
def Image.add(+a: U.U64, b: U.U64) -> Maybe<&2, U.U64>:
  +s = U.U64.add(a, b)
  Image.when(U.U64, U.U64.is_le(a, s), s)

# a rounded up to a multiple of 2^k, or None when that wraps past 2^64.
def Image.align(k: Nat, +a: U.U64) -> Maybe<&2, U.U64>:
  +s = U.U64.align_up(k, a)
  Image.when(U.U64, U.U64.is_le(a, s), s)

def Image.max(+a: U.U64, +b: U.U64) -> U.U64:
  Bool.pick(U.U64, U.U64.is_lt(a, b), b, a)

# Places the kernel, the DTB and the initrd in RAM [ram_base, ram_base+ram_size):
# - kernel at ram_base + text_offset (ram_base is 2 MiB aligned), spanning
#   max(image_size, kernel_len) bytes;
# - the DTB at the first 2 MiB boundary at or after the kernel's end (it must be
#   8-byte aligned and within one 2 MiB region; dtb_len <= 2 MiB);
# - the initrd at the first 4 KiB boundary at or after the end of the DTB's 2 MiB region
#   (initrd_len 0 gives initrd == initrd_end, still placed there).
# None if anything would end past the end of RAM.
#
# Each region ends at or before the start of the next one, so the initrd's end
# bounds them all. Also None when dtb_len > 2 MiB or an address wraps past 2^64.
def Image.layout(ram_base: U.U64, ram_size: U.U64, info: ImageInfo, kernel_len: U32, dtb_len: U32, initrd_len: U32) -> Maybe<&2, Layout>:
  match info:
    case ImageInfo{text_offset, image_size, flags}:
      +ram_base = ram_base
      +dtb_len = dtb_len
      do Maybe<&2, Layout>:
        +ram_end : U.U64 <- Image.add(ram_base, ram_size)
        +kernel : U.U64 <- Image.add(ram_base, text_offset)
        +kernel_end : U.U64 <- Image.add(kernel, Image.max(image_size, U.U64{0, kernel_len}))
        +dtb : U.U64 <- Image.align(21n, kernel_end)
        # dtb + 2 MiB is 2 MiB aligned, so 4 KiB aligned too.
        +initrd : U.U64 <- Image.add(dtb, U.U64{0, Image.mib2()})
        +initrd_end : U.U64 <- Image.add(initrd, U.U64{0, initrd_len})
        ok : Bool = U32.is_le(dtb_len, Image.mib2()) && U.U64.is_le(initrd_end, ram_end)
        Image.when(Layout, ok, Layout{kernel, kernel_end, dtb, initrd, initrd_end})
