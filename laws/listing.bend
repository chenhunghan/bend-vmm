import Base
import ../src/lib/u64.bend as U
import ../src/vmm/abi.bend as V
import ../src/fs/listing.bend as L

# Spec for src/fs/listing.bend: a directory's listing order and its pages.

def e(n: String) -> V.FsEntry:
  V.FsEntry{n, U.U64{0, 1}, 8}

def dir() -> List<&2, V.FsEntry>:
  [e("zeta"), e("Alpha"), e("beta"), e("b"), e("alpha")]

law listing.sorted:
  {L.Listing.page(dir(), 0, 10) == [e("Alpha"), e("alpha"), e("b"), e("beta"), e("zeta")] : List<&2, V.FsEntry>}

law listing.page:
  {L.Listing.page(dir(), 2, 2) == [e("b"), e("beta")] : List<&2, V.FsEntry>}

law listing.past_end:
  {L.Listing.page(dir(), 5, 10) == [] : List<&2, V.FsEntry>}

law listing.prefix_first:
  {L.Listing.names_le("b", "beta") == True{} : Bool}
