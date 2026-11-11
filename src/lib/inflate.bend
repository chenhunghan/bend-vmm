import Base

# DEFLATE (RFC 1951) and gzip (RFC 1952) decoding (laws/inflate.bend): the
# spec of host/hvf.c's hvf_inflate, which calls zlib, and the oracle the
# differential test checks zlib against (tests/oracles/inflate.py). Bytes
# are lists here, so this is for small inputs; the host keeps zlib until a
# packed-buffer decoder meets the speed gate (C_TO_BEND.md, stage 6).
#
# What the host accepts (hvf_inflate, one inflate call over all the output):
#   a raw stream (qcow2's compressed clusters): the bytes up to the end of
#     the last block; output that reaches `room` stops there and is no
#     error; an error AFTER some output still answers that output (zlib's
#     inflate returns what it wrote, and the C takes any out > 0)
#   a gzip file (a compressed kernel): one member, its header checked
#     (magic, method 8, no reserved flag; extra, name, comment and header
#     CRC skipped or checked), its trailer's CRC-32 and size checked; more
#     output than `room` is an error; bytes after the member are ignored
# A back-reference may reach any byte written so far: the C hands zlib all
# of the output at once, so its window is the whole output, not 2^wbits.
#
# The decoder is a state machine over a bit reader (least significant bit
# first). Every step reads at least one bit or ends a block, so a fuel of
# twice the input's bits and a few more ends every run.

# Errors (the numbers are this module's; zlib's messages in brackets):
#   1 the input ended early                 [incomplete / buffer error]
#   2 block type 3                          [invalid block type]
#   3 stored LEN is not ~NLEN               [invalid stored block lengths]
#   4 more than 286 literal or 30 distance codes [too many length or distance symbols]
#   5 the code-length code is over-subscribed or incomplete [invalid code lengths set]
#   6 a repeat with no length before it, or past the count [invalid bit length repeat]
#   7 the end-of-block code has no length   [invalid code -- missing end-of-block]
#   8 the literal/length code is bad        [invalid literal/lengths set]
#   9 the distance code is bad              [invalid distances set]
#  10 a literal/length code that is unused or 286, 287 [invalid literal/length code]
#  11 a distance code that is unused or 30, 31 [invalid distance code]
#  12 a distance past the output so far     [invalid distance too far back]
#  20 a bad gzip header                     [incorrect header check / unknown compression method / unknown header flags set]
#  21 the gzip CRC-32 does not match        [incorrect data check]
#  22 the gzip size does not match          [incorrect length check]
#  23 the gzip header CRC does not match    [header crc mismatch]
#  30 the output reached `room` (an error only for gzip)
#  31 out of fuel (cannot happen with Inflate.fuel)

def Inflate.u32_nat(bits: Nat, +x: U32) -> Nat:
  match bits:
    case 0n:
      0n
    case 1n+k:
      Nat.add(Nat.double(Inflate.u32_nat(k, (x >> 1n : U32))), Bool.pick(Nat, U32.is_eq((x .&. 1 : U32), 1), 1n, 0n))

def Inflate.nat(+x: U32) -> Nat:
  Inflate.u32_nat(32n, x)

# The element at n (0 when there is none).
def Inflate.at(xs: +List<U32>, n: Nat) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{x, rest}:
      match n:
        case 0n:
          x
        case 1n+k:
          Inflate.at(rest, k)

