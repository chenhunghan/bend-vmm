#!/usr/bin/env python3
"""Differential test of src/lib/inflate.bend against zlib, as the host uses it.

usage: tests/oracles/inflate.py [--seed N] [--random N] [--emit FILE]

Builds a corpus of gzip files and raw deflate streams, valid and malformed:
stored, fixed and dynamic blocks at every level, overlapping
back-references, gzip headers with extra/name/comment/header CRC, empty
input, then truncations, bit flips, bad stored lengths, bad block types,
bad flags and CRCs, and trailing bytes. Each case's expected answer comes
from libz called exactly as host/hvf.c's hvf_inflate calls it (ctypes:
inflateInit2_ with 31 for gzip, -12 for raw; one inflate call over all of
`room`; raw output after an error still counts). The Bend decoder runs
every case in one generated program (out/inflate-oracle/) and must give the
same output (length and CRC-32) or fail where zlib fails.

--emit FILE writes the fixed part of the corpus (inputs up to 1 KiB) as a
Bend test instead (tests/inflate.bend is made this way).
"""
import ctypes, ctypes.util, os, random, subprocess, sys, zlib

# zlib, as hvf_inflate calls it
class ZStream(ctypes.Structure):
    _fields_ = [("next_in", ctypes.c_void_p), ("avail_in", ctypes.c_uint), ("total_in", ctypes.c_ulong),
                ("next_out", ctypes.c_void_p), ("avail_out", ctypes.c_uint), ("total_out", ctypes.c_ulong),
                ("msg", ctypes.c_char_p), ("state", ctypes.c_void_p), ("zalloc", ctypes.c_void_p),
                ("zfree", ctypes.c_void_p), ("opaque", ctypes.c_void_p), ("data_type", ctypes.c_int),
                ("adler", ctypes.c_ulong), ("reserved", ctypes.c_ulong)]

def load_libz():
    for name in ("/usr/lib/libz.1.dylib", "libz.so.1", ctypes.util.find_library("z")):
        if name:
            try:
                return ctypes.CDLL(name)
            except OSError:
                pass
    sys.exit("inflate.py: no libz")

