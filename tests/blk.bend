import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/vmm/abi.bend as V
import ../src/vmm/sim.bend as S
import ../src/virtio/queue.bend as Q
import ../src/virtio/blk.bend as K
import ../src/virtio/device.bend as D
import ./t.bend as T

# virtio-blk requests on the simulator. Layout (decimal): memory 4096..20480;
# descriptor table 4096, available ring 8192, used ring 12288, buffers from
# 16384. The disk is image 0: 4 sectors (2048 bytes) of a byte pattern.

def show(bs: +List<U32>) -> String:
  List.show(~&2, ~U32, ~U32.show, bs)

def u64(x: U32) -> U.U64:
  U.U64{0, x}

def cat(a: +List<U32>, b: +List<U32>) -> +List<U32>:
  List.append(&2, U32, a, b)

# A 16-byte descriptor.
def desc(addr: U32, len: U32, flags: U32, next: U32) -> +List<U32>:
  cat(B.Bytes.le64(u64(addr)), cat(B.Bytes.le32(len), cat(B.Bytes.le16(flags), B.Bytes.le16(next))))

# A request header: type, reserved, sector.
def hdr(t: U32, sector: U32) -> +List<U32>:
  cat(B.Bytes.le32(t), cat(B.Bytes.le32(0), B.Bytes.le64(u64(sector))))

def pattern(n: Nat, +i: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      (((i * 7) + (i >> 9n)) .&. 255 : U32) <> pattern(p, (i + 1 : U32))

def disk() -> +List<U32>:
  pattern(2048n, 0)

def le16s(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      cat(B.Bytes.le16(x), le16s(t))

def le32s(xs: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      cat(B.Bytes.le32(x), le32s(t))

def bytes_eq(xs: +List<U32>, ys: +List<U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{x, xt} Con{y, yt}:
      U32.is_eq(x, y) && bytes_eq(xt, yt)
    case _ _:
      False{}

def bool_eq(a: Bool, b: Bool) -> Bool:
  match a b:
    case True{} True{}:
      True{}
    case False{} False{}:
      True{}
    case _ _:
      False{}

def slice(bs: +List<U32>, off: Nat, len: Nat) -> +List<U32>:
  B.Bytes.slice(bs, off, len)

# Memory with the given descriptor table and available ring (idx, heads).
def machine(table: +List<U32>, idx: U32, heads: +List<U32>) -> S.Sim:
  +s = S.Sim.with_disk(S.Sim.new(u64(4096), 16384n), disk())
  s = S.Sim.write(s, u64(4096), table)
  S.Sim.write(s, u64(8194), cat(B.Bytes.le16(idx), le16s(heads)))

def queue() -> Q.Vq:
  Q.Vq{8, u64(4096), u64(8192), u64(12288), 0, 0}

def run(s: S.Sim) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, s, K.Blk.process(Q.Vq & Bool, 0, u64(4), queue()))

# Expected used ring: flags, idx, then {id, len} per element.
def used(idx: U32, elems: +List<U32>) -> +List<U32>:
  cat([0, 0], cat(B.Bytes.le16(idx), le32s(elems)))

# Checks memory at addr, the used ring, the returned flag and queue, the disk.
def check(
  +name: String, r: Maybe<&1, S.Sim & (Q.Vq & Bool)>, addr: U32, want: +List<U32>,
  want_used: +List<U32>, flag: Bool, +na: U32, want_disk: +List<U32>
) -> IO(Unit):
  match r:
    case None{}:
      T.ok(name ++ " ran", False{})
    case Some{(+s, (q, f))}:
      +want = want
      +want_used = want_used
      +n = List.length(&2, U32, want)
      +m = List.length(&2, U32, want_used)
      do IO<Unit>:
        T.eq_str(name ++ " data", show(S.Sim.read(s, u64(addr), U32.from_nat(n))), show(want))
        T.eq_str(name ++ " used ring", show(S.Sim.read(s, u64(12288), U32.from_nat(m))), show(want_used))
        T.ok(name ++ " flag", bool_eq(f, flag))
        T.ok(name ++ " queue", Q.Vq.is_eq(q, Q.Vq{8, u64(4096), u64(8192), u64(12288), na, na}))
        T.ok(name ++ " disk", bytes_eq(S.Sim.disk(s), want_disk))

# "bend-vmm-disk", NUL-padded to 20 bytes.
def id() -> +List<U32>:
  [98, 101, 110, 100, 45, 118, 109, 109, 45, 100, 105, 115, 107, 0, 0, 0, 0, 0, 0, 0]

# 1. IN sector 1 into one 512-byte data descriptor; status at 16912.
def read1() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 512, 3, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 1))
  check("blk read", run(s), 16400, cat(slice(disk(), 512n, 512n), [0]), used(1, [0, 513]), True{}, 1, disk())

# 2. IN sector 2 split over 200 + 312 bytes; status at 16912.
def read_split() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 200, 3, 2), cat(desc(16600, 312, 3, 3), desc(16912, 1, 2, 0))))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 2))
  check("blk read split", run(s), 16400, cat(slice(disk(), 1024n, 512n), [0]), used(1, [0, 513]), True{}, 1, disk())

