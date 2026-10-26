import Base
import ../src/lib/u64.bend as U
import ../src/boot/image.bend as I

# Frozen spec for src/boot/image.bend.

def w(x: U32) -> U.U64:
  U.U64{0, x}

# text_offset 0, image_size 32 MiB, flags 10 (LE, 4K pages, place anywhere)
def hdr() -> +List<U32>:
  [77, 90, 0, 145, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 65, 82, 77, 100, 0, 0, 0, 0]

# a pre-3.17 header: image_size 0
def old_hdr() -> +List<U32>:
  [77, 90, 0, 145, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 65, 82, 77, 100, 0, 0, 0, 0]

def info() -> I.ImageInfo:
  I.ImageInfo{w(0), w(33554432), w(10)}

law image.parse:
  {I.Image.parse(hdr()) == Some{info()} : Maybe<&2, I.ImageInfo>}

law image.parse_old:
  {I.Image.parse(old_hdr()) == Some{I.ImageInfo{w(524288), w(0), w(0)}} : Maybe<&2, I.ImageInfo>}

law image.parse_short:
  {I.Image.parse([77, 90]) == None{} : Maybe<&2, I.ImageInfo>}

law image.parse_bad_magic:
  {I.Image.parse(List.set(&2, U32, hdr(), 56n, 66)) == None{} : Maybe<&2, I.ImageInfo>}

law image.parse_big_endian:
  {I.Image.parse(List.set(&2, U32, hdr(), 24n, 11)) == None{} : Maybe<&2, I.ImageInfo>}

law image.layout:
  # RAM 1 GiB at 0x4000_0000, 20 MiB file of a 32 MiB image, 4 KiB DTB,
  # 1 MiB + 5 initrd. Kernel 0x4000_0000..0x4200_0000, DTB 0x4200_0000,
  # initrd 0x4220_0000.
  {I.Image.layout(w(1073741824), w(1073741824), info(), 20971520, 4096, 1048581) == Some{I.Layout{w(1073741824), w(1107296256), w(1107296256), w(1109393408), w(1110441989)}} : Maybe<&2, I.Layout>}

law image.layout_file_longer_than_image:
  # A 33 MiB + 1 file pushes the DTB to the next 2 MiB boundary.
  {I.Image.layout(w(1073741824), w(1073741824), info(), 34603009, 4096, 0) == Some{I.Layout{w(1073741824), w(1108344833), w(1109393408), w(1111490560), w(1111490560)}} : Maybe<&2, I.Layout>}

law image.layout_old_kernel:
  # text_offset 0x80000
  {I.Image.layout(w(1073741824), w(1073741824), I.ImageInfo{w(524288), w(0), w(0)}, 1048576, 4096, 0) == Some{I.Layout{w(1074266112), w(1075314688), w(1075838976), w(1077936128), w(1077936128)}} : Maybe<&2, I.Layout>}

law image.layout_no_room:
  {I.Image.layout(w(1073741824), w(33554432), info(), 20971520, 4096, 0) == None{} : Maybe<&2, I.Layout>}