Z = load_libz()
Z.inflateInit2_.argtypes = [ctypes.POINTER(ZStream), ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
Z.inflate.argtypes = [ctypes.POINTER(ZStream), ctypes.c_int]
Z.inflateEnd.argtypes = [ctypes.POINTER(ZStream)]

def host(src, room, bits):
    """hvf_inflate: the output, or None."""
    z = ZStream()
    inp = ctypes.create_string_buffer(bytes(src), max(len(src), 1))
    out = ctypes.create_string_buffer(max(room, 1))
    z.next_in = ctypes.cast(inp, ctypes.c_void_p)
    z.avail_in = len(src)
    if Z.inflateInit2_(ctypes.byref(z), bits, b"1.2.12", ctypes.sizeof(z)) != 0:
        return None
    done, r = 0, 0
    while r == 0 and done < room:
        z.next_out = ctypes.c_void_p(ctypes.addressof(out) + done)
        z.avail_out = room - done
        before = z.avail_out
        r = Z.inflate(ctypes.byref(z), 0)
        done += before - z.avail_out
    Z.inflateEnd(ctypes.byref(z))
    return out.raw[:done] if r == 1 or (bits < 0 and done > 0) else None

# the corpus
def raw(data, level=6, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()

def gz(data, level=6, name=None, extra=None, comment=None, hcrc=False, mtime=0):
    flg = (4 if extra is not None else 0) | (8 if name is not None else 0) | (16 if comment is not None else 0) | (2 if hcrc else 0)
    h = bytes([31, 139, 8, flg]) + mtime.to_bytes(4, "little") + bytes([0, 3])
    if extra is not None:
        h += len(extra).to_bytes(2, "little") + extra
    if name is not None:
        h += name + b"\0"
    if comment is not None:
        h += comment + b"\0"
    if hcrc:
        h += (zlib.crc32(h) & 65535).to_bytes(2, "little")
    return h + raw(data, level) + zlib.crc32(data).to_bytes(4, "little") + (len(data) & 0xffffffff).to_bytes(4, "little")

def texts(rng):
    words = [b"bend", b"vmm", b"guest", b"host", b"kernel", b"virtio", b"\n", b" ", b"0123456789"]
    yield "empty", b""
    yield "one", b"x"
    yield "abc", b"abcabcabcabcabcabcabcabc"
    yield "run", b"a" * 1000
    yield "words", b"".join(rng.choice(words) for _ in range(600))
    yield "bytes", bytes(rng.randrange(256) for _ in range(700))
    yield "mixed", b"".join(rng.choice(words) if rng.random() < 0.7 else bytes([rng.randrange(256)]) for _ in range(800))
    yield "far", bytes(rng.randrange(256) for _ in range(300)) + b"filler" * 400 + bytes(rng.randrange(256) for _ in range(300))

def corpus(rng):
    cases = []  # (name, kind, bytes, room)
    for tname, t in texts(rng):
        room = len(t) + 64
        for lv in (0, 1, 6, 9):
            cases.append((f"gz-{tname}-l{lv}", "gz", gz(t, lv), room))
            cases.append((f"raw-{tname}-l{lv}", "raw", raw(t, lv), room))
        cases.append((f"raw-{tname}-fixed", "raw", raw(t, 6, zlib.Z_FIXED), room))
        cases.append((f"raw-{tname}-huffman", "raw", raw(t, 6, zlib.Z_HUFFMAN_ONLY), room))
        cases.append((f"raw-{tname}-rle", "raw", raw(t, 6, zlib.Z_RLE), room))
    t = b"".join(bytes([rng.randrange(97, 100)]) for _ in range(500))
    cases.append(("gz-header-all", "gz", gz(t, 6, name=b"vmlinux", extra=b"\1\2\3\4", comment=b"bend", hcrc=True), 600))
    cases.append(("gz-header-name", "gz", gz(t, 9, name=b"Image"), 600))
    cases.append(("gz-room-exact", "gz", gz(t), 500))
    cases.append(("gz-room-short", "gz", gz(t), 499))
    cases.append(("raw-room-short", "raw", raw(t), 100))
    cases.append(("gz-trailing", "gz", gz(t) + b"garbage", 600))
    g = bytearray(gz(t))
    cases.append(("gz-bad-magic", "gz", bytes([31, 140]) + bytes(g[2:]), 600))
    cases.append(("gz-bad-method", "gz", bytes(g[:2]) + bytes([7]) + bytes(g[3:]), 600))
    cases.append(("gz-bad-flags", "gz", bytes(g[:3]) + bytes([32]) + bytes(g[4:]), 600))
    h = bytearray(gz(t, hcrc=True)); h[10] ^= 1
    cases.append(("gz-bad-hcrc", "gz", bytes(h), 600))
    c = bytearray(g); c[-8] ^= 1
    cases.append(("gz-bad-crc", "gz", bytes(c), 600))
    c = bytearray(g); c[-4] ^= 1
    cases.append(("gz-bad-size", "gz", bytes(c), 600))
    for cut in (1, 5, 10, 11, 20, len(g) // 2, len(g) - 9, len(g) - 4, len(g) - 1):
        cases.append((f"gz-cut-{cut}", "gz", bytes(g[:cut]), 600))
    r = raw(t)
    for cut in (0, 1, 2, len(r) // 3, len(r) // 2, len(r) - 1):
        cases.append((f"raw-cut-{cut}", "raw", r[:cut], 600))
    # stored block with a bad NLEN; block type 3; a distance too far back
    cases.append(("raw-stored-ok", "raw", bytes([1, 5, 0, 250, 255]) + b"hello", 64))
    cases.append(("raw-stored-bad-nlen", "raw", bytes([1, 5, 0, 251, 255]) + b"hello", 64))
    cases.append(("raw-btype3", "raw", bytes([7, 0, 0]), 64))
    # fixed block: literal 'a' (0x61 -> code 0x91, 8 bits), then length 3 at
    # distance 2 (only 1 byte written: too far back)
    cases.append(("raw-too-far", "raw", fixed_block([("lit", 97), ("match", 3, 2)]), 64))
    cases.append(("raw-overlap", "raw", fixed_block([("lit", 97), ("lit", 98), ("match", 10, 2)]), 64))
    cases.append(("raw-lit-then-bad", "raw", fixed_block([("lit", 97), ("lit", 98), ("sym", 286)]), 64))
    cases.append(("raw-bad-dist-code", "raw", fixed_block([("lit", 97), ("lit", 98), ("lit", 99), ("baddist", 3)]), 64))
    return cases

class BitW:
    def __init__(self): self.bits, self.n = 0, 0
    def put(self, v, k):  # k bits, low first
        self.bits |= v << self.n; self.n += k
    def code(self, c, k):  # a Huffman code, high bit first
        for i in range(k - 1, -1, -1): self.put((c >> i) & 1, 1)
    def bytes(self): return self.bits.to_bytes((self.n + 7) // 8, "little")

def fixed_sym(w, s):
    if s < 144: w.code(0x30 + s, 8)
    elif s < 256: w.code(0x190 + s - 144, 9)
    elif s < 280: w.code(s - 256, 7)
    else: w.code(0xc0 + s - 280, 8)

def fixed_block(ops):
    w = BitW(); w.put(1, 1); w.put(1, 2)
    for op in ops:
        if op[0] == "lit": fixed_sym(w, op[1])
        elif op[0] == "sym": fixed_sym(w, op[1])
        elif op[0] == "match":
            assert 3 <= op[1] <= 10 and op[2] <= 4
            fixed_sym(w, 254 + op[1]); w.code(op[2] - 1, 5)
        elif op[0] == "baddist":
            fixed_sym(w, 254 + op[1]); w.code(30, 5)
    if ops[-1][0] in ("lit", "match"): fixed_sym(w, 256)
    return w.bytes()

def mutate(rng, b):
    b = bytearray(b)
    for _ in range(rng.randrange(1, 4)):
        if b: b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
    return bytes(b)

def random_cases(rng, n):
    out = []
    for i in range(n):
        t = bytes(rng.choice(b"abcde \n") for _ in range(rng.randrange(1, 400)))
        if rng.random() < 0.5:
            out.append((f"rnd-gz-{i}", "gz", mutate(rng, gz(t, rng.choice((1, 6, 9)))), len(t) + 16))
        else:
            out.append((f"rnd-raw-{i}", "raw", mutate(rng, raw(t, rng.choice((1, 6, 9)))), len(t) + 16))
    return out

def expect(kind, src, room):
    return host(src, room, 31 if kind == "gz" else -12)

def bend_list(b):
    # a long list literal overflows Bend's stack when it expands: chunks of
    # 256, joined by cat (tail-recursive, in the generated program)
    chunks = [b[i:i + 256] for i in range(0, len(b), 256)] or [b""]
    return "cat([" + ", ".join("[" + ", ".join(str(x) for x in c) + "]" for c in chunks) + "])"

CAT = """def cat.rev(xs: +List<U32>, +acc: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      cat.rev(rest, Con{x, acc})

def cat.go(xss: List<+List<U32>>, +acc: +List<U32>) -> +List<U32>:
  match xss:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case Con{xs, rest}:
      cat.go(rest, cat.rev(xs, acc))

def cat(xss: List<+List<U32>>) -> +List<U32>:
  cat.go(xss, [])
"""

def program(cases, imp):
    lines = ["import Base", f"import {imp} as I", "",
             "def show(+r: I.Res) -> String:", "  match r:", "    case I.ROk{+out}:",
             '      "ok " ++ U32.show(U32.from_nat(List.length(&2, U32, out))) ++ " " ++ U32.show(I.Crc.of(out))',
             "    case I.RErr{c}:", '      "err"', "", CAT]
    body = []
    for i, (name, kind, src, room) in enumerate(cases):
        fn = "I.Inflate.gunzip" if kind == "gz" else "I.Inflate.raw"
        lines += [f"def c{i}() -> String:", f"  show({fn}({bend_list(src)}, {room}))", ""]
        body.append(f'    IO.print("{i} " ++ c{i}())')
    return "\n".join(lines + ["def main() -> IO(Unit):", "  do IO<Unit>:"] + body) + "\n"

def want_line(i, w):
    return f"{i} err" if w is None else f"{i} ok {len(w)} {zlib.crc32(w)}"

def emit(path, cases):
    lines = ["import Base", "import ../src/lib/inflate.bend as I", "import ./t.bend as T", "",
             "# Made by tests/oracles/inflate.py --emit: each case's answer is zlib's, as",
             "# host/hvf.c calls it (the output's length and CRC-32, or an error).", "",
             "def got(+r: I.Res) -> String:", "  match r:", "    case I.ROk{+out}:",
             '      "ok " ++ U32.show(U32.from_nat(List.length(&2, U32, out))) ++ " " ++ U32.show(I.Crc.of(out))',
             "    case I.RErr{c}:", '      "err"', "", CAT]
    body = []
    for i, (name, kind, src, room) in enumerate(cases):
        w = expect(kind, src, room)
        want = "err" if w is None else f"ok {len(w)} {zlib.crc32(w)}"
        fn = "I.Inflate.gunzip" if kind == "gz" else "I.Inflate.raw"
        lines += [f"def c{i}() -> String:", f"  got({fn}({bend_list(src)}, {room}))", ""]
        body.append(f'    T.eq_str("inflate: {name}", c{i}(), "{want}")')
    open(path, "w").write("\n".join(lines + ["def main() -> IO(Unit):", "  do IO<Unit>:"] + body) + "\n")

def main(argv):
    seed, nrand, out = 1, 200, None
    while argv:
        if argv[0] == "--seed": seed = int(argv[1]); argv = argv[2:]
        elif argv[0] == "--random": nrand = int(argv[1]); argv = argv[2:]
        elif argv[0] == "--emit": out = argv[1]; argv = argv[2:]
        else: sys.exit(__doc__)
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rng = random.Random(seed)
    cases = corpus(rng)
    if out:
        # the committed test keeps the cases up to 1 KiB of input (the
        # oracle run takes them all)
        small = [c for c in cases if len(c[2]) <= 1024]
        emit(out, small)
        print(f"wrote {len(small)} cases to {out}")
        return 0
    cases += random_cases(rng, nrand)
    d = os.path.join(root, "out", "inflate-oracle")
    os.makedirs(d, exist_ok=True)
    prog = os.path.join(d, "oracle.bend")
    open(prog, "w").write(program(cases, os.path.join(root, "src", "lib", "inflate.bend")))
    r = subprocess.run(["bend", prog], capture_output=True, text=True)
    got = {}
    for line in r.stdout.splitlines():
        i, _, rest = line.partition(" ")
        if i.isdigit(): got[int(i)] = f"{i} {rest}"
    bad = 0
    for i, (name, kind, src, room) in enumerate(cases):
        w = want_line(i, expect(kind, src, room))
        if got.get(i) != w:
            bad += 1
            print(f"DIFF {name}: bend {got.get(i, '(none) ' + r.stderr[-200:])!r}, zlib {w!r}")
    print(f"{len(cases) - bad} of {len(cases)} cases agree with zlib")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
