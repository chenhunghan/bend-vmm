import Base
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V

# A CFI parallel NOR flash bank with the Intel/Sharp command set, as edk2's
# VirtNorFlashDxe drives QEMU's pflash_cfi01 on the "virt" machine: the UEFI
# variable store. Two 16-bit chips side by side make a 32-bit bus, so every
# command is written as a 32-bit word with the command in both halves, and
# every status reads back in both halves (0x00800080: ready).
#
# The bank's bytes live on the host (V.FlashCmd). In read-array mode the
# host maps them into the guest read-only, so reads (edk2 copies with ldp,
# which a trap could not decode) never trap and writes do; any other mode
# unmaps them so reads trap and see the mode's register. The model answers
# the host commands each write needs: FlashMap on entering or leaving
# read-array mode, FlashWrite for programmed words, FlashErase for a block.
#
# Modes: 0 read array, 1 read status, 2 read identifier, 3 CFI query,
# 4 word program (the next write is the data), 5 buffered program (the next
# write is the word count less one), 6 buffered data, 7 buffered confirm,
# 8 erase confirm, 9 lock/unlock confirm.
#
# Commands (low byte) in modes 0..3: 0xFF/0xF0 read array, 0x70 read status,
# 0x50 clear status (read array), 0x90 identifier, 0x98 query, 0x40/0x10
# word program, 0xE8 buffered program at the written address, 0x20 block
# erase at the written address, 0x60 lock setup; anything else reads status.
# Blocks are 256 KiB; buffered programs hold at most 32 words.

type Pflash is Data:
  Pflash{mode: U32, at: U32, count: U32, data: +List<U32>}

# A write's result: the new state and the host commands, in order.
type PfOut is Data:
  PfOut{flash: Pflash, cmds: +List<V.FlashCmd>}

def Pflash.new() -> Pflash:
  Pflash{0, 0, 0, []}

def Pflash.block_size() -> U32:
  262144

def Pflash.status() -> U32:
  8388736

# A value in both 16-bit halves.
def Pflash.dual(+x: U32) -> U32:
  ((x << 16n) .|. x : U32)

def Pflash.mode(f: Pflash) -> U32:
  match f:
    case Pflash{m, at, n, d}:
      m

# What a read at off answers in a mode that is not read array: the status,
# the identifier (manufacturer 0x89 at word 0, device 0x18 at word 1, block
# lock status 0, unlocked, at word 2 of a block), or the CFI query ("QRY" at
# words 16..18).
def Pflash.register(+mode: U32, off: U32) -> U32:
  +word = ((off .&. 262143) >> 2n : U32)
  Bool.pick(U32, U32.is_eq(mode, 2),
    Bool.pick(U32, U32.is_eq(word, 0), Pflash.dual(137), Bool.pick(U32, U32.is_eq(word, 1), Pflash.dual(24), 0)),
    Bool.pick(U32, U32.is_eq(mode, 3),
      Bool.pick(U32, U32.is_eq(word, 16), Pflash.dual(81), Bool.pick(U32, U32.is_eq(word, 17), Pflash.dual(82), Bool.pick(U32, U32.is_eq(word, 18), Pflash.dual(89), 0))),
      Pflash.status()))

# A read at off: None in read-array mode (the host's bytes answer it),
# else the register of the mode.
def Pflash.read(f: Pflash, off: U32) -> Maybe<&2, U32>:
  match f:
    case Pflash{+m, at, n, d}:
      Bool.pick(Maybe<&2, U32>, U32.is_eq(m, 0), None{}, Some{Pflash.register(m, off)})

# The mode a command selects (modes 0..3 accept commands).
def Pflash.command(+c: U32) -> U32:
  Bool.pick(U32, U32.is_eq(c, 255) || U32.is_eq(c, 240) || U32.is_eq(c, 80), 0,
  Bool.pick(U32, U32.is_eq(c, 112), 1,
  Bool.pick(U32, U32.is_eq(c, 144), 2,
  Bool.pick(U32, U32.is_eq(c, 152), 3,
  Bool.pick(U32, U32.is_eq(c, 64) || U32.is_eq(c, 16), 4,
  Bool.pick(U32, U32.is_eq(c, 232), 5,
  Bool.pick(U32, U32.is_eq(c, 32), 8,
  Bool.pick(U32, U32.is_eq(c, 96), 9, 1))))))))

def Pflash.block(+off: U32) -> U32:
  ((off >> 18n) << 18n : U32)

# The state after a write in mode m (the host commands follow separately).
def Pflash.next(+m: U32, +at: U32, +n: U32, +d: +List<U32>, +off: U32, +v: U32) -> Pflash:
  +c = (v .&. 255 : U32)
  Bool.pick(Pflash, U32.is_lt(m, 4), Pflash{Pflash.command(c), off, 0, []},
  Bool.pick(Pflash, U32.is_eq(m, 4), Pflash{1, 0, 0, []},
  Bool.pick(Pflash, U32.is_eq(m, 5), Pflash{6, at, ((c .&. 31) + 1 : U32), []},
  Bool.pick(Pflash, U32.is_eq(m, 6), Pflash{Bool.pick(U32, U32.is_eq(n, 1), 7, 6), at, (n - 1 : U32), List.append(&2, U32, d, B.Bytes.le32(v))},
  Pflash{1, 0, 0, []}))))

# The data commands of a write in mode m.
def Pflash.effects(+m: U32, +at: U32, +d: +List<U32>, +off: U32, +v: U32) -> +List<V.FlashCmd>:
  +confirm = U32.is_eq((v .&. 255 : U32), 208)
  Bool.pick(+List<V.FlashCmd>, U32.is_eq(m, 4), [V.FlashWrite{off, B.Bytes.le32(v)}],
  Bool.pick(+List<V.FlashCmd>, U32.is_eq(m, 7) && confirm, [V.FlashWrite{at, d}],
  Bool.pick(+List<V.FlashCmd>, U32.is_eq(m, 8) && confirm, [V.FlashErase{Pflash.block(at), Pflash.block_size()}], [])))

# FlashMap commands around a mode change: unmap before leaving read array,
# map after returning to it.
def Pflash.around(+was: U32, +now: U32, +cmds: +List<V.FlashCmd>) -> +List<V.FlashCmd>:
  +before = {Bool.pick(+List<V.FlashCmd>, U32.is_eq(was, 0) && U32.is_ne(now, 0), [V.FlashMap{False{}}], []) : +List<V.FlashCmd>}
  +after = {Bool.pick(+List<V.FlashCmd>, U32.is_ne(was, 0) && U32.is_eq(now, 0), [V.FlashMap{True{}}], []) : +List<V.FlashCmd>}
  List.append(&2, V.FlashCmd, before, List.append(&2, V.FlashCmd, cmds, after))

def Pflash.write.fin(+was: U32, f: Pflash, cmds: +List<V.FlashCmd>) -> PfOut:
  +f = f
  PfOut{f, Pflash.around(was, Pflash.mode(f), cmds)}

# A 32-bit write of v at offset off of the bank.
def Pflash.write(f: Pflash, +off: U32, +v: U32) -> PfOut:
  match f:
    case Pflash{+m, +at, +n, +d}:
      Pflash.write.fin(m, Pflash.next(m, at, n, d, off, v), Pflash.effects(m, at, d, off, v))
