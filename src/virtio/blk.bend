import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q
import ../disk/store.bend as S

# virtio-blk (Virtio 1.2 section 5.2), device id 2, one request queue. The
# backing store is a host disk image. Request data moves between it and the
# chain's memory on the host (Op.disk_to_ram, Op.ram_to_disk: no byte passes
# through Bend); Bend reads only the header, decides, and names the memory
# (Q.Vq.segs). Op.disk_flush makes writes durable. Offered features: VIRTIO_F_VERSION_1 and
# VIRTIO_BLK_F_FLUSH, plus VIRTIO_BLK_F_RO on a read-only disk (no
# multi-queue). Config space: capacity, a little-endian u64 count of 512-byte
# sectors.
#
# A request is one chain: a 16-byte readable header {type u32, reserved u32,
# sector u64}, data descriptors, and a final 1-byte writable status.
#   type 0 IN:     read len bytes at sector*512 into the writable data
#                  descriptors; len = total writable length - 1
#   type 1 OUT:    write the readable data after the header at sector*512;
#                  on a read-only disk, status IOERR and nothing is written
#   type 4 FLUSH:  Op.disk_flush, then status OK
#   type 8 GET_ID: write the id string (Blk.id(), NUL-padded to 20 bytes) into
#                  the writable data descriptors
#   other types:   status UNSUPP
# Status: 0 OK, 1 IOERR (the access ends past capacity*512, or the chain has no
# writable status byte to answer in), 2 UNSUPP. The used length is the number
# of bytes written into the chain, status byte included.

def Blk.id() -> String:
  "bend-vmm-disk"

# The offered features: VIRTIO_F_VERSION_1 (bit 32, bit 0 of the high word),
# VIRTIO_BLK_F_FLUSH (bit 9) and, when ro, VIRTIO_BLK_F_RO (bit 5).
def Blk.features(ro: Bool) -> U.U64:
  U.U64{1, Bool.pick(U32, ro, 544, 512)}

def Blk.config(sectors: U.U64) -> +List<U32>:
  B.Bytes.le64(sectors)

# Status codes.
def Blk.s_ok() -> U32:
  0

def Blk.s_ioerr() -> U32:
  1

def Blk.s_unsupp() -> U32:
  2

# The total length of a chain's writable descriptors.
def Blk.room(ds: +List<Q.Desc>) -> U32:
  match ds:
    case Nil{}:
      0
    case Q.Desc{a, l, f, n} <> t:
      (l + Blk.room(t) : U32)

# The id string, NUL-padded (or cut) to 20 bytes.
def Blk.id_bytes() -> +List<U32>:
  List.take(&2, U32, List.append(&2, U32, B.Bytes.of_string(Blk.id()), B.Bytes.zeros(20n)), 20n)

# Whether len bytes fit before the end of the disk when rem sectors remain
# after the start sector. Past 2^23 sectors any U32 length fits, and below it
# rem * 512 does not overflow a U32.
def Blk.fits.rem(rem: U.U64, +len: U32) -> Bool:
  match rem:
    case U.U64{h, +l}:
      U32.is_ne(h, 0) || U32.is_ge(l, 8388608) || U32.is_le(len, (l * 512 : U32))

# Whether the access of len bytes at sector ends within capacity sectors.
def Blk.fits(+sectors: U.U64, +sector: U.U64, len: U32) -> Bool:
  U.U64.is_le(sector, sectors) && Blk.fits.rem(U.U64.sub(sectors, sector), len)

# The byte offset of a sector (sector * 512).
def Blk.offset(sector: U.U64) -> U.U64:
  U.U64.shl(9n, sector)

# The request kind of a type field: 0 IN, 1 OUT, 2 GET_ID, 3 FLUSH,
# 4 unsupported.
def Blk.kind(+t: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(t, 0), 0n,
    Bool.pick(Nat, U32.is_eq(t, 1), 1n,
      Bool.pick(Nat, U32.is_eq(t, 8), 2n,
        Bool.pick(Nat, U32.is_eq(t, 4), 3n, 4n))))

