import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./qcow2.bend as Q

# A block device's backing store: a raw image, or a qcow2 image over what
# lies below it (its backing file, or nothing), read and written in Op.
# Bend walks the qcow2 metadata; the host only moves bytes (V.Op.disk_*,
# inflate_*, zero_ram), so no guest data passes through Bend.
#
# Reads go cluster by cluster: a mapped cluster from the image, a compressed
# one inflated, a zero or unallocated one as zeros or from below. Writes go
# to the top image: in place for a cluster whose reference count is 1
# (COPIED); otherwise into a new cluster appended to the image (its old
# contents copied first unless the write covers it whole), a new L2 table
# when the L1 entry has none, and reference counts of 1 for both, a new
# refcount block when the table's entry has none. Writes need 16-bit
# reference counts (refcount_order 4) and fail past the refcount table.

type Store is Data:
  NoStore{}
  RawStore{disk: U32}
  QcowStore{disk: U32, q: Q.Qcow, below: Store}

# The first n bytes of some pieces of memory.
def Iov.take(xs: +List<V.Iov>, +n: U32) -> +List<V.Iov>:
  match xs:
    case Nil{}:
      []
    case V.Iov{+a, +l} <> t:
      Bool.pick(+List<V.Iov>, U32.is_zero(n), [],
        Bool.pick(+List<V.Iov>, U32.is_le(l, n), V.Iov{a, l} <> Iov.take(t, (n - l : U32)), [V.Iov{a, n}]))

# The pieces of memory past their first n bytes.
def Iov.drop(xs: +List<V.Iov>, +n: U32) -> +List<V.Iov>:
  match xs:
    case Nil{}:
      []
    case V.Iov{+a, +l} <> +t:
      Bool.pick(+List<V.Iov>, U32.is_zero(n), V.Iov{a, l} <> t,
        Bool.pick(+List<V.Iov>, U32.is_le(l, n), Iov.drop(t, (n - l : U32)), V.Iov{U.U64.add_u32(a, n), (l - n : U32)} <> t))

def Store.read8(-R: Type, disk: U32, off: U.U64) -> V.Op<R, U.U64>:
  do V.Op<R, U.U64>:
    +bs : +List<U32> <- V.Op.disk_read(R, disk, off, 8)
    return Q.Qcow.be64(bs, 0n)

def Store.write8(-R: Type, disk: U32, off: U.U64, v: U.U64) -> V.Op<R, Unit>:
  V.Op.disk_write(R, disk, off, B.Bytes.be64(v))

def Store.lookup.l2(-R: Type, none: Bool, +disk: U32, +q: Q.Qcow, l2: U.U64, +off: U.U64) -> V.Op<R, Q.Entry>:
  match none:
    case True{}:
      V.Op.pure(R, Q.Entry, Q.Unalloc{})
    case False{}:
      do V.Op<R, Q.Entry>:
        +e : U.U64 <- Store.read8(R, disk, U.U64.add(l2, U.U64.shl(3n, U.U64.from_u32(Q.Qcow.l2_index(q, off)))))
        return Q.Qcow.decode(q, e)

def Store.lookup.l1(-R: Type, past: Bool, +disk: U32, +q: Q.Qcow, +off: U.U64) -> V.Op<R, Q.Entry>:
  match past:
    case True{}:
      V.Op.pure(R, Q.Entry, Q.Unalloc{})
    case False{}:
      match q:
        case Q.Qcow{bits, size, +l1, l1_size, rt, rtc, rb}:
          +q = {Q.Qcow{bits, size, l1, l1_size, rt, rtc, rb} : Q.Qcow}
          do V.Op<R, Q.Entry>:
            +e1 : U.U64 <- Store.read8(R, disk, U.U64.add(l1, U.U64.shl(3n, U.U64.from_u32(Q.Qcow.l1_index(q, off)))))
            +l2 : U.U64 = Q.Qcow.entry_off(e1)
            Store.lookup.l2(R, U.U64.is_zero(l2), disk, q, l2, off)

def Qcow.l1_size(q: Q.Qcow) -> U32:
  match q:
    case Q.Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      l1_size