# 3. OUT 512 bytes of 171 to sector 3; status at 16912.
def write3() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 512, 1, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(1, 3))
  +s = S.Sim.write(s, u64(16400), List.replicate(U32, 512n, 171))
  check("blk write", run(s), 16912, [0], used(1, [0, 1]), True{}, 1, cat(slice(disk(), 0n, 1536n), List.replicate(U32, 512n, 171)))

# 4. GET_ID into 20 bytes; status at 16420.
def get_id() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 20, 3, 2), desc(16420, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(8, 0))
  check("blk get_id", run(s), 16400, cat(id(), [0]), used(1, [0, 21]), True{}, 1, disk())

# 5. An unknown type (5): UNSUPP, data untouched.
def unsupported() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 4, 3, 2), desc(16404, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(5, 0))
  check("blk unsupported", run(s), 16400, [0, 0, 0, 0, 2], used(1, [0, 1]), True{}, 1, disk())

# 6. IN sector 3, 1024 bytes: ends past capacity (4 sectors): IOERR.
def past_end() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 1024, 3, 2), desc(17424, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 3))
  check("blk past capacity", run(s), 17424, [1], used(1, [0, 1]), True{}, 1, disk())

# 7. OUT at sector 4 (the end of the disk): IOERR, disk unchanged.
def write_past_end() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 512, 1, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(1, 4))
  check("blk write past capacity", run(s), 16912, [1], used(1, [0, 1]), True{}, 1, disk())

# 8. Two requests posted at once: IN sector 0 (16 bytes) as chain 0 (data
# 16400, status 16416), GET_ID as chain 3 (header 16456, data 16472, status
# 16492).
def two() -> IO(Unit):
  +a = cat(desc(16384, 16, 1, 1), cat(desc(16400, 16, 3, 2), desc(16416, 1, 2, 0)))
  +b = cat(desc(16456, 16, 1, 4), cat(desc(16472, 20, 3, 5), desc(16492, 1, 2, 0)))
  +s = S.Sim.write(machine(cat(a, b), 2, [0, 3]), u64(16384), hdr(0, 0))
  +s = S.Sim.write(s, u64(16456), hdr(8, 0))
  +want = cat(slice(disk(), 0n, 16n), cat([0], cat(B.Bytes.zeros(39n), cat(hdr(8, 0), cat(id(), [0])))))
  check("blk two requests", run(s), 16400, want, used(2, [0, 17, 3, 21]), True{}, 2, disk())

# 9. An empty queue: nothing used, flag False.
def empty() -> IO(Unit):
  +s = machine(desc(16384, 16, 1, 0), 0, [])
  check("blk empty queue", run(s), 16384, [], used(0, []), False{}, 0, disk())

# 10. A chain with no writable byte: IOERR has nowhere to go, used length 0.
def no_status() -> IO(Unit):
  +s = S.Sim.write(machine(desc(16384, 16, 0, 0), 1, [0]), u64(16384), hdr(0, 0))
  check("blk no status", run(s), 16384, hdr(0, 0), used(1, [0, 0]), True{}, 1, disk())

