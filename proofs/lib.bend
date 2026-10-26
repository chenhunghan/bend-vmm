import Base
import ../laws/lib.bend as L
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B

def L.lib.add_carry():
  {==}

def L.lib.sub_borrow():
  {==}

def L.lib.le32():
  {==}

def L.lib.be32():
  {==}

def L.lib.show_hex():
  {==}

# Word lemmas. Each states {simple == computed} so that `%` rewrites the
# computed form back to the simple one.

law W.cmp_refl:
  for n: Nat
  for a: Word(n)
  {EQ{} == Word.cmp(n, a, a) : Cmp}

def W.cmp_refl(n, a):
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{False{}, t}:
          %W.cmp_refl(p, t) : {EQ{} == Word.cmp.fin(False{}, False{}, _) : Cmp}
          {==}
        case WCon{True{}, t}:
          %W.cmp_refl(p, t) : {EQ{} == Word.cmp.fin(True{}, True{}, _) : Cmp}
          {==}

law W.add_zero:
  for n: Nat
  for a: Word(n)
  {a == Word.adc(n, a, Word.zero(n), False{}, False{}) : Word(n)}

def W.add_zero(n, a):
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{False{}, t}:
          %W.add_zero(p, t) : {WCon{False{}, t} == WCon{False{}, _} : Word(1n+p)}
          {==}
        case WCon{True{}, t}:
          %W.add_zero(p, t) : {WCon{True{}, t} == WCon{True{}, _} : Word(1n+p)}
          {==}

law W.sub_zero:
  for n: Nat
  for a: Word(n)
  {a == Word.adc(n, a, Word.zero(n), True{}, True{}) : Word(n)}

def W.sub_zero(n, a):
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{False{}, t}:
          %W.sub_zero(p, t) : {WCon{False{}, t} == WCon{False{}, _} : Word(1n+p)}
          {==}
        case WCon{True{}, t}:
          %W.sub_zero(p, t) : {WCon{True{}, t} == WCon{True{}, _} : Word(1n+p)}
          {==}

law W.sub_self:
  for n: Nat
  for a: Word(n)
  {Word.zero(n) == Word.adc(n, a, a, True{}, True{}) : Word(n)}

def W.sub_self(n, a):
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{False{}, t}:
          %W.sub_self(p, t) : {WCon{False{}, Word.zero(p)} == WCon{False{}, _} : Word(1n+p)}
          {==}
        case WCon{True{}, t}:
          %W.sub_self(p, t) : {WCon{False{}, Word.zero(p)} == WCon{False{}, _} : Word(1n+p)}
          {==}

# U32 lemmas, lifted from the Word lemmas.

law V.cmp_refl:
  for x: U32
  {EQ{} == U32.cmp(x, x) : Cmp}

def V.cmp_refl(x):
  match x:
    case U32{w}:
      W.cmp_refl(32n, w)

law V.add_zero:
  for x: U32
  {x == (x + 0 : U32) : U32}

def V.add_zero(x):
  match x:
    case U32{w}:
      %W.add_zero(32n, w) : {U32{w} == U32{_} : U32}
      {==}

law V.sub_zero:
  for x: U32
  {x == (x - 0 : U32) : U32}

def V.sub_zero(x):
  match x:
    case U32{w}:
      %W.sub_zero(32n, w) : {U32{w} == U32{_} : U32}
      {==}

law V.sub_self:
  for x: U32
  {0 == (x - x : U32) : U32}

def V.sub_self(x):
  match x:
    case U32{w}:
      %W.sub_self(32n, w) : {0 == U32{_} : U32}
      {==}

law V.and_comm:
  for a: Bool
  for b: Bool
  {Bool.and(a, b) == Bool.and(b, a) : Bool}

def V.and_comm(a, b):
  match a b:
    case False{} False{}:
      {==}
    case False{} True{}:
      {==}
    case True{} False{}:
      {==}
    case True{} True{}:
      {==}

# U64 laws.

def L.lib.add_zero(a):
  match a:
    case U.U64{+h, +l}:
      %V.add_zero(l) : {U.U64{U32.add(U32.add(h, 0), Bool.to_u32(Bool.and(U32.is_lt(_, l), U32.is_lt(_, 0)))), _} == U.U64{h, l} : U.U64}
      %V.cmp_refl(l) : {U.U64{U32.add(U32.add(h, 0), Bool.to_u32(Bool.and(Cmp.is_lt(_), U32.is_lt(l, 0)))), l} == U.U64{h, l} : U.U64}
      %V.add_zero(h) : {U.U64{U32.add(_, 0), l} == U.U64{h, l} : U.U64}
      %V.add_zero(h) : {U.U64{_, l} == U.U64{h, l} : U.U64}
      {==}