# The first n of xs, reversed onto acc.
def Inflate.take_rev(n: Nat, xs: +List<U32>, +acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      acc
    case 1n+k:
      match xs:
        case Nil{}:
          acc
        case Con{x, rest}:
          Inflate.take_rev(k, rest, Con{x, acc})

# Bit input
# =========

# The bits not yet used (buf, cnt of them, low first), the bytes after them,
# and whether a read wanted more bits than there were (short).
type Bits is Data:
  Bits{buf: U32, cnt: U32, rest: +List<U32>, short: Bool}

def Bits.of(+bs: +List<U32>) -> Bits:
  Bits{0, 0, bs, False{}}

# One more byte when fewer than n bits are held (n <= 24).
def Bits.pull(+n: U32, +b: Bits) -> Bits:
  match b:
    case Bits{+buf, +cnt, +rest, short}:
      match rest:
        case Nil{}:
          Bits{buf, cnt, [], short}
        case Con{+x, +more}:
          Bool.pick(Bits, U32.is_lt(cnt, n),
            Bits{(buf .|. U32.shln(x, Inflate.u32_nat(5n, cnt)) : U32), (cnt + 8 : U32), more, short},
            Bits{buf, cnt, Con{x, more}, short})

def Bits.mask(+n: U32) -> U32:
  Bool.pick(U32, U32.is_le(32, n), 4294967295, (U32.shln(1, Inflate.u32_nat(5n, n)) - 1 : U32))

# A read of n bits (n <= 16).
type Got is Data:
  Got{v: U32, b: Bits}

def Got.v(+g: Got) -> U32:
  match g:
    case Got{v, b}:
      v

def Got.b(+g: Got) -> Bits:
  match g:
    case Got{v, b}:
      b

def Bits.take(+n: U32, +b: Bits) -> Got:
  match b:
    case Bits{+buf, +cnt, +rest, +short}:
      Bool.pick(Got, U32.is_lt(cnt, n),
        Got{0, Bits{buf, cnt, rest, True{}}},
        Got{(buf .&. Bits.mask(n) : U32), Bits{U32.shrn(buf, Inflate.u32_nat(5n, n)), (cnt - n : U32), rest, short}})

def Bits.get(+n: U32, +b: Bits) -> Got:
  Bits.take(n, Bits.pull(n, Bits.pull(n, Bits.pull(n, b))))

# 32 bits, as two reads of 16.
def Inflate.get32.join(+lo: U32, +g: Got) -> Got:
  match g:
    case Got{+hi, +b}:
      Got{(lo .|. (hi << 16n : U32) : U32), b}

def Inflate.get32.lo(+g: Got) -> Got:
  match g:
    case Got{+lo, +b}:
      Inflate.get32.join(lo, Bits.get(16, b))

def Inflate.get32(+b: Bits) -> Got:
  Inflate.get32.lo(Bits.get(16, b))

# Drops the bits up to the next byte boundary (before a stored block).
def Bits.align(+b: Bits) -> Bits:
  match b:
    case Bits{+buf, +cnt, rest, short}:
      +k = (cnt .&. 7 : U32)
      Bits{U32.shrn(buf, Inflate.u32_nat(3n, k)), (cnt - k : U32), rest, short}

def Bits.is_short(+b: Bits) -> Bool:
  match b:
    case Bits{x, c, r, short}:
      short

# Huffman codes
# =============

# A canonical code: how many codes of each length 0..15, and the symbols
# ordered by length, then by value (RFC 1951, 3.2.2).
type Huff is Data:
  Huff{counts: +List<U32>, syms: +List<U32>}

def Huff.count(lens: +List<U32>, +l: U32, +acc: U32) -> U32:
  match lens:
    case Nil{}:
      acc
    case Con{+x, rest}:
      Huff.count(rest, l, Bool.pick(U32, U32.is_eq(x, l), (acc + 1 : U32), acc))

# The counts for lengths l..15, onto acc (reversed: built from 15 down).
def Huff.counts.go(n: Nat, +lens: +List<U32>, +acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      Con{Huff.count(lens, 0, 0), acc}
    case 1n+(+k):
      Huff.counts.go(k, lens, Con{Huff.count(lens, (U32.from_nat(k) + 1 : U32), 0), acc})

def Huff.counts(+lens: +List<U32>) -> +List<U32>:
  Huff.counts.go(15n, lens, [])

# The symbols with length l, in order, reversed onto acc.
def Huff.with_len(lens: +List<U32>, +l: U32, +s: U32, +acc: +List<U32>) -> +List<U32>:
  match lens:
    case Nil{}:
      acc
    case Con{+x, rest}:
      Huff.with_len(rest, l, (s + 1 : U32), Bool.pick(+List<U32>, U32.is_eq(x, l), Con{s, acc}, acc))

def Huff.syms.go(n: Nat, +lens: +List<U32>, +acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      acc
    case 1n+(+k):
      Huff.syms.go(k, lens, Huff.with_len(lens, (15 - U32.from_nat(k) : U32), 0, acc))

def Huff.of(+lens: +List<U32>) -> Huff:
  Huff{Huff.counts(lens), List.reverse(&2, U32, Huff.syms.go(15n, lens, []))}

# How the code fills the code space: over-subscribed (some length has more
# codes than room), the room left (0: complete), and the longest length.
type Fill is Data:
  Fill{over: Bool, left: U32, max: U32}

def Huff.fill.go(cs: +List<U32>, +len: U32, +left: U32, +over: Bool, +max: U32) -> Fill:
  match cs:
    case Nil{}:
      Fill{over, left, max}
    case Con{+c, rest}:
      +room = (left * 2 : U32)
      Huff.fill.go(rest, (len + 1 : U32), Bool.pick(U32, U32.is_lt(room, c), 0, (room - c : U32)),
        over || U32.is_lt(room, c), Bool.pick(U32, U32.is_eq(c, 0), max, len))

def Huff.fill(+h: Huff) -> Fill:
  match h:
    case Huff{cs, s}:
      match cs:
        case Nil{}:
          Fill{False{}, 1, 0}
        case Con{c0, rest}:
          Huff.fill.go(rest, 1, 1, False{}, 0)

# zlib's rule (inflate_table): over-subscribed is bad; incomplete is bad,
# except a code whose longest length is 1 (one symbol) for literals and
# distances; the code-length code must be complete (strict). A code with
# no symbols at all builds, and fails on its first use.
def Huff.ok.of(+strict: Bool, +f: Fill) -> Bool:
  match f:
    case Fill{+over, +left, +max}:
      Bool.not(over) && (U32.is_eq(max, 0) || U32.is_eq(left, 0) || (Bool.not(strict) && U32.is_eq(max, 1)))

def Huff.ok(+strict: Bool, +h: Huff) -> Bool:
  Huff.ok.of(strict, Huff.fill(h))

# A decoded symbol, or none (4294967295: no code matches).
type Sym is Data:
  Sym{s: U32, b: Bits}

# Decoding (puff's decode): one bit at a time; at each length, the codes of
# that length are first .. first+count-1.
type Dec is Data:
  DSearch{code: U32, first: U32, index: U32, b: Bits}
  DFound{s: U32, b: Bits}

def Huff.dstep.bit(+syms: +List<U32>, +count: U32, +code: U32, +first: U32, +index: U32, +g: Got) -> Dec:
  match g:
    case Got{+bit, +b2}:
          +c = (code .|. bit : U32)
          Bool.pick(Dec, U32.is_lt((c - first : U32), count) && U32.is_le(first, c),
            DFound{Inflate.at(syms, Inflate.nat((index + (c - first : U32) : U32))), b2},
            DSearch{(c << 1n : U32), ((first + count : U32) << 1n : U32), (index + count : U32), b2})

def Huff.dstep(+syms: +List<U32>, +count: U32, +d: Dec) -> Dec:
  match d:
    case DFound{s, b}:
      DFound{s, b}
    case DSearch{+code, +first, +index, +b}:
      Huff.dstep.bit(syms, count, code, first, index, Bits.get(1, b))

def Huff.decode.go(cs: +List<U32>, +syms: +List<U32>, +d: Dec) -> Dec:
  match cs:
    case Nil{}:
      d
    case Con{+c, rest}:
      Huff.decode.go(rest, syms, Huff.dstep(syms, c, d))

def Huff.decode.end(+d: Dec) -> Sym:
  match d:
    case DFound{+s, +b2}:
      Sym{s, b2}
    case DSearch{c, f, i, +b2}:
      Sym{4294967295, b2}

def Huff.decode(+h: Huff, +b: Bits) -> Sym:
  match h:
    case Huff{cs, +syms}:
      match cs:
        case Nil{}:
          Sym{4294967295, b}
        case Con{c0, rest}:
          Huff.decode.end(Huff.decode.go(rest, syms, DSearch{0, 0, 0, b}))

# n copies of x onto acc.
def Inflate.rep(n: Nat, +x: U32, +acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      acc
    case 1n+k:
      Inflate.rep(k, x, Con{x, acc})

# The fixed codes (RFC 1951, 3.2.6).
def Huff.fixed_lit() -> Huff:
  Huff.of(List.reverse(&2, U32, Inflate.rep(8n, 8, Inflate.rep(24n, 7, Inflate.rep(112n, 9, Inflate.rep(144n, 8, []))))))

def Huff.fixed_dist() -> Huff:
  Huff.of(Inflate.rep(30n, 5, []))

# Length and distance bases and extra bits (RFC 1951, 3.2.5).
def Inflate.len_base() -> +List<U32>:
  [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]

def Inflate.len_extra() -> +List<U32>:
  [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

def Inflate.dist_base() -> +List<U32>:
  [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

def Inflate.dist_extra() -> +List<U32>:
  [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

# The order of the code-length code's lengths.
def Inflate.clen_order() -> +List<U32>:
  [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

# Dynamic code lengths
# ====================

# Replaces the element at n.
def Inflate.set(xs: +List<U32>, n: Nat, +v: U32) -> +List<U32>:
  match xs:
    case Nil{}:
      []
    case Con{+x, rest}:
      match n:
        case 0n:
          Con{v, rest}
        case 1n+k:
          Con{x, Inflate.set(rest, k, v)}

# n bits, or none (0, the bits unchanged) when not wanted.
def Inflate.read_if(+want: Bool, +n: U32, +b: Bits) -> Got:
  Bool.pick(Got, want, Bits.get(n, b), Got{0, b})

type CLens is Data:
  CLens{lens: +List<U32>, b: Bits}

# The code-length code's lengths: the first `left` of clen_order read, 3
# bits each; the rest 0.
def Inflate.clens.go(order: +List<U32>, +left: U32, +lens: +List<U32>, +b: Bits) -> CLens:
  match order:
    case Nil{}:
      CLens{lens, b}
    case Con{+sym, rest}:
      +g = Inflate.read_if(U32.is_lt(0, left), 3, b)
      Inflate.clens.go(rest, Bool.pick(U32, U32.is_eq(left, 0), 0, (left - 1 : U32)), Inflate.set(lens, Inflate.nat(sym), Got.v(g)), Got.b(g))

# The literal/length and distance code lengths, read with the code-length
# code: newest first in rev, n of total read, err (0, or 1 or 6).
type LState is Data:
  LState{rev: +List<U32>, n: U32, err: U32, b: Bits}

# A run of k copies of x when it fits the count, else error 6.
def Inflate.lens.run(+total: U32, +rev: +List<U32>, +n: U32, +k: U32, +x: U32, +bad: Bool, +b: Bits) -> LState:
  Bool.pick(LState, bad || U32.is_lt(total, (n + k : U32)), LState{rev, n, 6, b},
    LState{Inflate.rep(Inflate.u32_nat(8n, k), x, rev), (n + k : U32), 0, b})

def Inflate.prev(+rev: +List<U32>) -> U32:
  match rev:
    case Nil{}:
      0
    case Con{x, r}:
      x

def Inflate.lens.rep(+total: U32, +rev: +List<U32>, +n: U32, +base: U32, +x: U32, +bad: Bool, +g: Got) -> LState:
  match g:
    case Got{+v, +b}:
      Bool.pick(LState, Bits.is_short(b), LState{rev, n, 1, b}, Inflate.lens.run(total, rev, n, (base + v : U32), x, bad, b))

def Inflate.lens.sym(+total: U32, +rev: +List<U32>, +n: U32, +sym: U32, +b: Bits) -> LState:
  +g2 = Bits.get(2, b)
  +g3 = Bits.get(3, b)
  +g7 = Bits.get(7, b)
  Bool.pick(LState, U32.is_lt(sym, 16), LState{Con{sym, rev}, (n + 1 : U32), 0, b},
  Bool.pick(LState, U32.is_eq(sym, 16), Inflate.lens.rep(total, rev, n, 3, Inflate.prev(rev), U32.is_eq(n, 0), g2),
  Bool.pick(LState, U32.is_eq(sym, 17), Inflate.lens.rep(total, rev, n, 3, 0, False{}, g3),
  Bool.pick(LState, U32.is_eq(sym, 18), Inflate.lens.rep(total, rev, n, 11, 0, False{}, g7),
    LState{rev, n, 5, b}))))

def Inflate.lens.on(+total: U32, +rev: +List<U32>, +n: U32, +sy: Sym) -> LState:
  match sy:
    case Sym{+s, +b}:
      Bool.pick(LState, Bits.is_short(b), LState{rev, n, 1, b}, Inflate.lens.sym(total, rev, n, s, b))

def Inflate.lens.step(+total: U32, +ch: Huff, +ls: LState) -> LState:
  match ls:
    case LState{+rev, +n, +err, +b}:
      Bool.pick(LState, Bool.not(U32.is_eq(err, 0)) || U32.is_le(total, n), LState{rev, n, err, b},
        Inflate.lens.on(total, rev, n, Huff.decode(ch, b)))

# At most 316 lengths, each step reads at least one.
def Inflate.lens.go(fuel: Nat, +total: U32, +ch: Huff, +ls: LState) -> LState:
  match fuel:
    case 0n:
      ls
    case 1n+k:
      Inflate.lens.go(k, total, ch, Inflate.lens.step(total, ch, ls))

# The decoder
# ===========

type St is Data:
  SHead{}
  SStored{left: U32}
  SCodes{lit: Huff, dist: Huff}
  SDone{}
  SFull{}
  SErr{code: U32}

# The state, the bits, the output (newest first), its length, whether the
# last block began, and the most output allowed.
type Inf is Data:
  Inf{st: St, b: Bits, out: +List<U32>, n: U32, last: Bool, room: U32}

def Inflate.fail(+code: U32, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  Inf{SErr{code}, b, out, n, last, room}

# A dynamic block's codes, from its lengths (newest first in rev).
def Inflate.dyn.codes(+hlit: U32, +ls: LState, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match ls:
    case LState{+rev, ln, +err, +b}:
      +lens = List.reverse(&2, U32, rev)
      +litl = List.take(&2, U32, lens, Inflate.nat(hlit))
      +lit = Huff.of(litl)
      +dist = Huff.of(List.drop(&2, U32, lens, Inflate.nat(hlit)))
      Bool.pick(Inf, Bool.not(U32.is_eq(err, 0)), Inflate.fail(err, b, out, n, last, room),
      Bool.pick(Inf, U32.is_eq(Inflate.at(litl, 256n), 0), Inflate.fail(7, b, out, n, last, room),
      Bool.pick(Inf, Bool.not(Huff.ok(False{}, lit)), Inflate.fail(8, b, out, n, last, room),
      Bool.pick(Inf, Bool.not(Huff.ok(False{}, dist)), Inflate.fail(9, b, out, n, last, room),
        Inf{SCodes{lit, dist}, b, out, n, last, room}))))

def Inflate.dyn.lens(+hlit: U32, +hdist: U32, +cl: CLens, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match cl:
    case CLens{+lens, +b}:
      +ch = Huff.of(lens)
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
      Bool.pick(Inf, Bool.not(Huff.ok(True{}, ch)), Inflate.fail(5, b, out, n, last, room),
        Inflate.dyn.codes(hlit, Inflate.lens.go(320n, (hlit + hdist : U32), ch, LState{[], 0, 0, b}), out, n, last, room)))

# The three counts: 5, 5 and 4 bits as one 14-bit read.
def Inflate.dyn.head(+g: Got, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match g:
    case Got{+v, +b3}:
              +hlit = ((v .&. 31 : U32) + 257 : U32)
              +hdist = (((v >> 5n : U32) .&. 31 : U32) + 1 : U32)
              +c = ((v >> 10n : U32) .&. 15 : U32)
              Bool.pick(Inf, Bits.is_short(b3), Inflate.fail(1, b3, out, n, last, room),
              Bool.pick(Inf, U32.is_lt(286, hlit) || U32.is_lt(30, hdist), Inflate.fail(4, b3, out, n, last, room),
                Inflate.dyn.lens(hlit, hdist, Inflate.clens.go(Inflate.clen_order(), (c + 4 : U32), Inflate.rep(19n, 0, []), b3), out, n, last, room)))

def Inflate.dyn(+b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  Inflate.dyn.head(Bits.get(14, b), out, n, last, room)

# A stored block's header: to the byte boundary, LEN, then NLEN = ~LEN.
def Inflate.stored.lens(+g: Got, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match g:
    case Got{+v, +b2}:
          +len = (v .&. 65535 : U32)
          +nlen = (v >> 16n : U32)
          Bool.pick(Inf, Bits.is_short(b2), Inflate.fail(1, b2, out, n, last, room),
          Bool.pick(Inf, Bool.not(U32.is_eq(len, U32.xor(nlen, 65535))), Inflate.fail(3, b2, out, n, last, room),
            Inf{SStored{len}, b2, out, n, last, room}))

def Inflate.stored(+b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  Inflate.stored.lens(Inflate.get32(Bits.align(b)), out, n, last, room)

# A block of type BTYPE (hi and lo bits): 0 stored, 1 fixed, 2 dynamic, 3
# none.
def Inflate.block(hi: Bool, lo: Bool, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match hi:
    case False{}:
      match lo:
        case False{}:
          Inflate.stored(b, out, n, last, room)
        case True{}:
          Inf{SCodes{Huff.fixed_lit(), Huff.fixed_dist()}, b, out, n, last, room}
    case True{}:
      match lo:
        case False{}:
          Inflate.dyn(b, out, n, last, room)
        case True{}:
          Inflate.fail(2, b, out, n, last, room)

# A block's start: when the last block has ended, the stream is done; else
# BFINAL and BTYPE.
def Inflate.head.got(+g: Got, +out: +List<U32>, +n: U32, +room: U32) -> Inf:
  match g:
    case Got{+v, +b}:
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, False{}, room),
        Inflate.block(U32.is_eq((v .&. 4 : U32), 4), U32.is_eq((v .&. 2 : U32), 2), b, out, n, U32.is_eq((v .&. 1 : U32), 1), room))

def Inflate.head(last: Bool, +b: Bits, +out: +List<U32>, +n: U32, +room: U32) -> Inf:
  match last:
    case True{}:
      Inf{SDone{}, b, out, n, True{}, room}
    case False{}:
      Inflate.head.got(Bits.get(3, b), out, n, room)

# A stored block's next byte.
def Inflate.stored.byte(+left: U32, +g: Got, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match g:
    case Got{+v, +b}:
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
        Inf{SStored{(left - 1 : U32)}, b, Con{v, out}, (n + 1 : U32), last, room})

def Inflate.stored.step(+left: U32, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  Bool.pick(Inf, U32.is_eq(left, 0), Inf{SHead{}, b, out, n, last, room},
    Bool.pick(Inf, U32.is_le(room, n), Inf{SFull{}, b, out, n, last, room},
      Inflate.stored.byte(left, Bits.get(8, b), out, n, last, room)))

# A literal/length symbol's kind.
type K is Data:
  KLit{}
  KEnd{}
  KLen{}
  KBad{}

def Inflate.kind(+s: U32) -> K:
  Bool.pick(K, U32.is_lt(s, 256), KLit{}, Bool.pick(K, U32.is_eq(s, 256), KEnd{}, Bool.pick(K, U32.is_lt(s, 286), KLen{}, KBad{})))

# len bytes from distance d (the newest first in out): the last d bytes,
# oldest first, cycled.
def Inflate.cycle(len: Nat, +seg: +List<U32>, cur: +List<U32>, +out: +List<U32>) -> +List<U32>:
  match len:
    case 0n:
      out
    case 1n+k:
      match cur:
        case Con{x, rest}:
          Inflate.cycle(k, seg, rest, Con{x, out})
        case Nil{}:
          Inflate.cycle(k, seg, List.drop(&2, U32, seg, 1n), Con{Inflate.at(seg, 0n), out})

# A match of len at distance d, cut at room (then full).
def Inflate.copy.ok(ok: Bool, +len: U32, +d: U32, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match ok:
    case False{}:
      Inflate.fail(12, b, out, n, last, room)
    case True{}:
      +k = U32.min(len, (room - n : U32))
      +seg = Inflate.take_rev(Inflate.nat(d), out, [])
      Inf{Bool.pick(St, U32.is_lt(k, len), SFull{}, SCodes{lit, dist}), b, Inflate.cycle(Inflate.nat(k), seg, seg, out), (n + k : U32), last, room}

def Inflate.copy(+len: U32, +base: U32, +g: Got, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match g:
    case Got{+v, +b}:
      +d = (base + v : U32)
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
        Inflate.copy.ok(U32.is_le(d, n), len, d, b, out, n, last, room, lit, dist))

def Inflate.match.dist(+len: U32, +sy: Sym, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match sy:
    case Sym{+ds, +b}:
      +i = Inflate.nat(ds)
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
        Bool.pick(Inf, U32.is_le(30, ds), Inflate.fail(11, b, out, n, last, room),
          Inflate.copy(len, Inflate.at(Inflate.dist_base(), i), Bits.get(Inflate.at(Inflate.dist_extra(), i), b), out, n, last, room, lit, dist)))

def Inflate.match.len(+base: U32, +g: Got, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match g:
    case Got{+v, +b}:
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
        Inflate.match.dist((base + v : U32), Huff.decode(dist, b), out, n, last, room, lit, dist))

def Inflate.codes.on(k: K, +s: U32, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match k:
    case KLit{}:
      Bool.pick(Inf, U32.is_le(room, n), Inf{SFull{}, b, out, n, last, room},
        Inf{SCodes{lit, dist}, b, Con{s, out}, (n + 1 : U32), last, room})
    case KEnd{}:
      Inf{SHead{}, b, out, n, last, room}
    case KBad{}:
      Inflate.fail(10, b, out, n, last, room)
    case KLen{}:
      +i = Inflate.nat((s - 257 : U32))
      Inflate.match.len(Inflate.at(Inflate.len_base(), i), Bits.get(Inflate.at(Inflate.len_extra(), i), b), out, n, last, room, lit, dist)

def Inflate.codes.sym(+sy: Sym, +out: +List<U32>, +n: U32, +last: Bool, +room: U32, +lit: Huff, +dist: Huff) -> Inf:
  match sy:
    case Sym{+s, +b}:
      Bool.pick(Inf, Bits.is_short(b), Inflate.fail(1, b, out, n, last, room),
        Inflate.codes.on(Inflate.kind(s), s, b, out, n, last, room, lit, dist))

# One step of a running stream.
def Inflate.step(st: St, +b: Bits, +out: +List<U32>, +n: U32, +last: Bool, +room: U32) -> Inf:
  match st:
    case SHead{}:
      Inflate.head(last, b, out, n, room)
    case SStored{+left}:
      Inflate.stored.step(left, b, out, n, last, room)
    case SCodes{+lit, +dist}:
      Inflate.codes.sym(Huff.decode(lit, b), out, n, last, room, lit, dist)
    case SDone{}:
      Inf{SDone{}, b, out, n, last, room}
    case SFull{}:
      Inf{SFull{}, b, out, n, last, room}
    case SErr{c}:
      Inf{SErr{c}, b, out, n, last, room}

def Inflate.run(fuel: Nat, +i: Inf) -> Inf:
  match fuel:
    case 0n:
      match i:
        case Inf{st, b, out, n, last, room}:
          Inflate.fail(31, b, out, n, last, room)
    case 1n+k:
      match i:
        case Inf{st, +b, +out, +n, +last, +room}:
          match st:
            case SDone{}:
              Inf{SDone{}, b, out, n, last, room}
            case SFull{}:
              Inf{SFull{}, b, out, n, last, room}
            case SErr{c}:
              Inf{SErr{c}, b, out, n, last, room}
            case SHead{}:
              Inflate.run(k, Inflate.step(SHead{}, b, out, n, last, room))
            case SStored{left}:
              Inflate.run(k, Inflate.step(SStored{left}, b, out, n, last, room))
            case SCodes{lit, dist}:
              Inflate.run(k, Inflate.step(SCodes{lit, dist}, b, out, n, last, room))

# Enough steps for any input: each step reads a bit or ends a block.
def Inflate.fuel(+src: +List<U32>) -> Nat:
  Nat.add(Nat.mul(List.length(&2, U32, src), 16n), 16n)

def Inflate.stream(+src: +List<U32>, +room: U32) -> Inf:
  Inflate.run(Inflate.fuel(src), Inf{SHead{}, Bits.of(src), [], 0, False{}, room})

# What the host gets: the output, or an error.
type Res is Data:
  ROk{out: +List<U32>}
  RErr{code: U32}

# A raw stream, as the host inflates a qcow2 cluster: the output when the
# stream ends or fills room, and also after an error once some output was
# written; else the error.
def Inflate.raw.of(+i: Inf) -> Res:
  match i:
    case Inf{st, b, +out, +n, l, r}:
      match st:
        case SErr{+c}:
          Bool.pick(Res, U32.is_eq(n, 0), RErr{c}, ROk{List.reverse(&2, U32, out)})
        case SDone{}:
          ROk{List.reverse(&2, U32, out)}
        case SFull{}:
          ROk{List.reverse(&2, U32, out)}
        case SHead{}:
          RErr{31}
        case SStored{x}:
          RErr{31}
        case SCodes{x, y}:
          RErr{31}

def Inflate.raw(+src: +List<U32>, +room: U32) -> Res:
  Inflate.raw.of(Inflate.stream(src, room))

# CRC-32 (the gzip trailer's), bit by bit.
def Crc.round(+c: U32) -> U32:
  U32.xor((c >> 1n : U32), (3988292384 .&. (0 - (c .&. 1 : U32) : U32) : U32))

def Crc.byte(+c: U32, +x: U32) -> U32:
  Crc.round(Crc.round(Crc.round(Crc.round(Crc.round(Crc.round(Crc.round(Crc.round(U32.xor(c, x)))))))))

def Crc.go(xs: +List<U32>, +c: U32) -> U32:
  match xs:
    case Nil{}:
      c
    case Con{+x, rest}:
      Crc.go(rest, Crc.byte(c, x))

def Crc.of(+xs: +List<U32>) -> U32:
  U32.xor(Crc.go(xs, 4294967295), 4294967295)

# gzip
# ====

# The header as it is read: the bytes after it, how many it took, and an
# error (0 none).
type At is Data:
  At{rest: +List<U32>, k: U32, err: U32}

def Gz.le16(+xs: +List<U32>) -> U32:
  (Inflate.at(xs, 0n) .|. (Inflate.at(xs, 1n) << 8n : U32) : U32)

def Gz.len(+xs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, xs))

# Past a zero-terminated string (name or comment).
def Gz.zstr.go(xs: +List<U32>, +k: U32, ended: Bool) -> At:
  match xs ended:
    case Nil{} True{}:
      At{[], k, 0}
    case Nil{} False{}:
      At{[], k, 1}
    case Con{x, rest} True{}:
      At{Con{x, rest}, k, 0}
    case Con{+x, rest} False{}:
      Gz.zstr.go(rest, (k + 1 : U32), U32.is_eq(x, 0))

def Gz.zstr.of(+a: At, +x: At) -> At:
  match a:
    case At{r, k, +err}:
      match x:
        case At{+r2, +k2, +e2}:
          At{r2, k2, Bool.pick(U32, U32.is_eq(err, 0), e2, err)}

def Gz.zstr(on: Bool, +a: At) -> At:
  match on:
    case False{}:
      a
    case True{}:
      match a:
        case At{+r, +k, +err}:
          Gz.zstr.of(At{r, k, err}, Gz.zstr.go(r, k, False{}))

def Gz.extra(on: Bool, +a: At) -> At:
  match on:
    case False{}:
      a
    case True{}:
      match a:
        case At{+r, +k, +err}:
          +x = (Gz.le16(r) + 2 : U32)
          Bool.pick(At, U32.is_lt(Gz.len(r), x), At{[], k, Bool.pick(U32, U32.is_eq(err, 0), 1, err)},
            At{List.drop(&2, U32, r, Inflate.nat(x)), (k + x : U32), err})

# The header CRC: the low 16 bits of the CRC-32 of the header before it.
def Gz.hcrc(on: Bool, +src: +List<U32>, +a: At) -> At:
  match on:
    case False{}:
      a
    case True{}:
      match a:
        case At{+r, +k, +err}:
          +want = Gz.le16(r)
          +got = (Crc.of(List.take(&2, U32, src, Inflate.nat(k))) .&. 65535 : U32)
          Bool.pick(At, U32.is_lt(Gz.len(r), 2), At{[], k, Bool.pick(U32, U32.is_eq(err, 0), 1, err)},
            At{List.drop(&2, U32, r, 2n), (k + 2 : U32), Bool.pick(U32, U32.is_eq(err, 0) && Bool.not(U32.is_eq(want, got)), 23, err)})

def Gz.flag(+flg: U32, +bit: U32) -> Bool:
  U32.is_eq((flg .&. bit : U32), bit)

# Magic 31 139, method 8, no reserved flag (224), then the optional parts.
def Gz.head(+src: +List<U32>) -> At:
  +flg = Inflate.at(src, 3n)
  +ok = U32.is_eq(Inflate.at(src, 0n), 31) && U32.is_eq(Inflate.at(src, 1n), 139) && U32.is_eq(Inflate.at(src, 2n), 8)
    && U32.is_eq((flg .&. 224 : U32), 0) && U32.is_le(10, Gz.len(src))
  +a : At = At{List.drop(&2, U32, src, 10n), 10, Bool.pick(U32, ok, 0, 20)}
  Gz.hcrc(Gz.flag(flg, 2), src, Gz.zstr(Gz.flag(flg, 16), Gz.zstr(Gz.flag(flg, 8), Gz.extra(Gz.flag(flg, 4), a))))

# After the last block: to the byte boundary, the CRC-32 and the size.
def Gz.trailer.check(+g: Got, +crc: U32, +out: +List<U32>, +n: U32) -> Res:
  match g:
    case Got{+v, +b}:
      Bool.pick(Res, Bits.is_short(b), RErr{1},
        Bool.pick(Res, Bool.not(U32.is_eq(v, n)), RErr{22}, ROk{out}))

def Gz.trailer(+g: Got, +out: +List<U32>, +n: U32) -> Res:
  match g:
    case Got{+crc, +b}:
      Bool.pick(Res, Bits.is_short(b), RErr{1},
        Bool.pick(Res, Bool.not(U32.is_eq(crc, Crc.of(out))), RErr{21},
          Gz.trailer.check(Inflate.get32(b), crc, out, n)))

def Gz.end(+i: Inf) -> Res:
  match i:
    case Inf{st, +b, +out, +n, l, r}:
      match st:
        case SDone{}:
          Gz.trailer(Inflate.get32(Bits.align(b)), List.reverse(&2, U32, out), n)
        case SFull{}:
          RErr{30}
        case SErr{c}:
          RErr{c}
        case SHead{}:
          RErr{31}
        case SStored{x}:
          RErr{31}
        case SCodes{x, y}:
          RErr{31}

def Gz.body(+a: At, +room: U32) -> Res:
  match a:
    case At{+rest, k, +err}:
      Bool.pick(Res, U32.is_eq(err, 0), Gz.end(Inflate.stream(rest, room)), RErr{err})

# A gzip file, as the host inflates a kernel: its first member's output
# (no more than room), or an error.
def Inflate.gunzip(+src: +List<U32>, +room: U32) -> Res:
  Gz.body(Gz.head(src), room)