# What the cluster holding guest offset off is in the image.
def Store.lookup(-R: Type, +disk: U32, +q: Q.Qcow, +off: U.U64) -> V.Op<R, Q.Entry>:
  Store.lookup.l1(R, U32.is_le(Qcow.l1_size(q), Q.Qcow.l1_index(q, off)), disk, q, off)

# A cluster's part (skip bytes in, the pieces' length) into guest memory, by
# its entry; below: the read of the same bytes from the store below.
def Store.read.entry(-R: Type, e: Q.Entry, +disk: U32, +skip: U32, +a: +List<V.Iov>, below: V.Op<R, Unit>) -> V.Op<R, Unit>:
  match e:
    case Q.Unalloc{}:
      below
    case Q.Zeroed{}:
      V.Op.zero_ram(R, a)
    case Q.Mapped{off, copied}:
      V.Op.disk_to_ram(R, disk, U.U64.add_u32(off, skip), a)
    case Q.Packed{off, clen}:
      V.Op.inflate_to_ram(R, disk, off, clen, skip, a)

# more, unless the pieces are done.
def Store.read.rest(-R: Type, done: Bool, more: V.Op<R, Unit>) -> V.Op<R, Unit>:
  match done:
    case True{}:
      V.Op.pure(R, Unit, Unit{})
    case False{}:
      more

# The bytes from guest offset off on into the pieces of memory. fuel bounds
# the steps (a cluster at a time, and a layer at a time down the chain).
def Store.read(fuel: Nat, -R: Type, st: Store, +off: U.U64, +iovs: +List<V.Iov>) -> V.Op<R, Unit>:
  match fuel:
    case 0n:
      V.Op.zero_ram(R, iovs)
    case 1n+(+f):
      match st:
        case NoStore{}:
          V.Op.zero_ram(R, iovs)
        case RawStore{disk}:
          V.Op.disk_to_ram(R, disk, off, iovs)
        case QcowStore{+disk, +q, +below}:
          +total = V.Iov.total(iovs)
          +inner = Q.Qcow.inner(q, off)
          +n = U32.min(total, (Q.Qcow.csize(q) - inner : U32))
          +a = Iov.take(iovs, n)
          +rest = Iov.drop(iovs, n)
          do V.Op<R, Unit>:
            e : Q.Entry <- Store.lookup(R, disk, q, off)
            Store.read.entry(R, e, disk, inner, a, Store.read(f, R, below, off, a))
            Store.read.rest(R, U32.is_zero(V.Iov.total(rest)), Store.read(f, R, QcowStore{disk, q, below}, U.U64.add_u32(off, n), rest))


# A cluster's part into disk dst at doff, by its entry; dst is a fresh
# cluster (zeros), so zeros take nothing. below: the copy from the store
# below.
def Store.copy.entry(-R: Type, e: Q.Entry, +disk: U32, +skip: U32, +n: U32, +dst: U32, +doff: U.U64, below: V.Op<R, Unit>) -> V.Op<R, Unit>:
  match e:
    case Q.Unalloc{}:
      below
    case Q.Zeroed{}:
      V.Op.pure(R, Unit, Unit{})
    case Q.Mapped{off, copied}:
      V.Op.disk_copy(R, disk, U.U64.add_u32(off, skip), dst, doff, n)
    case Q.Packed{off, clen}:
      V.Op.inflate_to_disk(R, disk, off, clen, dst, doff, skip, n)

# Copies len bytes from guest offset off on (down the chain) into disk dst
# at doff, a fresh cluster.
def Store.copy(fuel: Nat, -R: Type, st: Store, +off: U.U64, +len: U32, +dst: U32, +doff: U.U64) -> V.Op<R, Unit>:
  match fuel:
    case 0n:
      V.Op.pure(R, Unit, Unit{})
    case 1n+(+f):
      match st:
        case NoStore{}:
          V.Op.pure(R, Unit, Unit{})
        case RawStore{disk}:
          V.Op.disk_copy(R, disk, off, dst, doff, len)
        case QcowStore{+disk, +q, +below}:
          +inner = Q.Qcow.inner(q, off)
          +n = U32.min(len, (Q.Qcow.csize(q) - inner : U32))
          do V.Op<R, Unit>:
            e : Q.Entry <- Store.lookup(R, disk, q, off)
            Store.copy.entry(R, e, disk, inner, n, dst, doff, Store.copy(f, R, below, off, n, dst, doff))
            Store.read.rest(R, U32.is_eq(n, len), Store.copy(f, R, QcowStore{disk, q, below}, U.U64.add_u32(off, n), (len - n : U32), dst, U.U64.add_u32(doff, n)))

