import Base
import ../src/dev/escape.bend as E

# Spec for src/dev/escape.bend: the console's Ctrl-A keys.

def on() -> E.Esc:
  E.Esc.new(True{})

law escape.plain:
  {E.Esc.feed([104, 105, 10], on()) == (E.Esc{True{}, False{}}, [E.KBytes{[104, 105, 10]}]) : E.Esc & +List<E.Key>}

law escape.pause_between_bytes:
  {E.Esc.feed([104, 1, 112, 105], on()) == (E.Esc{True{}, False{}}, [E.KBytes{[104]}, E.KPause{}, E.KBytes{[105]}]) : E.Esc & +List<E.Key>}

law escape.quit:
  {E.Esc.feed([1, 120], on()) == (E.Esc{True{}, False{}}, [E.KQuit{}]) : E.Esc & +List<E.Key>}

law escape.snapshot_and_help:
  {E.Esc.feed([1, 115, 1, 104], on()) == (E.Esc{True{}, False{}}, [E.KSnap{}, E.KHelp{}]) : E.Esc & +List<E.Key>}

law escape.double_ctrl_a:
  {E.Esc.feed([1, 1, 97], on()) == (E.Esc{True{}, False{}}, [E.KBytes{[1, 97]}]) : E.Esc & +List<E.Key>}

law escape.other_key:
  {E.Esc.feed([1, 113], on()) == (E.Esc{True{}, False{}}, [E.KBytes{[1, 113]}]) : E.Esc & +List<E.Key>}

law escape.armed_across_chunks:
  {E.Esc.feed([104, 1], on()) == (E.Esc{True{}, True{}}, [E.KBytes{[104]}]) : E.Esc & +List<E.Key>}

law escape.armed_then_key:
  {E.Esc.feed([112, 106], E.Esc{True{}, True{}}) == (E.Esc{True{}, False{}}, [E.KPause{}, E.KBytes{[106]}]) : E.Esc & +List<E.Key>}

law escape.piped_passes_ctrl_a:
  {E.Esc.feed([1, 120], E.Esc.new(False{})) == (E.Esc{False{}, False{}}, [E.KBytes{[1, 120]}]) : E.Esc & +List<E.Key>}
