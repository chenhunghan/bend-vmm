import Base

# A 64-bit word as two U32 halves. Bend has no U64, and arm64 guest addresses,
# registers and syndrome values are 64 bits wide.
type U64 is Data:
  U64{hi: U32, lo: U32}

def U64.zero() -> U64:
  U64{0, 0}

def U64.from_u32(x: U32) -> U64:
  U64{0, x}

def U64.make(hi: U32, lo: U32) -> U64:
  U64{hi, lo}

def U64.hi(a: U64) -> U32:
  match a:
    case U64{h, l}:
      h

def U64.lo(a: U64) -> U32:
  match a:
    case U64{h, l}:
      l

def U64.add(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, +al} U64{bh, bl}:
      +lo = (al + bl : U32)
      carry = Bool.to_u32(U32.is_lt(lo, al))
      U64{(ah + bh + carry : U32), lo}

def U64.sub(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, +al} U64{bh, +bl}:
      borrow = Bool.to_u32(U32.is_lt(al, bl))
      U64{(ah - bh - borrow : U32), (al - bl : U32)}

def U64.add_u32(a: U64, x: U32) -> U64:
  U64.add(a, U64{0, x})

def U64.and(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64{(ah .&. bh : U32), (al .&. bl : U32)}

def U64.or(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64{(ah .|. bh : U32), (al .|. bl : U32)}

def U64.xor(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64{(ah .^. bh : U32), (al .^. bl : U32)}

def U64.not(a: U64) -> U64:
  match a:
    case U64{h, l}:
      U64{U32.not(h), U32.not(l)}

# Shift left by one bit.
def U64.shl1(a: U64) -> U64:
  match a:
    case U64{h, +l}:
      U64{((h << 1n) .|. (l >> 31n) : U32), (l << 1n : U32)}

# Shift right by one bit (logical).
def U64.shr1(a: U64) -> U64:
  match a:
    case U64{+h, l}:
      U64{(h >> 1n : U32), ((l >> 1n) .|. (h << 31n) : U32)}

# Shift left by n bits; n >= 64 gives zero.
def U64.shl(n: Nat, a: U64) -> U64:
  match n:
    case 0n:
      a
    case 1n+p:
      U64.shl(p, U64.shl1(a))

# Shift right (logical) by n bits; n >= 64 gives zero.
def U64.shr(n: Nat, a: U64) -> U64:
  match n:
    case 0n:
      a
    case 1n+p:
      U64.shr(p, U64.shr1(a))

def U64.cmp.fin(c: Cmp, al: U32, bl: U32) -> Cmp:
  match c:
    case EQ{}:
      U32.cmp(al, bl)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

def U64.cmp(a: U64, b: U64) -> Cmp:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64.cmp.fin(U32.cmp(ah, bh), al, bl)

def U64.is_eq(a: U64, b: U64) -> Bool:
  Cmp.is_eq(U64.cmp(a, b))

def U64.is_lt(a: U64, b: U64) -> Bool:
  Cmp.is_lt(U64.cmp(a, b))

def U64.is_le(a: U64, b: U64) -> Bool:
  Cmp.is_le(U64.cmp(a, b))

def U64.is_zero(a: U64) -> Bool:
  match a:
    case U64{h, l}:
      U32.is_zero(h) && U32.is_zero(l)

# Bits [lo, lo+width) of a, with width <= 32, as a U32.
def U64.bits(a: U64, lo: Nat, width: Nat) -> U32:
  mask = U32.not((4294967295 << width : U32))
  (U64.lo(U64.shr(lo, a)) .&. mask : U32)

# Round a up to a multiple of 2^k.
def U64.align_up(k: Nat, a: U64) -> U64:
  +k = k
  +mask = U64.sub(U64.shl(k, U64{0, 1}), U64{0, 1})
  U64.and(U64.add(a, mask), U64.not(mask))

def U64.hex_digit(+d: U32) -> Char:
  Char.from_u32((Bool.pick(U32, U32.is_lt(d, 10), 48, 87) + d : U32))

# The n low nibbles of x, most significant first.
def U64.nibbles(n: Nat, +x: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      +p = p
      ((x >> Nat.mul(p, 4n)) .&. 15 : U32) <> U64.nibbles(p, x)

# [0] for an empty list, else the list itself.
def U64.nonempty(ds: +List<U32>) -> +List<U32>:
  match ds:
    case Nil{}:
      [0]
    case Con{d, rest}:
      d <> rest

def U64.strip_zeros.go(ds: +List<U32>) -> +List<U32>:
  match ds:
    case Nil{}:
      []
    case Con{+d, +rest}:
      Bool.pick(+List<U32>, U32.is_zero(d), U64.strip_zeros.go(rest), d <> rest)

def U64.hex_list(ds: +List<U32>) -> String:
  match ds:
    case Nil{}:
      ""
    case Con{d, rest}:
      SCon{U64.hex_digit(d), U64.hex_list(rest)}

# Lowercase hex with a 0x prefix and no leading zeros (0 is "0x0").
def U64.show_hex(a: U64) -> String:
  match a:
    case U64{+h, +l}:
      ds = List.append(&2, U32, U64.nibbles(8n, h), U64.nibbles(8n, l))
      "0x" ++ U64.hex_list(U64.nonempty(U64.strip_zeros.go(ds)))
