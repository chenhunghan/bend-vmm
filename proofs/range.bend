import Base
import ../src/host/range.bend as R
import ../laws/range.bend as L

def L.range.last_page():
  {==}

def L.range.past_end():
  {==}

def L.range.below():
  {==}

def L.range.no_wrap():
  {==}

def L.range.whole():
  {==}

def L.range.empty_at_end():
  {==}

def L.range.one_out():
  {==}

def L.range.split_total():
  {==}

def L.range.split_contiguous():
  {==}

def L.range.split_pieces():
  {==}

def L.range.advance_mid():
  {==}

def L.range.advance_piece():
  {==}

def L.range.advance_all():
  {==}

def L.range.advance_total():
  {==}

def L.range.advance_zero(ps):
  match ps:
    case Nil{}:
      {==}
    case Con{p, rest}:
      match p:
        case R.Piece{g, len}:
          {==}
