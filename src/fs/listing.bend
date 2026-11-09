import Base
import ../vmm/abi.bend as V

# A shared directory's listing (laws/listing.bend): the host reads every
# entry (no "." or ".."), in whatever order its file system keeps; the order
# the guest sees, stable from one call to the next, is decided here: by
# name, byte by byte (as strcmp), and a call takes the page [from, from+max).

# a no later than b, byte by byte (a prefix comes first).
def Listing.names_le(a: String, b: String) -> Bool:
  match a b:
    case SNil{} _:
      True{}
    case SCon{x, xs} SNil{}:
      False{}
    case SCon{x, xs} SCon{y, ys}:
      +cx = Char.to_u32(x)
      +cy = Char.to_u32(y)
      U32.is_lt(cx, cy) || (U32.is_eq(cx, cy) && Listing.names_le(xs, ys))

def Listing.name(e: V.FsEntry) -> String:
  match e:
    case V.FsEntry{n, i, k}:
      n

# Whether a comes no later than b: by name, byte by byte.
def Listing.le(a: V.FsEntry, b: V.FsEntry) -> Bool:
  Listing.names_le(Listing.name(a), Listing.name(b))

# The page [from, from + max) of the entries in order.
def Listing.page(es: List<&2, V.FsEntry>, +from: U32, +max: U32) -> List<&2, V.FsEntry>:
  List.take(&2, V.FsEntry, List.drop(&2, V.FsEntry, List.sort(~V.FsEntry, ~Listing.le, es), U32.to_nat(from)), U32.to_nat(max))