def Qcow.rt(q: Q.Qcow) -> U.U64:
  match q:
    case Q.Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      rt

def Qcow.l1(q: Q.Qcow) -> U.U64:
  match q:
    case Q.Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      l1

def Qcow.refbits(q: Q.Qcow) -> U32:
  match q:
    case Q.Qcow{bits, size, l1, l1_size, rt, rtc, rb}:
      rb

def Store.ref.set(-R: Type, +disk: U32, rb: U.U64, slot: U32) -> V.Op<R, Bool>:
  do V.Op<R, Bool>:
    V.Op.disk_write(R, disk, U.U64.add(rb, U.U64.from_u32((slot * 2 : U32))), [0, 1])
    return True{}

# The refcount block for a table entry: when there is none, a new cluster
# (its address into the table first, then its own count, by self).
def Store.ref.block(-R: Type, none: Bool, +disk: U32, +q: Q.Qcow, +rti: U32, rb: U.U64, slot: U32, self: U.U64 -> V.Op<R, Bool>) -> V.Op<R, Bool>:
  match none:
    case False{}:
      Store.ref.set(R, disk, rb, slot)
    case True{}:
      do V.Op<R, Bool>:
        +nb : U.U64 <- V.Op.disk_alloc(R, disk, Q.Qcow.csize(q))
        Store.write8(R, disk, U.U64.add(Qcow.rt(q), U.U64.from_u32((rti * 8 : U32))), nb)
        ok : Bool <- self(nb)
        set : Bool <- Store.ref.set(R, disk, nb, slot)
        return ok && set

def Store.ref.go(-R: Type, ok: Bool, f: Nat, +disk: U32, +q: Q.Qcow, +h: U.U64, self: U.U64 -> V.Op<R, Bool>) -> V.Op<R, Bool>:
  match ok:
    case False{}:
      V.Op.pure(R, Bool, False{})
    case True{}:
      +rti = Q.Qcow.ref_rti(q, h)
      +slot = Q.Qcow.ref_slot(q, h)
      do V.Op<R, Bool>:
        e : U.U64 <- Store.read8(R, disk, U.U64.add(Qcow.rt(q), U.U64.from_u32((rti * 8 : U32))))
        +rb : U.U64 = Q.Qcow.entry_off(e)
        Store.ref.block(R, U.U64.is_zero(rb), disk, q, rti, rb, slot, self)

# Sets the reference count of the cluster at host offset h to 1 (16-bit
# counts only; false when the refcount table has no room for it). fuel
# bounds the new refcount blocks that counting takes.
def Store.ref(fuel: Nat, -R: Type, +disk: U32, +q: Q.Qcow, +h: U.U64) -> V.Op<R, Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Bool, False{})
    case 1n+(+f):
      +ok = U32.is_eq(Qcow.refbits(q), 16) && U32.is_lt(Q.Qcow.ref_rti(q, h), Q.Qcow.rt_entries(q))
      Store.ref.go(R, ok, f, disk, q, h, x => Store.ref(f, R, disk, q, x))

