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

# Proposed: a rotation's renames, planned in Bend (the host only reopens the
# log): the numbered logs move up from the oldest kept, then PATH becomes
# PATH.1; with keep 0, nothing moves.
law conlog.moves_keep3:
  {L.Log.moves("log", 3) == [L.Rename{"log.2", "log.3"}, L.Rename{"log.1", "log.2"}, L.Rename{"log", "log.1"}] : List<L.Rename>}

law conlog.moves_keep1:
  {L.Log.moves("log", 1) == [L.Rename{"log", "log.1"}] : List<L.Rename>}

law conlog.moves_keep0:
  {L.Log.moves("log", 0) == [] : List<L.Rename>}