def run_ro(s: S.Sim) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, s, K.Blk.serve(Q.Vq & Bool, 0, u64(4), True{}, queue()))

def run_rw(s: S.Sim) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, s, K.Blk.serve(Q.Vq & Bool, 0, u64(4), False{}, queue()))

def run_dev(k: D.DevKind, s: S.Sim) -> Maybe<&1, S.Sim & (Q.Vq & Bool)>:
  S.Sim.exec(Q.Vq & Bool, s, D.Dev.process(Q.Vq & Bool, k, queue()))

# The number of flushes the run made (99 when it did not run).
def flushes(r: Maybe<&1, S.Sim & (Q.Vq & Bool)>) -> U32:
  match r:
    case None{}:
      99
    case Some{(s, x)}:
      U32.from_nat(S.Sim.flushes(s))

def feats(f: U.U64) -> +List<U32>:
  match f:
    case U.U64{h, l}:
      [h, l]

# A FLUSH request: header and status (16400).
def flush_sim() -> S.Sim:
  +t = cat(desc(16384, 16, 1, 1), desc(16400, 1, 2, 0))
  S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(4, 0))

# 11. FLUSH (type 4): one Op.disk_flush, status OK, used length 1.
def flush() -> IO(Unit):
  +s = flush_sim()
  do IO<Unit>:
    check("blk flush", run(s), 16400, [0], used(1, [0, 1]), True{}, 1, disk())
    T.eq_u32("blk flush count", flushes(run(s)), 1)
    T.eq_u32("blk flush count ro", flushes(run_ro(s)), 1)
    T.eq_u32("blk no flush on IN", flushes(run(S.Sim.write(s, u64(16384), hdr(0, 0)))), 0)

# The OUT request of test 3: 512 bytes of 171 to sector 3.
def out_sim() -> S.Sim:
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 512, 1, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(1, 3))
  S.Sim.write(s, u64(16400), List.replicate(U32, 512n, 171))

# 12. OUT on a read-only disk: IOERR, disk unchanged; on a read-write one
# through Blk.serve: written.
def out_ro() -> IO(Unit):
  +s = out_sim()
  +written = cat(slice(disk(), 0n, 1536n), List.replicate(U32, 512n, 171))
  do IO<Unit>:
    check("blk ro write", run_ro(s), 16912, [1], used(1, [0, 1]), True{}, 1, disk())
    check("blk serve rw write", run_rw(s), 16912, [0], used(1, [0, 1]), True{}, 1, written)
    check("blk dev ro write", run_dev(D.BlkRoKind{0, u64(4)}, s), 16912, [1], used(1, [0, 1]), True{}, 1, disk())
    check("blk dev rw write", run_dev(D.BlkKind{0, u64(4)}, s), 16912, [0], used(1, [0, 1]), True{}, 1, written)

# 13. IN and GET_ID on a read-only disk are served as usual.
def in_ro() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), cat(desc(16400, 512, 3, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 1))
  +u = cat(desc(16384, 16, 1, 1), cat(desc(16400, 20, 3, 2), desc(16420, 1, 2, 0)))
  +g = S.Sim.write(machine(u, 1, [0]), u64(16384), hdr(8, 0))
  do IO<Unit>:
    check("blk ro read", run_ro(s), 16400, cat(slice(disk(), 512n, 512n), [0]), used(1, [0, 513]), True{}, 1, disk())
    check("blk dev ro read", run_dev(D.BlkRoKind{0, u64(4)}, s), 16400, cat(slice(disk(), 512n, 512n), [0]), used(1, [0, 513]), True{}, 1, disk())
    check("blk ro get_id", run_ro(g), 16400, cat(id(), [0]), used(1, [0, 21]), True{}, 1, disk())