# The old contents of a cluster about to move to nc: nothing when the write
# covers it whole, else by its entry (below: from the store below).
def Store.fill(-R: Type, whole: Bool, e: Q.Entry, +disk: U32, +q: Q.Qcow, +nc: U.U64, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Unit>:
  match whole:
    case True{}:
      V.Op.pure(R, Unit, Unit{})
    case False{}:
      match e:
        case Q.Unalloc{}:
          cow(nc)
        case Q.Zeroed{}:
          V.Op.pure(R, Unit, Unit{})
        case Q.Mapped{off, copied}:
          V.Op.disk_copy(R, disk, off, disk, nc, Q.Qcow.csize(q))
        case Q.Packed{off, clen}:
          V.Op.inflate_to_disk(R, disk, off, clen, disk, nc, 0, Q.Qcow.csize(q))

# A write into a cluster that is not the image's alone: a new cluster, its
# count, the old contents, the data, then the L2 entry at slot.
def Store.write.new(-R: Type, e: Q.Entry, +disk: U32, +q: Q.Qcow, slot: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  do V.Op<R, Bool>:
    +nc : U.U64 <- V.Op.disk_alloc(R, disk, Q.Qcow.csize(q))
    ok : Bool <- Store.ref(4n, R, disk, q, nc)
    Store.fill(R, U32.is_zero(inner) && U32.is_eq(n, Q.Qcow.csize(q)), e, disk, q, nc, cow)
    V.Op.ram_to_disk(R, disk, U.U64.add_u32(nc, inner), a)
    Store.write8(R, disk, slot, Q.Qcow.copied(nc))
    return ok

def Store.write.mapped(-R: Type, copied: Bool, +off: U.U64, +disk: U32, +q: Q.Qcow, slot: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  match copied:
    case True{}:
      do V.Op<R, Bool>:
        V.Op.ram_to_disk(R, disk, U.U64.add_u32(off, inner), a)
        return True{}
    case False{}:
      Store.write.new(R, Q.Mapped{off, False{}}, disk, q, slot, inner, n, a, cow)

def Store.write.entry(-R: Type, e: Q.Entry, +disk: U32, +q: Q.Qcow, slot: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  match e:
    case Q.Mapped{off, copied}:
      Store.write.mapped(R, copied, off, disk, q, slot, inner, n, a, cow)
    case e:
      Store.write.new(R, e, disk, q, slot, inner, n, a, cow)

def Store.write.l2(-R: Type, fail: Bool, +disk: U32, +q: Q.Qcow, l2: U.U64, +off: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  match fail:
    case True{}:
      V.Op.pure(R, Bool, False{})
    case False{}:
      +slot = U.U64.add(l2, U.U64.from_u32((Q.Qcow.l2_index(q, off) * 8 : U32)))
      do V.Op<R, Bool>:
        e : U.U64 <- Store.read8(R, disk, slot)
        Store.write.entry(R, Q.Qcow.decode(q, e), disk, q, slot, inner, n, a, cow)

# The L2 table for L1 entry l1i: a new one (zeros, counted) when none.
def Store.ensure_l2(-R: Type, none: Bool, +disk: U32, +q: Q.Qcow, +l1i: U32, l2: U.U64) -> V.Op<R, U.U64>:
  match none:
    case False{}:
      V.Op.pure(R, U.U64, l2)
    case True{}:
      do V.Op<R, U.U64>:
        +nl : U.U64 <- V.Op.disk_alloc(R, disk, Q.Qcow.csize(q))
        ok : Bool <- Store.ref(4n, R, disk, q, nl)
        Store.write8(R, disk, U.U64.add(Qcow.l1(q), U.U64.from_u32((l1i * 8 : U32))), Q.Qcow.copied(nl))
        return Bool.pick(U.U64, ok, nl, U.U64.zero())

def Store.write.cluster.go(-R: Type, past: Bool, +disk: U32, +q: Q.Qcow, +off: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  match past:
    case True{}:
      V.Op.pure(R, Bool, False{})
    case False{}:
      +l1i = Q.Qcow.l1_index(q, off)
      do V.Op<R, Bool>:
        e1 : U.U64 <- Store.read8(R, disk, U.U64.add(Qcow.l1(q), U.U64.from_u32((l1i * 8 : U32))))
        +old : U.U64 = Q.Qcow.entry_off(e1)
        +l2 : U.U64 <- Store.ensure_l2(R, U.U64.is_zero(old), disk, q, l1i, old)
        Store.write.l2(R, U.U64.is_zero(l2), disk, q, l2, off, inner, n, a, cow)

# n bytes (the pieces a) at guest offset off, inner bytes into its cluster.
def Store.write.cluster(-R: Type, +disk: U32, +q: Q.Qcow, +off: U.U64, +inner: U32, +n: U32, a: +List<V.Iov>, cow: U.U64 -> V.Op<R, Unit>) -> V.Op<R, Bool>:
  Store.write.cluster.go(R, U32.is_le(Qcow.l1_size(q), Q.Qcow.l1_index(q, off)), disk, q, off, inner, n, a, cow)

def Store.write.rest(-R: Type, done: Bool, more: V.Op<R, Bool>) -> V.Op<R, Bool>:
  match done:
    case True{}:
      V.Op.pure(R, Bool, True{})
    case False{}:
      more

# The bytes of the pieces of memory, read from the guest.
def Store.bytes(-R: Type, xs: +List<V.Iov>) -> V.Op<R, +List<U32>>:
  match xs:
    case Nil{}:
      V.Op.pure(R, +List<U32>, [])
    case V.Iov{a, l} <> t:
      do V.Op<R, +List<U32>>:
        b : +List<U32> <- V.Op.read(R, a, l)
        r : +List<U32> <- Store.bytes(R, t)
        return List.append(&2, U32, b, r)

def Store.same(a: +List<U32>, b: +List<U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Con{x, xs} Con{y, ys}:
      U32.is_eq(x, y) && Store.same(xs, ys)
    case _ _:
      False{}

# Whether bytes begin as a qcow2 image does (QFI\xfb).
def Store.qcow_magic(bs: +List<U32>) -> Bool:
  Store.same(List.take(&2, U32, bs, 4n), [81, 70, 73, 251])

def Store.raw.write(-R: Type, refuse: Bool, +disk: U32, +off: U.U64, +iovs: +List<V.Iov>) -> V.Op<R, Bool>:
  match refuse:
    case True{}:
      V.Op.pure(R, Bool, False{})
    case False{}:
      do V.Op<R, Bool>:
        V.Op.ram_to_disk(R, disk, off, iovs)
        return True{}

# A raw image never takes a qcow2 header at its start: the host tells the
# formats apart by that header, so a guest that wrote one would turn its own
# disk into a qcow2 image at the next start, one whose backing file could
# name any host file (QEMU refuses the same for a probed raw image). Guest
# writes come in 512-byte sectors, so a write that reaches the first bytes
# starts at 0.
def Store.raw.at0(-R: Type, at0: Bool, +disk: U32, +off: U.U64, +iovs: +List<V.Iov>) -> V.Op<R, Bool>:
  match at0:
    case True{}:
      do V.Op<R, Bool>:
        head : +List<U32> <- Store.bytes(R, Iov.take(iovs, 4))
        Store.raw.write(R, Store.qcow_magic(head), disk, off, iovs)
    case False{}:
      Store.raw.write(R, False{}, disk, off, iovs)

# Writes the pieces of memory at guest offset off into the top image; false
# when a qcow2 image cannot take them (no room for its counts, or past its
# L1 table), a raw image would start as a qcow2 one, or there is no image.
def Store.write(fuel: Nat, -R: Type, st: Store, +off: U.U64, +iovs: +List<V.Iov>) -> V.Op<R, Bool>:
  match fuel:
    case 0n:
      V.Op.pure(R, Bool, False{})
    case 1n+(+f):
      match st:
        case NoStore{}:
          V.Op.pure(R, Bool, False{})
        case RawStore{disk}:
          Store.raw.at0(R, U.U64.is_zero(off), disk, off, iovs)
        case QcowStore{+disk, +q, +below}:
          +inner = Q.Qcow.inner(q, off)
          +n = U32.min(V.Iov.total(iovs), (Q.Qcow.csize(q) - inner : U32))
          +a = Iov.take(iovs, n)
          +rest = Iov.drop(iovs, n)
          +base = U.U64.sub(off, U.U64.from_u32(inner))
          +cs = Q.Qcow.csize(q)
          do V.Op<R, Bool>:
            ok1 : Bool <- Store.write.cluster(R, disk, q, off, inner, n, a, nc => Store.copy(f, R, below, base, cs, disk, nc))
            ok2 : Bool <- Store.write.rest(R, U32.is_zero(V.Iov.total(rest)), Store.write(f, R, QcowStore{disk, q, below}, U.U64.add_u32(off, n), rest))
            return ok1 && ok2

# Makes the top image's writes durable.
def Store.flush(-R: Type, st: Store) -> V.Op<R, Unit>:
  match st:
    case NoStore{}:
      V.Op.pure(R, Unit, Unit{})
    case RawStore{disk}:
      V.Op.disk_flush(R, disk)
    case QcowStore{disk, q, below}:
      V.Op.disk_flush(R, disk)
