import Base
import ../laws/pack.bend as L
import ../src/disk/pack.bend as P

def L.pack.add_next(p, path, id):
  match p:
    case P.Pack{nm, es, nx, c}:
      {==}

def L.pack.drop_next(p, off):
  match p:
    case P.Pack{nm, es, nx, c}:
      {==}

def L.pack.drop_count(p, off):
  match p:
    case P.Pack{nm, es, nx, c}:
      {==}

def L.pack.slot_up():
  {==}

def L.pack.slot_exact():
  {==}

def L.pack.slot_empty():
  {==}

def L.pack.slot_big():
  {==}

def L.pack.entries():
  {==}

def L.pack.no_reuse():
  {==}

def L.pack.tiles():
  {==}

def L.pack.tiles_overlap():
  {==}

def L.pack.sectors():
  {==}

def L.pack.can_drop():
  {==}

def L.pack.can_drop_dead():
  {==}

def L.pack.can_drop_inside():
  {==}

def L.pack.split_tail():
  {==}

def L.pack.split_inside():
  {==}

def L.pack.split_dead():
  {==}

def L.pack.split_dead_next():
  {==}

def L.pack.split_past():
  {==}

def L.pack.split_empty_pack():
  {==}

def L.pack.split_none():
  {==}

def L.pack.slot_of():
  {==}

def L.pack.key_of():
  {==}

def L.pack.read_done():
  {==}

def L.pack.read_miss():
  {==}

def L.pack.read_short():
  {==}

def L.pack.same():
  {==}

def L.pack.same_changed():
  {==}

def L.pack.same_touched():
  {==}

def L.pack.same_gone():
  {==}

def L.pack.errno():
  {==}

def L.pack.dec():
  {==}

def L.pack.dec_zero():
  {==}

def L.pack.dec_max():
  {==}

def L.pack.parse():
  {==}

def L.pack.parse_big():
  {==}

def L.pack.parse_empty():
  {==}

def L.pack.parse_junk():
  {==}

def L.pack.parse_long():
  {==}

def L.pack.name():
  {==}

def L.pack.name_empty():
  {==}

def L.pack.name_slash():
  {==}

def L.pack.name_long():
  {==}

def L.pack.json():
  {==}

def L.pack.json_str():
  {==}
