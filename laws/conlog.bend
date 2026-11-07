import Base
import ../src/lib/u64.bend as U
import ../src/dev/conlog.bend as L

# Spec for src/dev/conlog.bend: when the console log rotates.

law conlog.under:
  {L.Log.rotate(U.U64{0, 67108863}, U.U64{0, 67108864}) == False{} : Bool}

law conlog.at_max:
  {L.Log.rotate(U.U64{0, 67108864}, U.U64{0, 67108864}) == True{} : Bool}

law conlog.never:
  {L.Log.rotate(U.U64{1, 0}, U.U64{0, 0}) == False{} : Bool}
