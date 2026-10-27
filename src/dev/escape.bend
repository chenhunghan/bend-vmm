import Base

# The host console's escape keys. When the console is a terminal (active),
# Ctrl-A (1) arms the escape and the next key acts: x quits, p pauses or
# resumes, s takes a snapshot, h lists the keys, Ctrl-A sends one Ctrl-A to
# the guest, any other key goes to the guest after its Ctrl-A. An escape
# armed at the end of one chunk of input acts on the first key of the next.
# Piped input (inactive) goes to the guest as it is. Every other byte goes
# to the guest; consecutive ones stay together.

type Esc is Data:
  Esc{active: Bool, armed: Bool}

type Key is Data:
  # Bytes for the guest.
  KBytes{bs: +List<U32>}
  KQuit{}
  KPause{}
  KSnap{}
  KHelp{}

def Esc.new(active: Bool) -> Esc:
  Esc{active, False{}}

def Esc.active(e: Esc) -> Bool:
  match e:
    case Esc{active, armed}:
      active

def Key.bytes.new(+bs: +List<U32>, +ks: +List<Key>) -> +List<Key>:
  Bool.pick(+List<Key>, List.is_empty(&2, U32, bs), ks, KBytes{bs} <> ks)

def Key.bytes.on(+bs: +List<U32>, k: Key, rest: +List<Key>) -> +List<Key>:
  match k:
    case KBytes{more}:
      KBytes{List.append(&2, U32, bs, more)} <> rest
    case k:
      Key.bytes.new(bs, k <> rest)

# Prepends guest bytes, joining a KBytes that follows.
def Key.bytes(+bs: +List<U32>, ks: +List<Key>) -> +List<Key>:
  match ks:
    case Nil{}:
      Key.bytes.new(bs, [])
    case Con{k, rest}:
      Key.bytes.on(bs, k, rest)

# The key an armed escape makes of c: an action, or bytes.
def Esc.act(+c: U32) -> Key:
  Bool.pick(Key, U32.is_eq(c, 120), KQuit{},
    Bool.pick(Key, U32.is_eq(c, 112), KPause{},
      Bool.pick(Key, U32.is_eq(c, 115), KSnap{},
        Bool.pick(Key, U32.is_eq(c, 104), KHelp{},
          Bool.pick(Key, U32.is_eq(c, 1), KBytes{[1]}, KBytes{[1, c]})))))

def Esc.prepend(k: Key, ks: +List<Key>) -> +List<Key>:
  match k:
    case KBytes{bs}:
      Key.bytes(bs, ks)
    case k:
      k <> ks

# The keys a step emits (none or one) before the rest's.
def Esc.after(emit: +List<Key>, r: Esc & +List<Key>) -> Esc & +List<Key>:
  match r:
    case (e2, ks):
      (e2, List.foldr(~&2, ~Key, ~+List<Key>, ~Esc.prepend, emit, ks))

def Esc.feed.go(bs: +List<U32>, +active: Bool, +armed: Bool) -> Esc & +List<Key>:
  match bs:
    case Nil{}:
      (Esc{active, armed}, [])
    case Con{+c, t}:
      +arms = Bool.not(armed) && active && U32.is_eq(c, 1)
      +emit = Bool.pick(+List<Key>, armed, [Esc.act(c)], Bool.pick(+List<Key>, arms, [], [KBytes{[c]}]))
      Esc.after(emit, Esc.feed.go(t, active, arms))

# Feeds a chunk of console input: the escape's state after it and the keys,
# in order.
def Esc.feed(bs: +List<U32>, e: Esc) -> Esc & +List<Key>:
  match e:
    case Esc{active, armed}:
      Esc.feed.go(bs, active, armed)
