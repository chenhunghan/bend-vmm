import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/disk/qcow2.bend as Q
import ../src/disk/store.bend as St
import ./t.bend as T

# src/disk/store.bend on the simulator: a tiny qcow2 image of 512-byte
# clusters (cluster_bits 9) and 4 KiB. Layout: header 0, L1 table 512 (1
# entry), refcount table 1024 (1 cluster), refcount block 1536, L2 table
# 2048, guest cluster 1 mapped at 2560 (filled with 7), guest cluster 2
# zeroed (with 9s at 3072 left over), the rest unallocated. Clusters 0-6
# have reference count 1. The image ends at 3584.

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def be64(x: U32) -> +List<U32>:
  B.Bytes.be64(U.U64{0, x})

def copied(x: U32) -> +List<U32>:
  B.Bytes.be64(U.U64{2147483648, x})

def q() -> Q.Qcow:
  Q.Qcow{9, u64(4096), u64(512), 1, u64(1024), 1, 16}

def pad(+bs: +List<U32>, n: Nat) -> +List<U32>:
  cat(bs, B.Bytes.zeros(Nat.sub(n, List.length(&2, U32, bs))))

def refblock() -> +List<U32>:
  pad([0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], 512n)

def l2() -> +List<U32>:
  pad(cat(be64(0), cat(copied(2560), be64(1))), 512n)

def image() -> +List<U32>:
  +head = pad([81, 70, 73, 251], 512n)
  +l1 = pad(copied(2048), 512n)
  +rt = pad(be64(1536), 512n)
  cat(head, cat(l1, cat(rt, cat(refblock(), cat(l2(), cat(List.replicate(U32, 512n, 7), List.replicate(U32, 512n, 9)))))))

# Memory 0..8192; reads land at 4096.
def sim() -> S.Sim:
  S.Sim.with_disk(S.Sim.new(u64(0), 8192n), image())

def store() -> St.Store:
  St.QcowStore{0, q(), St.NoStore{}}

def read.got(r: Maybe<&1, S.Sim & Unit>, len: U32) -> +List<U32>:
  match r:
    case None{}:
      []
    case Some{(s2, u)}:
      S.Sim.read(s2, u64(4096), len)

def read(+s: S.Sim, off: U32, +len: U32) -> +List<U32>:
  read.got(S.Sim.exec(Unit, s, St.Store.read(1000n, Unit, store(), u64(off), [V.Iov{u64(4096), len}])), len)

def written(+s: S.Sim, off: U32, +data: +List<U32>) -> Maybe<&1, S.Sim & Bool>:
  +s = S.Sim.write(s, u64(4096), data)
  S.Sim.exec(Bool, s, St.Store.write(1000n, Bool, store(), u64(off), [V.Iov{u64(4096), U32.from_nat(List.length(&2, U32, data))}]))

# The same image's bytes taken as a raw disk.
def written_raw(+s: S.Sim, off: U32, +data: +List<U32>) -> Maybe<&1, S.Sim & Bool>:
  +s = S.Sim.write(s, u64(4096), data)
  S.Sim.exec(Bool, s, St.Store.write(1000n, Bool, St.RawStore{0}, u64(off), [V.Iov{u64(4096), U32.from_nat(List.length(&2, U32, data))}]))

def disk_after(r: Maybe<&1, S.Sim & Bool>) -> +List<U32>:
  match r:
    case None{}:
      []
    case Some{(s, ok)}:
      S.Sim.disk(s)

def ok_after(r: Maybe<&1, S.Sim & Bool>) -> Bool:
  match r:
    case None{}:
      False{}
    case Some{(s, ok)}:
      ok

def main() -> IO(Unit):
  +d = disk_after(written(sim(), 1100, [5, 5, 5, 5]))
  +d2 = disk_after(written(sim(), 600, [4, 4]))
  do IO<Unit>:
    T.eq_str("qcow2 read mapped", show(read(sim(), 512, 4)), "[7, 7, 7, 7]")
    T.eq_str("qcow2 read across clusters", show(read(sim(), 1020, 8)), "[7, 7, 7, 7, 0, 0, 0, 0]")
    T.eq_str("qcow2 read zeroed", show(read(sim(), 1024, 4)), "[0, 0, 0, 0]")
    T.eq_str("qcow2 read unallocated", show(read(sim(), 3000, 4)), "[0, 0, 0, 0]")
    # writing into zeroed guest cluster 2: a new cluster 7 at 3584, its count
    # set, the L2 entry pointing at it, the data 76 bytes in
    T.ok("qcow2 write ok", ok_after(written(sim(), 1100, [5, 5, 5, 5])))
    T.eq_u32("qcow2 write grows the image", U32.from_nat(List.length(&2, U32, d)), 4096)
    T.eq_str("qcow2 write data", show(B.Bytes.slice(d, 3659n, 6n)), "[0, 5, 5, 5, 5, 0]")
    T.eq_str("qcow2 write l2 entry", show(B.Bytes.slice(d, 2064n, 8n)), show(copied(3584)))
    T.eq_str("qcow2 write refcount", show(B.Bytes.slice(d, 1550n, 2n)), "[0, 1]")
    # writing in place into mapped cluster 1 (COPIED): no new cluster
    T.eq_u32("qcow2 in place keeps the size", U32.from_nat(List.length(&2, U32, d2)), 3584)
    T.eq_str("qcow2 in place data", show(B.Bytes.slice(d2, 2647n, 4n)), "[7, 4, 4, 7]")
    T.eq_str("qcow2 read after write", show(read(S.Sim.with_disk(sim(), d), 1100, 4)), "[5, 5, 5, 5]")
    # a raw disk never starts as a qcow2 image (QFI\xfb): the write is refused
    # and the disk keeps its first bytes; elsewhere, or other bytes, go in
    T.ok("raw refuses a qcow2 header at 0", Bool.not(ok_after(written_raw(sim(), 0, [81, 70, 73, 251, 0, 0, 0, 3]))))
    T.eq_str("raw keeps its start", show(List.take(&2, U32, disk_after(written_raw(S.Sim.with_disk(sim(), B.Bytes.zeros(1024n)), 0, [81, 70, 73, 251])), 4n)), "[0, 0, 0, 0]")
    T.ok("raw takes the magic past 0", ok_after(written_raw(sim(), 512, [81, 70, 73, 251])))
    T.ok("raw takes other bytes at 0", ok_after(written_raw(sim(), 0, [81, 70, 73, 250])))
