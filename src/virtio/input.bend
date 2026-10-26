import Base
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ./queue.bend as Q

# virtio-input (Virtio 1.2 section 5.8), device id 18, two queues: 0 eventq
# (device to driver), 1 statusq (driver to device: LEDs, which are dropped).
# Two flavours: a keyboard (EV_KEY for Linux key codes 1..247) and a tablet
# (absolute ABS_X/ABS_Y in 0..32767 and the left, right and middle buttons).
#
# Config space, 136 bytes: select u8, subsel u8, size u8, 5 reserved bytes,
# then a 128-byte union the driver reads after writing select and subsel:
#   ID_NAME 1:     the device name
#   ID_DEVIDS 3:   bustype BUS_VIRTUAL (6), vendor 0, product 1 keyboard /
#                  2 tablet, version 1 (le16 each)
#   EV_BITS 17:    the code bitmap of event type subsel (EV_KEY 1, EV_ABS 3)
#   ABS_INFO 18:   for the tablet's axes 0 and 1: min 0, max 32767, fuzz,
#                  flat and resolution 0 (le32 each)
# anything else has size 0.
#
# An event is 8 bytes: type le16, code le16, value le32; each eventq chain
# takes one. Every report ends with EV_SYN/SYN_REPORT (all zeros).

# What the host saw: a key (a Linux key code; 0 is no key), the pointer at
# (x, y) scaled to 0..32767, a mouse button (0 left, 1 right, 2 middle).
type Hid is Data:
  HidKey{code: U32, down: Bool}
  HidMove{x: U32, y: U32}
  HidButton{button: U32, down: Bool}

# The device's selector and the events not yet delivered, oldest first.
type InputState is Data:
  InputState{sel: U32, subsel: U32, events: +List<+List<U32>>}

# What an eventq pass did.
type InRx is Data:
  InRx{s: InputState, q: Q.Vq, used: Bool}

def Input.max_events() -> Nat:
  512n

def InputState.new() -> InputState:
  InputState{0, 0, []}

def Input.event(t: U32, code: U32, value: U32) -> +List<U32>:
  List.append(&2, U32, B.Bytes.le16(t), List.append(&2, U32, B.Bytes.le16(code), B.Bytes.le32(value)))

def Input.syn() -> +List<U32>:
  Input.event(0, 0, 0)

# The events of one report on the keyboard (tablet False) or the tablet.
def Input.events.kbd(ev: Hid) -> +List<+List<U32>>:
  match ev:
    case HidKey{+code, down}:
      Bool.pick(+List<+List<U32>>, U32.is_eq(code, 0), [], [Input.event(1, code, Bool.to_u32(down)), Input.syn()])
    case HidMove{x, y}:
      []
    case HidButton{b, down}:
      []

def Input.events.tablet(ev: Hid) -> +List<+List<U32>>:
  match ev:
    case HidKey{code, down}:
      []
    case HidMove{x, y}:
      [Input.event(3, 0, x), Input.event(3, 1, y), Input.syn()]
    case HidButton{b, down}:
      [Input.event(1, (272 + b : U32), Bool.to_u32(down)), Input.syn()]

def Input.events(tablet: Bool, ev: Hid) -> +List<+List<U32>>:
  match tablet:
    case True{}:
      Input.events.tablet(ev)
    case False{}:
      Input.events.kbd(ev)

# Queues the events of a report, keeping the last Input.max_events().
def Input.push(tablet: Bool, s: InputState, ev: Hid) -> InputState:
  match s:
    case InputState{sel, sub, evs}:
      +all = List.append(&2, +List<U32>, evs, Input.events(tablet, ev))
      InputState{sel, sub, List.drop(&2, +List<U32>, all, Nat.sub(List.length(&2, +List<U32>, all), Input.max_events()))}

# Config space
# ============

def Input.name(tablet: Bool) -> +List<U32>:
  match tablet:
    case True{}:
      B.Bytes.of_string("bend-vmm tablet")
    case False{}:
      B.Bytes.of_string("bend-vmm keyboard")

def Input.devids(tablet: Bool) -> +List<U32>:
  +ids = {[B.Bytes.le16(6), B.Bytes.le16(0), B.Bytes.le16(Bool.pick(U32, tablet, 2, 1)), B.Bytes.le16(1)] : +List<+List<U32>>}
  List.concat(&2, U32, ids)

# Key codes 1..247: bit 0 clear, then 247 set bits.
def Input.key_bits() -> +List<U32>:
  254 <> List.replicate(U32, 30n, 255)

def Input.ev_bits(tablet: Bool, +subsel: U32) -> +List<U32>:
  match tablet:
    case True{}:
      Bool.pick(+List<U32>, U32.is_eq(subsel, 1), List.append(&2, U32, B.Bytes.zeros(34n), [7]), Bool.pick(+List<U32>, U32.is_eq(subsel, 3), [3], []))
    case False{}:
      Bool.pick(+List<U32>, U32.is_eq(subsel, 1), Input.key_bits(), [])

