import Base
import ../lib/u64.bend as U

# The console log (--console-log PATH,max=BYTES[,keep=N]; laws/conlog.bend):
# the VMM writes the guest's console to PATH itself and, once it holds max
# bytes, renames it to PATH.1 (PATH.1 to PATH.2, ..., the oldest past keep
# dropped) and starts a new one. A guest that prints without end then takes
# at most (keep + 1) * max bytes of the host's disk.

# Whether the log of size bytes rotates (max 0: never).
def Log.rotate(+size: U.U64, +max: U.U64) -> Bool:
  Bool.not(U.U64.is_zero(max)) && U.U64.is_le(max, size)