def L.lib.add_comm(a, b):
  match a b:
    case U.U64{+ah, +al} U.U64{+bh, +bl}:
      %U32.add_comm(al, bl) : {U.U64{U32.add(U32.add(ah, bh), Bool.to_u32(Bool.and(U32.is_lt(U32.add(al, bl), al), U32.is_lt(U32.add(al, bl), bl)))), U32.add(al, bl)} == U.U64{U32.add(U32.add(bh, ah), Bool.to_u32(Bool.and(U32.is_lt(_, bl), U32.is_lt(_, al)))), _} : U.U64}
      %U32.add_comm(ah, bh) : {U.U64{U32.add(U32.add(ah, bh), Bool.to_u32(Bool.and(U32.is_lt(U32.add(al, bl), al), U32.is_lt(U32.add(al, bl), bl)))), U32.add(al, bl)} == U.U64{U32.add(_, Bool.to_u32(Bool.and(U32.is_lt(U32.add(al, bl), bl), U32.is_lt(U32.add(al, bl), al)))), U32.add(al, bl)} : U.U64}
      %V.and_comm(U32.is_lt(U32.add(al, bl), al), U32.is_lt(U32.add(al, bl), bl)) : {U.U64{U32.add(U32.add(ah, bh), Bool.to_u32(Bool.and(U32.is_lt(U32.add(al, bl), al), U32.is_lt(U32.add(al, bl), bl)))), U32.add(al, bl)} == U.U64{U32.add(U32.add(ah, bh), Bool.to_u32(_)), U32.add(al, bl)} : U.U64}
      {==}

def L.lib.sub_self(a):
  match a:
    case U.U64{+h, +l}:
      %V.cmp_refl(l) : {U.U64{U32.sub(U32.sub(h, h), Bool.to_u32(Cmp.is_lt(_))), U32.sub(l, l)} == U.U64{0, 0} : U.U64}
      %V.sub_self(l) : {U.U64{U32.sub(U32.sub(h, h), 0), _} == U.U64{0, 0} : U.U64}
      %V.sub_self(h) : {U.U64{U32.sub(_, 0), 0} == U.U64{0, 0} : U.U64}
      %V.sub_zero(0) : {U.U64{_, 0} == U.U64{0, 0} : U.U64}
      {==}

# Bytes laws.

def L.lib.le32_length(x):
  {==}

law T.take_length:
  for xs: +List<U32>
  for n: Nat
  {Nat.is_le(List.length(&2, U32, List.take(&2, U32, xs, n)), n) == True{} : Bool}

def T.take_length(xs, n):
  match xs n:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+p:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      T.take_length(t, p)

def L.lib.slice_length(bs, n):
  match bs:
    case Nil{}:
      T.take_length(Nil{}, n)
    case h <> t:
      T.take_length(h <> t, n)

# Bool.or(b, False{}) on every bit: the normal form a byte round trip leaves.
def T.orf(n: Nat, w: Word(n)) -> Word(n):
  match n:
    case 0n:
      WNil{}
    case 1n+p:
      match w:
        case WCon{b, t}:
          WCon{Bool.or(b, False{}), T.orf(p, t)}

law T.orf_id:
  for n: Nat
  for w: Word(n)
  {w == T.orf(n, w) : Word(n)}

def T.orf_id(n, w):
  match n:
    case 0n:
      match w:
        case WNil{}:
          {==}
    case 1n+p:
      match w:
        case WCon{False{}, t}:
          %T.orf_id(p, t) : {WCon{False{}, t} == WCon{False{}, _} : Word(1n+p)}
          {==}
        case WCon{True{}, t}:
          %T.orf_id(p, t) : {WCon{True{}, t} == WCon{True{}, _} : Word(1n+p)}
          {==}

# Split into bits, both sides reduce to the same term.
law T.le32_bits:
  for w: Word(32n)
  {B.Bytes.read_le32(B.Bytes.le32(U32{w})) == U32{T.orf(32n, w)} : U32}

def T.le32_bits(w):
  match w:
    case WCon{b0, WCon{b1, WCon{b2, WCon{b3, WCon{b4, WCon{b5, WCon{b6, WCon{b7, WCon{b8, WCon{b9, WCon{b10, WCon{b11, WCon{b12, WCon{b13, WCon{b14, WCon{b15, WCon{b16, WCon{b17, WCon{b18, WCon{b19, WCon{b20, WCon{b21, WCon{b22, WCon{b23, WCon{b24, WCon{b25, WCon{b26, WCon{b27, WCon{b28, WCon{b29, WCon{b30, WCon{b31, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}

law T.be32_bits:
  for w: Word(32n)
  {B.Bytes.read_be32(B.Bytes.be32(U32{w})) == U32{T.orf(32n, w)} : U32}

def T.be32_bits(w):
  match w:
    case WCon{b0, WCon{b1, WCon{b2, WCon{b3, WCon{b4, WCon{b5, WCon{b6, WCon{b7, WCon{b8, WCon{b9, WCon{b10, WCon{b11, WCon{b12, WCon{b13, WCon{b14, WCon{b15, WCon{b16, WCon{b17, WCon{b18, WCon{b19, WCon{b20, WCon{b21, WCon{b22, WCon{b23, WCon{b24, WCon{b25, WCon{b26, WCon{b27, WCon{b28, WCon{b29, WCon{b30, WCon{b31, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}

def L.lib.le32_roundtrip(x):
  match x:
    case U32{+w}:
      %Equal.sym(Word(32n), w, T.orf(32n, w), T.orf_id(32n, w)) : {B.Bytes.read_le32(B.Bytes.le32(U32{w})) == U32{_} : U32}
      T.le32_bits(w)

def L.lib.be32_roundtrip(x):
  match x:
    case U32{+w}:
      %Equal.sym(Word(32n), w, T.orf(32n, w), T.orf_id(32n, w)) : {B.Bytes.read_be32(B.Bytes.be32(U32{w})) == U32{_} : U32}
      T.be32_bits(w)