# Writes byte b at offset off of the writable area ds.
def Blk.put(-R: Type, ds: +List<Q.Desc>, +off: U32, +b: U32) -> V.Op<R, Unit>:
  match ds:
    case Nil{}:
      V.Op.pure(R, Unit, Unit{})
    case Q.Desc{a, +l, f, n} <> t:
      Bool.pick(V.Op<R, Unit>, U32.is_lt(off, l),
        V.Op.write(R, U.U64.add_u32(a, off), [b]),
        Blk.put(R, t, (off - l : U32), b))

# Scatters the data (cut to the room before the status byte), then writes the
# status into the last writable byte. Answers the bytes written.
def Blk.reply(-R: Type, +w: +List<Q.Desc>, +room: U32, res: U32 & +List<U32>) -> V.Op<R, U32>:
  match res:
    case (st, data):
      +last = (room - 1 : U32)
      do V.Op<R, U32>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{0, [], w}, List.take(&2, U32, data, U32.to_nat(last)))
        Blk.put(R, w, last, st)
        return (n + 1 : U32)

# The steps a request's store walk may take: a cluster at a time (512
# bytes at least) down a chain of images.
def Blk.fuel() -> Nat:
  1000000n

# IN: the room before the status byte filled from the store at sector.
def Blk.in(-R: Type, ok: Bool, st: S.Store, sector: U.U64, +w: +List<Q.Desc>, +room: U32) -> V.Op<R, U32>:
  match ok:
    case False{}:
      Blk.reply(R, w, room, (Blk.s_ioerr(), []))
    case True{}:
      +last = (room - 1 : U32)
      do V.Op<R, U32>:
        S.Store.read(Blk.fuel(), R, st, Blk.offset(sector), Q.Vq.segs(w, 0, last))
        Blk.put(R, w, last, Blk.s_ok())
        return room

# OUT: the readable data after the header (ss) written at sector.
def Blk.out(-R: Type, ok: Bool, st: S.Store, sector: U.U64, ss: +List<V.Iov>, +w: +List<Q.Desc>, +room: U32) -> V.Op<R, U32>:
  match ok:
    case False{}:
      Blk.reply(R, w, room, (Blk.s_ioerr(), []))
    case True{}:
      do V.Op<R, U32>:
        +done : Bool <- S.Store.write(Blk.fuel(), R, st, Blk.offset(sector), ss)
        Blk.reply(R, w, room, (Bool.pick(U32, done, Blk.s_ok(), Blk.s_ioerr()), []))

# OUT on a store that may be read-only: IOERR without writing when ro.
def Blk.out_ro(-R: Type, ro: Bool, st: S.Store, +sectors: U.U64, +sector: U.U64, +r: +List<Q.Desc>, +w: +List<Q.Desc>, +room: U32) -> V.Op<R, U32>:
  match ro:
    case True{}:
      Blk.reply(R, w, room, (Blk.s_ioerr(), []))
    case False{}:
      +ss = Q.Vq.segs(r, 16, 4294967295)
      Blk.out(R, Blk.fits(sectors, sector, V.Iov.total(ss)), st, sector, ss, w, room)

# FLUSH: makes earlier writes durable.
def Blk.flush(-R: Type, st: S.Store, +w: +List<Q.Desc>, +room: U32) -> V.Op<R, U32>:
  do V.Op<R, U32>:
    S.Store.flush(R, st)
    Blk.reply(R, w, room, (Blk.s_ok(), []))

def Blk.exec.kind(
  -R: Type, k: Nat, ro: Bool, st: S.Store, +sectors: U.U64, +sector: U.U64, +r: +List<Q.Desc>, +w: +List<Q.Desc>, +room: U32
) -> V.Op<R, U32>:
  match k:
    case 0n:
      Blk.in(R, Blk.fits(sectors, sector, (room - 1 : U32)), st, sector, w, room)
    case 1n:
      Blk.out_ro(R, ro, st, sectors, sector, r, w, room)
    case 2n:
      Blk.reply(R, w, room, (Blk.s_ok(), Blk.id_bytes()))
    case 3n:
      Blk.flush(R, st, w, room)
    case _:
      Blk.reply(R, w, room, (Blk.s_unsupp(), []))

