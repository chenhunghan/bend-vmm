import Base
import ./u64.bend as U

# A decoder over a stream of 32-bit words, used for snapshots. Dec<A> reads
# an A from the front of the stream and hands back the rest, or fails (None).
# Like Op, its bind needs no recursion, so `do Dec<A>:` blocks pass Bend's
# termination check; loops take a Nat count.

type Dec<-A: Type> is Type:
  Dec{run: +List<U32> -> Maybe<&1, A & +List<U32>>}

def Dec.pure(-A: Type, x: A) -> Dec<A>:
  Dec{ws => Some{(x, ws)}}

def Dec.fail(-A: Type) -> Dec<A>:
  Dec{ws => None{}}

def Dec.run(-A: Type, d: Dec<A>, ws: +List<U32>) -> Maybe<&1, A & +List<U32>>:
  match d:
    case Dec{r}:
      r(ws)

def Dec.bind.got(-A: Type, -B: Type, r: Maybe<&1, A & +List<U32>>, f: A -> Dec<B>) -> Maybe<&1, B & +List<U32>>:
  match r:
    case None{}:
      None{}
    case Some{(x, rest)}:
      Dec.run(B, f(x), rest)

def Dec.bind(-A: Type, -B: Type, m: Dec<A>, f: A -> Dec<B>) -> Dec<B>:
  Dec{ws => Dec.bind.got(A, B, Dec.run(A, m, ws), f)}

def Dec.u32.go(ws: +List<U32>) -> Maybe<&1, U32 & +List<U32>>:
  match ws:
    case Nil{}:
      None{}
    case Con{w, rest}:
      Some{(w, rest)}

def Dec.u32() -> Dec<U32>:
  Dec{ws => Dec.u32.go(ws)}

def Dec.u64() -> Dec<U.U64>:
  do Dec<U.U64>:
    h : U32 <- Dec.u32()
    l : U32 <- Dec.u32()
    return U.U64{h, l}

def Dec.bool.of(w: U32) -> Dec<Bool>:
  Dec.pure(Bool, U32.is_ne(w, 0))

def Dec.bool() -> Dec<Bool>:
  do Dec<Bool>:
    w : U32 <- Dec.u32()
    Dec.bool.of(w)

# n words.
def Dec.words(n: Nat) -> Dec<+List<U32>>:
  match n:
    case 0n:
      Dec.pure(+List<U32>, [])
    case 1n+p:
      do Dec<+List<U32>>:
        w : U32 <- Dec.u32()
        ws : +List<U32> <- Dec.words(p)
        return w <> ws

# A length-prefixed list of words (bytes, in practice).
def Dec.bytes() -> Dec<+List<U32>>:
  do Dec<+List<U32>>:
    n : U32 <- Dec.u32()
    Dec.words(U32.to_nat(n))

def Dec.chars(n: Nat) -> Dec<String>:
  match n:
    case 0n:
      Dec.pure(String, "")
    case 1n+p:
      do Dec<String>:
        c : U32 <- Dec.u32()
        s : String <- Dec.chars(p)
        return SCon{Char.from_u32(c), s}

# A length-prefixed string of character codes.
def Dec.string() -> Dec<String>:
  do Dec<String>:
    n : U32 <- Dec.u32()
    Dec.chars(U32.to_nat(n))

# Encoders, the inverses: words in the same order.
def Enc.u64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      [h, l]

def Enc.bool(b: Bool) -> +List<U32>:
  [Bool.to_u32(b)]

def Enc.bytes(+bs: +List<U32>) -> +List<U32>:
  U32.from_nat(List.length(&2, U32, bs)) <> bs

def Enc.chars(s: String) -> +List<U32>:
  match s:
    case SNil{}:
      []
    case SCon{c, rest}:
      Char.to_u32(c) <> Enc.chars(rest)

def Enc.string(+s: String) -> +List<U32>:
  U32.from_nat(String.length(s)) <> Enc.chars(s)
