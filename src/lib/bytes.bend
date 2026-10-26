import Base
import ./u64.bend as U

# Byte strings are `+List<U32>`, one byte (0..255) per element. Bend has no U8,
# and a reusable list keeps device code free of ownership plumbing.

def Bytes.zeros(n: Nat) -> +List<U32>:
  List.replicate(U32, n, 0)

# The low n bytes of x, least significant first (n <= 4). The mask comes first
# in `.&.` so that the proofs of the round trips reduce bit by bit.
def Bytes.le(n: Nat, +x: U32) -> +List<U32>:
  match n:
    case 0n:
      []
    case 1n+p:
      (255 .&. x : U32) <> Bytes.le(p, (x >> 8n : U32))

# The low n bytes of x, most significant first (n <= 4).
def Bytes.be(n: Nat, x: U32) -> +List<U32>:
  List.reverse(&2, U32, Bytes.le(n, x))

def Bytes.le16(x: U32) -> +List<U32>:
  Bytes.le(2n, x)

def Bytes.le32(x: U32) -> +List<U32>:
  Bytes.le(4n, x)

def Bytes.be32(x: U32) -> +List<U32>:
  Bytes.be(4n, x)

def Bytes.le64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      List.append(&2, U32, Bytes.le32(l), Bytes.le32(h))

def Bytes.be64(a: U.U64) -> +List<U32>:
  match a:
    case U.U64{h, l}:
      List.append(&2, U32, Bytes.be32(h), Bytes.be32(l))

# Reads up to 4 bytes little-endian; missing bytes read as zero.
def Bytes.read_le(n: Nat, bs: +List<U32>) -> U32:
  match n:
    case 0n:
      0
    case 1n+p:
      match bs:
        case Nil{}:
          0
        case Con{b, rest}:
          ((255 .&. b) .|. (Bytes.read_le(p, rest) << 8n) : U32)

# Reads up to 4 bytes big-endian; missing bytes read as zero.
def Bytes.read_be(+n: Nat, bs: +List<U32>) -> U32:
  Bytes.read_le(n, List.reverse(&2, U32, List.take(&2, U32, bs, n)))

def Bytes.read_le32(bs: +List<U32>) -> U32:
  Bytes.read_le(4n, bs)

def Bytes.read_le16(bs: +List<U32>) -> U32:
  Bytes.read_le(2n, bs)

def Bytes.read_be32(bs: +List<U32>) -> U32:
  Bytes.read_be(4n, bs)

def Bytes.read_le64(+bs: +List<U32>) -> U.U64:
  U.U64{Bytes.read_le32(List.drop(&2, U32, bs, 4n)), Bytes.read_le32(bs)}

# len bytes starting at off; short when the list ends first.
def Bytes.slice(bs: +List<U32>, off: Nat, len: Nat) -> +List<U32>:
  List.take(&2, U32, List.drop(&2, U32, bs, off), len)

# The low byte of each character code.
def Bytes.of_string(s: String) -> +List<U32>:
  match s:
    case SNil{}:
      []
    case SCon{c, rest}:
      (Char.to_u32(c) .&. 255 : U32) <> Bytes.of_string(rest)

# A NUL-terminated C string.
def Bytes.of_cstring(s: String) -> +List<U32>:
  List.append(&2, U32, Bytes.of_string(s), [0])

def Bytes.pad_len.fin(aligned: Bool, m: Nat, r: Nat) -> Nat:
  match aligned:
    case True{}:
      0n
    case False{}:
      Nat.sub(m, r)

# Zero bytes that pad a length n up to a multiple of 2^k.
def Bytes.pad_len(k: Nat, n: Nat) -> Nat:
  +k = k
  +m = Nat.pow(2n, k)
  +r = Nat.mod(n, m)
  Bytes.pad_len.fin(Nat.is_eq(r, 0n), m, r)

# bs followed by zeros up to a multiple of 2^k bytes.
def Bytes.pad(k: Nat, +bs: +List<U32>) -> +List<U32>:
  List.append(&2, U32, bs, Bytes.zeros(Bytes.pad_len(k, List.length(&2, U32, bs))))