def Input.abs_info(tablet: Bool, +subsel: U32) -> +List<U32>:
  match tablet:
    case True{}:
      Bool.pick(+List<U32>, U32.is_lt(subsel, 2), List.append(&2, U32, B.Bytes.le32(0), List.append(&2, U32, B.Bytes.le32(32767), B.Bytes.zeros(12n))), [])
    case False{}:
      []

# The union's bytes for a selector.
def Input.payload(+tablet: Bool, +sel: U32, +subsel: U32) -> +List<U32>:
  Bool.pick(+List<U32>, U32.is_eq(sel, 1), Input.name(tablet),
    Bool.pick(+List<U32>, U32.is_eq(sel, 3), Input.devids(tablet),
      Bool.pick(+List<U32>, U32.is_eq(sel, 17), Input.ev_bits(tablet, subsel),
        Bool.pick(+List<U32>, U32.is_eq(sel, 18), Input.abs_info(tablet, subsel), []))))

def Input.config(tablet: Bool, +sel: U32, +subsel: U32) -> +List<U32>:
  +p = Input.payload(tablet, sel, subsel)
  +n = List.length(&2, U32, p)
  +head = {[(sel .&. 255 : U32), (subsel .&. 255 : U32), U32.from_nat(n), 0, 0, 0, 0, 0] : +List<U32>}
  List.append(&2, U32, head, List.append(&2, U32, p, B.Bytes.zeros(Nat.sub(128n, n))))

# The config space of a state.
def InputState.config(tablet: Bool, s: InputState) -> +List<U32>:
  match s:
    case InputState{sel, sub, evs}:
      Input.config(tablet, sel, sub)

# A driver write of v at config byte off (0 select, 1 subsel; others are
# read-only).
def Input.select(s: InputState, +off: U32, +v: U32) -> InputState:
  match s:
    case InputState{sel, sub, evs}:
      InputState{Bool.pick(U32, U32.is_eq(off, 0), (v .&. 255 : U32), sel), Bool.pick(U32, U32.is_eq(off, 1), (v .&. 255 : U32), sub), evs}

# Queues
# ======

# Writes one event into a chain and pushes it used.
def Input.rx.serve(-R: Type, q: Q.Vq, c: Q.Chain, ev: +List<U32>) -> V.Op<R, Q.Vq>:
  match c:
    case Q.Chain{+h, r, w}:
      do V.Op<R, Q.Vq>:
        n : U32 <- Q.Vq.scatter(R, Q.Chain{h, [], w}, ev)
        Q.Vq.push(R, q, h, n)

def Input.rx.step(
  -R: Type, sel: U32, sub: U32, r: Q.Vq & Maybe<&2, Q.Chain>, ev: +List<U32>, rest: +List<+List<U32>>, used: Bool,
  k: Q.Vq & +List<+List<U32>> -> V.Op<R, InRx>
) -> V.Op<R, InRx>:
  match r:
    case (q, None{}):
      V.Op.pure(R, InRx, InRx{InputState{sel, sub, ev <> rest}, q, used})
    case (q, Some{c}):
      V.Op.bind(R, Q.Vq, InRx, Input.rx.serve(R, q, c, ev), q2 => k((q2, rest)))

def Input.rx.go(fuel: Nat, -R: Type, +sel: U32, +sub: U32, st: Q.Vq & +List<+List<U32>>, used: Bool) -> V.Op<R, InRx>:
  match fuel:
    case 0n:
      match st:
        case (q, evs):
          V.Op.pure(R, InRx, InRx{InputState{sel, sub, evs}, q, used})
    case 1n+f:
      match st:
        case (q, Nil{}):
          V.Op.pure(R, InRx, InRx{InputState{sel, sub, []}, q, used})
        case (q, Con{e, es}):
          do V.Op<R, InRx>:
            r : Q.Vq & Maybe<&2, Q.Chain> <- Q.Vq.pop(R, q)
            Input.rx.step(R, sel, sub, r, e, es, used, st2 => Input.rx.go(f, R, sel, sub, st2, True{}))

# Delivers pending events into eventq, one per available chain (at most
# num), until they run out. Answers the state with the events left, the
# queue, and whether any chain was used.
def Input.rx(-R: Type, s: InputState, q: Q.Vq) -> V.Op<R, InRx>:
  match s q:
    case InputState{sel, sub, evs} Q.Vq{+num, d, dr, dv, na, nu}:
      Input.rx.go(U32.to_nat(num), R, sel, sub, (Q.Vq{num, d, dr, dv, na, nu}, evs), False{})

# The number of events not yet delivered.
def InputState.pending(s: InputState) -> Nat:
  match s:
    case InputState{sel, sub, evs}:
      List.length(&2, +List<U32>, evs)