# 12. OUT whose header and data share one descriptor (528 bytes).
def write_one_desc() -> IO(Unit):
  +t = cat(desc(16384, 528, 1, 1), desc(16912, 1, 2, 0))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(1, 3))
  +s = S.Sim.write(s, u64(16400), List.replicate(U32, 512n, 171))
  check("blk write one descriptor", run(s), 16912, [0], used(1, [0, 1]), True{}, 1, cat(slice(disk(), 0n, 1536n), List.replicate(U32, 512n, 171)))

# 13. IN whose data and status share one writable descriptor (513 bytes).
def read_one_desc() -> IO(Unit):
  +t = cat(desc(16384, 16, 1, 1), desc(16400, 513, 2, 0))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 1))
  check("blk read one descriptor", run(s), 16400, cat(slice(disk(), 512n, 512n), [0]), used(1, [0, 513]), True{}, 1, disk())

# 14. A header shorter than 16 bytes: IOERR.
def short_header() -> IO(Unit):
  +t = cat(desc(16384, 8, 1, 1), desc(16400, 1, 2, 0))
  +s = S.Sim.write(machine(t, 1, [0]), u64(16384), hdr(0, 1))
  check("blk short header", run(s), 16400, [1], used(1, [0, 1]), True{}, 1, disk())

# What a request does on a disk of 65536 sectors (32 MiB), running on the
# simulator up to its first disk effect ("disk") or its end ("status" and the
# status byte at 16912).
def touch(fuel: Nat, -A: Type, s: S.Sim, m: V.Vm<A>) -> String:
  match fuel:
    case 0n:
      "fuel"
    case 1n+f:
      match m:
        case V.VmRead{+a, n, k}:
          +s = s
          touch(f, A, s, k(S.Sim.read(s, a, n)))
        case V.VmWrite{a, bs, next}:
          touch(f, A, S.Sim.write(s, a, bs), next)
        case V.VmRet{x}:
          "status " ++ show(S.Sim.read(s, u64(16912), 1))
        case V.VmDiskToRam{d, o, i, next}:
          "disk"
        case V.VmRamToDisk{d, o, i, next}:
          "disk"
        case _:
          "other"

def big(t: U32, flags: U32, len: U32) -> String:
  +tb = cat(desc(16384, 16, 1, 1), cat(desc(16400, len, flags, 2), desc(16912, 1, 2, 0)))
  +s = S.Sim.write(machine(tb, 1, [0]), u64(16384), hdr(t, 0))
  touch(100n, Q.Vq & Bool, s, V.Op.finish(Q.Vq & Bool, K.Blk.serve(Q.Vq & Bool, 0, u64(65536), False{}, queue())))

# 15. One request moves at most 16 MiB: a longer one is IOERR, the disk
# untouched.
def big_requests() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("blk read of 16 MiB served", big(0, 3, 16777216), "disk")
    T.eq_str("blk read past 16 MiB is IOERR", big(0, 3, 16777217), "status [1]")
    T.eq_str("blk write of 16 MiB served", big(1, 1, 16777216), "disk")
    T.eq_str("blk write past 16 MiB is IOERR", big(1, 1, 16777217), "status [1]")
    T.eq_str("blk write of 4 GiB is IOERR", big(1, 1, 4294967295), "status [1]")

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_str("blk config", show(K.Blk.config(U.U64{1, 2})), "[2, 0, 0, 0, 1, 0, 0, 0]")
    read1()
    read_split()
    write3()
    get_id()
    unsupported()
    past_end()
    write_past_end()
    two()
    empty()
    no_status()
    flush()
    out_ro()
    in_ro()
    write_one_desc()
    read_one_desc()
    short_header()
    T.eq_str("blk features rw", show(feats(K.Blk.features(False{}))), "[1, 512]")
    T.eq_str("blk features ro", show(feats(K.Blk.features(True{}))), "[1, 544]")
    big_requests()
    T.eq_str("blk offered rw", show(feats(K.Blk.offered(False{}))), "[1, 518]")
    T.eq_str("blk offered ro", show(feats(K.Blk.offered(True{}))), "[1, 550]")
    T.eq_str("blk config with limits", show(K.Blk.config_limits(U.U64{1, 2})), "[2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 128, 0, 0, 0]")
