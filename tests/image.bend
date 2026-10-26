import Base
import ../src/lib/u64.bend as U
import ../src/boot/image.bend as I
import ./t.bend as T

# Tests for src/boot/image.bend beyond its laws. Addresses are decimal with
# their hex in the comments.

def h(a: U.U64) -> String:
  U.U64.show_hex(a)

def w(x: U32) -> U.U64:
  U.U64{0, x}

def show_info(m: Maybe<&2, I.ImageInfo>) -> String:
  match m:
    case None{}:
      "None"
    case Some{I.ImageInfo{t, s, f}}:
      "text_offset=" ++ h(t) ++ " image_size=" ++ h(s) ++ " flags=" ++ h(f)

def show_layout(m: Maybe<&2, I.Layout>) -> String:
  match m:
    case None{}:
      "None"
    case Some{I.Layout{k, ke, d, i, ie}}:
      "kernel=" ++ h(k) ++ " kernel_end=" ++ h(ke) ++ " dtb=" ++ h(d) ++ " initrd=" ++ h(i) ++ " initrd_end=" ++ h(ie)

def z8() -> +List<U32>:
  [0, 0, 0, 0, 0, 0, 0, 0]

# A header: the le64 fields at 8, 16 and 24 given as byte lists of 8.
def hdr(text: +List<U32>, size: +List<U32>, flags: +List<U32>) -> +List<U32>:
  rest = List.append(&2, U32, z8(), List.append(&2, U32, z8(), List.append(&2, U32, z8(), [65, 82, 77, 100, 0, 0, 0, 0])))
  List.append(&2, U32, [77, 90, 0, 145, 0, 0, 0, 0], List.append(&2, U32, text, List.append(&2, U32, size, List.append(&2, U32, flags, rest))))

# 32 MiB (0x200_0000)
def mib32() -> +List<U32>:
  [0, 0, 0, 2, 0, 0, 0, 0]

def parse(name: String, bs: +List<U32>, want: String) -> IO(Unit):
  T.eq_str(name, show_info(I.Image.parse(bs)), want)

def lay(name: String, base: U.U64, size: U.U64, info: I.ImageInfo, k: U32, d: U32, i: U32, want: String) -> IO(Unit):
  T.eq_str(name, show_layout(I.Image.layout(base, size, info, k, d, i)), want)

# text_offset 0, image_size 32 MiB, flags 10
def info() -> I.ImageInfo:
  I.ImageInfo{w(0), w(33554432), w(10)}