# Runs a request whose first 16 readable bytes are hdr {type, reserved,
# sector}; a shorter header is an IOERR.
def Blk.exec.go(
  -R: Type, short: Bool, +hdr: +List<U32>, ro: Bool, st: S.Store, sectors: U.U64, r: +List<Q.Desc>, +w: +List<Q.Desc>, +room: U32
) -> V.Op<R, U32>:
  match short:
    case True{}:
      Blk.reply(R, w, room, (Blk.s_ioerr(), []))
    case False{}:
      +t = B.Bytes.read_le32(hdr)
      sector = B.Bytes.read_le64(List.drop(&2, U32, hdr, 8n))
      Blk.exec.kind(R, Blk.kind(t), ro, st, sectors, sector, r, w, room)

def Blk.exec(
  -R: Type, +hdr: +List<U32>, ro: Bool, st: S.Store, sectors: U.U64, r: +List<Q.Desc>, +w: +List<Q.Desc>, +room: U32
) -> V.Op<R, U32>:
  Blk.exec.go(R, Nat.is_lt(List.length(&2, U32, hdr), 16n), hdr, ro, st, sectors, r, w, room)

def Blk.answer_chain(
  -R: Type, empty: Bool, ro: Bool, st: S.Store, sectors: U.U64, +r: +List<Q.Desc>, +w: +List<Q.Desc>, +room: U32
) -> V.Op<R, U32>:
  match empty:
    case True{}:
      V.Op.pure(R, U32, 0)
    case False{}:
      do V.Op<R, U32>:
        hdr : +List<U32> <- Q.Vq.read_segs(R, Q.Vq.segs(r, 0, 16))
        Blk.exec(R, hdr, ro, st, sectors, r, w, room)

# Serves one request chain and pushes it used. A chain without a writable
# byte has no status to answer in: it is returned untouched, used length 0.
# The header is read through Bend; the data moves between the disk and the
# chain's memory on the host (Op.disk_to_ram, Op.ram_to_disk).
def Blk.serve_chain(-R: Type, ro: Bool, st: S.Store, sectors: U.U64, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, +w}:
      +room = Blk.room(w)
      do V.Op<R, Q.Vq>:
        n : U32 <- Blk.answer_chain(R, U32.is_zero(room), ro, st, sectors, r, w, room)
        Q.Vq.push(R, q, h, n)

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Blk.step(
  -R: Type, ro: Bool, st: S.Store, sectors: U.U64, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool,
  k: Q.Vq -> V.Op<R, Q.Vq & Bool>
) -> V.Op<R, Q.Vq & Bool>:
  match r:
    case (q, None{}):
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, Q.Vq & Bool, Blk.serve_chain(R, ro, st, sectors, q, c), k)

# Pops and serves requests, at most fuel of them; used tells whether any was.
def Blk.go(fuel: Nat, -R: Type, +ro: Bool, +st: S.Store, +sectors: U.U64, q: Q.Vq, used: Bool) -> V.Op<R, Q.Vq & Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case 1n+f:
      do V.Op<R, Q.Vq & Bool>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Blk.step(R, ro, st, sectors, r, used, q2 => Blk.go(f, R, ro, st, sectors, q2, True{}))

# Serves every available request of the queue (at most num per call) on a
# store (a raw image, or qcow2 over its backing files) that is read-only
# when ro. Answers the queue and whether any chain was used.
def Blk.serve_store(-R: Type, st: S.Store, sectors: U.U64, ro: Bool, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Blk.go(U32.to_nat(num), R, ro, st, sectors, Q.Vq{num, d, dr, dv, na, nu}, False{})

# Blk.serve_store on a raw disk image.
def Blk.serve(-R: Type, disk: U32, sectors: U.U64, ro: Bool, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  Blk.serve_store(R, S.RawStore{disk}, sectors, ro, q)

# Blk.serve on a read-write disk.
def Blk.process(-R: Type, disk: U32, sectors: U.U64, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  Blk.serve(R, disk, sectors, False{}, q)
