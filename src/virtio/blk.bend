import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-blk (Virtio 1.2 section 5.2), device id 2, one request queue. The
# backing store is a host disk image reached through Op.disk_read and
# Op.disk_write. Offered features: VIRTIO_F_VERSION_1 only (so no FLUSH, no
# read-only, no multi-queue). Config space: capacity, a little-endian u64
# count of 512-byte sectors.
#
# A request is one chain: a 16-byte readable header {type u32, reserved u32,
# sector u64}, data descriptors, and a final 1-byte writable status.
#   type 0 IN:     read len bytes at sector*512 into the writable data
#                  descriptors; len = total writable length - 1
#   type 1 OUT:    write the readable data after the header at sector*512
#   type 8 GET_ID: write the id string (Blk.id(), NUL-padded to 20 bytes) into
#                  the writable data descriptors
#   other types:   status UNSUPP
# Status: 0 OK, 1 IOERR (the access ends past capacity*512, or the chain has no
# writable status byte to answer in), 2 UNSUPP. The used length is the number
# of bytes written into the chain, status byte included.

def Blk.id() -> String:
  "bend-vmm-disk"

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

# bs cut or zero-padded to exactly len bytes.
def Blk.fill(bs: +List<U32>, +len: Nat) -> +List<U32>:
  List.take(&2, U32, List.append(&2, U32, bs, B.Bytes.zeros(len)), len)

def Blk.answer(-R: Type, st: U32, data: +List<U32>) -> V.Op<R, U32 & +List<U32>>:
  V.Op.pure(R, U32 & +List<U32>, (st, data))

def Blk.in.go(-R: Type, ok: Bool, disk: U32, sector: U.U64, +len: U32) -> V.Op<R, U32 & +List<U32>>:
  match ok:
    case False{}:
      Blk.answer(R, Blk.s_ioerr(), [])
    case True{}:
      do V.Op<R, U32 & +List<U32>>:
        bs : +List<U32> <- V.Op.disk_read(R, disk, Blk.offset(sector), len)
        Blk.answer(R, Blk.s_ok(), Blk.fill(bs, U32.to_nat(len)))

# IN: reads len bytes at sector, answers them with the status.
def Blk.in(-R: Type, disk: U32, sectors: U.U64, +sector: U.U64, +len: U32) -> V.Op<R, U32 & +List<U32>>:
  Blk.in.go(R, Blk.fits(sectors, sector, len), disk, sector, len)

def Blk.out.go(-R: Type, ok: Bool, disk: U32, sector: U.U64, body: +List<U32>) -> V.Op<R, U32 & +List<U32>>:
  match ok:
    case False{}:
      Blk.answer(R, Blk.s_ioerr(), [])
    case True{}:
      do V.Op<R, U32 & +List<U32>>:
        V.Op.disk_write(R, disk, Blk.offset(sector), body)
        Blk.answer(R, Blk.s_ok(), [])

# OUT: writes body at sector.
def Blk.out(-R: Type, disk: U32, sectors: U.U64, +sector: U.U64, +body: +List<U32>) -> V.Op<R, U32 & +List<U32>>:
  Blk.out.go(R, Blk.fits(sectors, sector, U32.from_nat(List.length(&2, U32, body))), disk, sector, body)

# The request kind of a type field: 0 IN, 1 OUT, 2 GET_ID, 3 unsupported.
def Blk.kind(+t: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(t, 0), 0n,
    Bool.pick(Nat, U32.is_eq(t, 1), 1n,
      Bool.pick(Nat, U32.is_eq(t, 8), 2n, 3n)))

def Blk.exec.kind(
  -R: Type, k: Nat, disk: U32, sectors: U.U64, sector: U.U64, len: U32, body: +List<U32>
) -> V.Op<R, U32 & +List<U32>>:
  match k:
    case 0n:
      Blk.in(R, disk, sectors, sector, len)
    case 1n:
      Blk.out(R, disk, sectors, sector, body)
    case 2n:
      Blk.answer(R, Blk.s_ok(), Blk.id_bytes())
    case _:
      Blk.answer(R, Blk.s_unsupp(), [])

def Blk.exec.go(
  -R: Type, short: Bool, disk: U32, sectors: U.U64, len: U32, req: +List<U32>
) -> V.Op<R, U32 & +List<U32>>:
  match short:
    case True{}:
      Blk.answer(R, Blk.s_ioerr(), [])
    case False{}:
      +req = req
      t = B.Bytes.read_le32(req)
      sector = B.Bytes.read_le64(List.drop(&2, U32, req, 8n))
      body = List.drop(&2, U32, req, 16n)
      Blk.exec.kind(R, Blk.kind(t), disk, sectors, sector, len, body)

# Runs the request whose readable bytes are req (header, then OUT data), with
# len bytes of writable data room. Answers the status and the data to return.
def Blk.exec(-R: Type, disk: U32, sectors: U.U64, len: U32, +req: +List<U32>) -> V.Op<R, U32 & +List<U32>>:
  short = Nat.is_lt(List.length(&2, U32, req), 16n)
  Blk.exec.go(R, short, disk, sectors, len, req)

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

def Blk.answer_chain(
  -R: Type, empty: Bool, disk: U32, sectors: U.U64, +w: +List<Q.Desc>, +room: U32, +req: +List<U32>
) -> V.Op<R, U32>:
  match empty:
    case True{}:
      V.Op.pure(R, U32, 0)
    case False{}:
      do V.Op<R, U32>:
        res : U32 & +List<U32> <- Blk.exec(R, disk, sectors, (room - 1 : U32), req)
        Blk.reply(R, w, room, res)

# Serves one request chain and pushes it used. A chain without a writable
# byte has no status to answer in: it is returned untouched, used length 0.
def Blk.serve(-R: Type, disk: U32, sectors: U.U64, q: Q.Vq, c: Q.Chain) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, +w}:
      +room = Blk.room(w)
      do V.Op<R, Q.Vq>:
        req : +List<U32> <- Q.Vq.gather(R, Q.Chain{h, r, []})
        n : U32 <- Blk.answer_chain(R, U32.is_zero(room), disk, sectors, w, room, req)
        Q.Vq.push(R, q, h, n)

# After a pop: stops on an empty queue, else serves the chain and continues
# with k.
def Blk.step(
  -R: Type, disk: U32, sectors: U.U64, r: Q.Vq & Maybe<&2, Q.Chain>, used: Bool,
  k: Q.Vq -> V.Op<R, Q.Vq & Bool>
) -> V.Op<R, Q.Vq & Bool>:
  match r:
    case (q, None{}):
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, Q.Vq & Bool, Blk.serve(R, disk, sectors, q, c), k)

# Pops and serves requests, at most fuel of them; used tells whether any was.
def Blk.go(fuel: Nat, -R: Type, +disk: U32, +sectors: U.U64, q: Q.Vq, used: Bool) -> V.Op<R, Q.Vq & Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Q.Vq & Bool, (q, used))
    case 1n+f:
      do V.Op<R, Q.Vq & Bool>:
        r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
        Blk.step(R, disk, sectors, r, used, q2 => Blk.go(f, R, disk, sectors, q2, True{}))

# Serves every available request of the queue (at most num per call).
# Answers the queue and whether any chain was used.
def Blk.process(-R: Type, disk: U32, sectors: U.U64, q: Q.Vq) -> V.Op<R, Q.Vq & Bool>:
  match q:
    case Q.Vq{+num, d, dr, dv, na, nu}:
      Blk.go(U32.to_nat(num), R, disk, sectors, Q.Vq{num, d, dr, dv, na, nu}, False{})