def main() -> IO(Unit):
  do IO<Unit>:
    # Parsing.
    parse("parse empty", [], "None")
    parse("parse 63 bytes", List.take(&2, U32, hdr(z8(), mib32(), z8()), 63n), "None")
    parse("parse 64 bytes", hdr(z8(), mib32(), z8()), "text_offset=0x0 image_size=0x2000000 flags=0x0")
    parse("parse ignores bytes after the header", List.append(&2, U32, hdr(z8(), mib32(), z8()), [1, 2, 3]), "text_offset=0x0 image_size=0x2000000 flags=0x0")
    # text_offset 0x8_0000 with a real image_size is kept as given.
    parse("parse text_offset", hdr([0, 0, 8, 0, 0, 0, 0, 0], mib32(), z8()), "text_offset=0x80000 image_size=0x2000000 flags=0x0")
    # All eight bytes of each field count, little-endian.
    parse("parse le64 fields", hdr([1, 2, 3, 4, 5, 6, 7, 8], [17, 18, 19, 20, 21, 22, 23, 24], [14, 0, 0, 0, 0, 0, 0, 128]), "text_offset=0x807060504030201 image_size=0x1817161514131211 flags=0x800000000000000e")
    # Bits other than bit 0 do not make the kernel big-endian.
    parse("parse flags bit 1..63", hdr(z8(), mib32(), [254, 255, 255, 255, 255, 255, 255, 255]), "text_offset=0x0 image_size=0x2000000 flags=0xfffffffffffffffe")
    parse("parse big-endian, other bits set", hdr(z8(), mib32(), [15, 0, 0, 0, 0, 0, 0, 0]), "None")
    # Only the low 32 bits of image_size zero is not a pre-3.17 kernel.
    parse("parse image_size 4 GiB", hdr([0, 0, 1, 0, 0, 0, 0, 0], [0, 0, 0, 0, 1, 0, 0, 0], z8()), "text_offset=0x10000 image_size=0x100000000 flags=0x0")
    # image_size 0 ignores the stored text_offset.
    parse("parse old kernel text_offset", hdr([0, 0, 1, 0, 0, 0, 0, 0], z8(), z8()), "text_offset=0x80000 image_size=0x0 flags=0x0")
    parse("parse magic byte 59", List.set(&2, U32, hdr(z8(), mib32(), z8()), 59n, 101), "None")
    parse("parse code0 is free", List.set(&2, U32, hdr(z8(), mib32(), z8()), 0n, 0), "text_offset=0x0 image_size=0x2000000 flags=0x0")

    # Layout. RAM 1 GiB at 0x4000_0000.
    # A 2 MiB aligned kernel end puts the DTB right there.
    lay("layout dtb at aligned kernel end", w(1073741824), w(1073741824), info(), 0, 8, 0, "kernel=0x40000000 kernel_end=0x42000000 dtb=0x42000000 initrd=0x42200000 initrd_end=0x42200000")
    # A kernel file one byte longer than image_size.
    lay("layout file one byte longer", w(1073741824), w(1073741824), info(), 33554433, 8, 1, "kernel=0x40000000 kernel_end=0x42000001 dtb=0x42200000 initrd=0x42400000 initrd_end=0x42400001")
    # text_offset adds to ram_base.
    lay("layout text_offset 0x20_0000", w(1073741824), w(1073741824), I.ImageInfo{w(2097152), w(4096), w(0)}, 4096, 8, 0, "kernel=0x40200000 kernel_end=0x40201000 dtb=0x40400000 initrd=0x40600000 initrd_end=0x40600000")
    # The largest DTB fills its 2 MiB region.
    lay("layout dtb of 2 MiB", w(1073741824), w(1073741824), info(), 0, 2097152, 0, "kernel=0x40000000 kernel_end=0x42000000 dtb=0x42000000 initrd=0x42200000 initrd_end=0x42200000")
    lay("layout dtb over 2 MiB", w(1073741824), w(1073741824), info(), 0, 2097153, 0, "None")
    # RAM of 36 MiB (0x4000_0000..0x4240_0000): the initrd ends exactly at
    # the end of RAM, then one byte past it.
    lay("layout initrd fits exactly", w(1073741824), w(37748736), info(), 0, 8, 2097152, "kernel=0x40000000 kernel_end=0x42000000 dtb=0x42000000 initrd=0x42200000 initrd_end=0x42400000")
    lay("layout initrd one byte past ram", w(1073741824), w(37748736), info(), 0, 8, 2097153, "None")
    # RAM of 32 MiB + 8: the DTB fits, an empty initrd lies past RAM.
    lay("layout empty initrd past ram", w(1073741824), w(33554440), info(), 0, 8, 0, "None")
    # The kernel itself does not fit.
    lay("layout kernel past ram", w(1073741824), w(16777216), info(), 0, 8, 0, "None")
    lay("layout zero ram", w(1073741824), w(0), info(), 0, 0, 0, "None")
    # RAM above 4 GiB: 0x1_0000_0000.
    lay("layout ram above 4 GiB", U.U64{1, 0}, w(1073741824), info(), 0, 8, 0, "kernel=0x100000000 kernel_end=0x102000000 dtb=0x102000000 initrd=0x102200000 initrd_end=0x102200000")
    # The kernel end crosses 4 GiB: 0xFFE0_0000 + 32 MiB.
    lay("layout carry into the high word", w(4292870144), U.U64{1, 0}, info(), 1, 8, 0, "kernel=0xffe00000 kernel_end=0x101e00000 dtb=0x101e00000 initrd=0x102000000 initrd_end=0x102000000")
    # Addresses that wrap past 2^64 never fit.
    lay("layout ram wraps", U.U64{4294967295, 4292870144}, U.U64{0, 33554432}, info(), 0, 8, 0, "None")
    lay("layout kernel wraps", U.U64{4294967295, 4292870144}, U.U64{0, 2097152}, I.ImageInfo{U.U64{4294967295, 0}, w(4096), w(0)}, 0, 8, 0, "None")
