import Base
import ../virtio/input.bend as In
import ./keymap.bend as Km

# The display window's events as reports for the virtio keyboard and tablet
# (laws/pointer.bend). A pointer's position comes in pixels from the
# window's top left (past its edge while a button holds it); the tablet
# takes 0..32767 on each axis. Buttons come as W3C's (0 main, 1 middle,
# 2 right, ...); the tablet has left, right and middle (BTN_LEFT + 0, 1, 2:
# src/virtio/input.bend). A pointer taken away while pressed (Lost: the
# window lost the focus, a pen left its range) lets every button go, as no
# Press up will come for it.

# A pixel position as a whole pixel (0 left of or above the window). The
# laws take the pixels from here on: the checker does not evaluate F32.
def Ptr.pix(+v: F32) -> U32:
  Bool.pick(U32, F32.is_lt(v, 0.0), 0, F32.to_u32(v))

# A pixel as a window coordinate, 0..size-1.
def Ptr.clamp(+p: U32, +size: U32) -> U32:
  Bool.pick(U32, U32.is_lt(p, size), p, Bool.pick(U32, U32.is_zero(size), 0, (size - 1 : U32)))

# A window coordinate (0..size-1) on the tablet's 0..32767 scale. v * 32767
# fits a U32 below 131072; past that (a window wider than any framebuffer
# the host maps) the coordinate and the size lose their low 4 bits first.
def Ptr.scale(+v: U32, +size: U32) -> U32:
  +den = Bool.pick(U32, U32.is_lt(size, 2), 1, (size - 1 : U32))
  Bool.pick(U32, U32.is_lt(v, 131072), ((v * 32767 : U32) / den : U32),
    (((v >> 4n : U32) * 32767 : U32) / Bool.pick(U32, U32.is_zero((den >> 4n : U32)), 1, (den >> 4n : U32)) : U32))

# A W3C button as the tablet's, if it has it.
def Ptr.button(+b: U32) -> Maybe<&2, U32>:
  Bool.pick(Maybe<&2, U32>, U32.is_eq(b, 0), Some{0},
    Bool.pick(Maybe<&2, U32>, U32.is_eq(b, 1), Some{2},
      Bool.pick(Maybe<&2, U32>, U32.is_eq(b, 2), Some{1}, None{})))

def Ptr.press(b: Maybe<&2, U32>, down: Bool) -> +List<In.Hid>:
  match b:
    case None{}:
      []
    case Some{t}:
      [In.HidButton{t, down}]

# The tablet report for the pointer at pixel (x, y).
def Ptr.at(+x: U32, +y: U32, +w: U32, +h: U32) -> In.Hid:
  In.HidMove{Ptr.scale(Ptr.clamp(x, w), w), Ptr.scale(Ptr.clamp(y, h), h)}

# A button (W3C's b) pressed or let go with the pointer at pixel (x, y).
def Ptr.pressed(+x: U32, +y: U32, +w: U32, +h: U32, +b: U32, down: Bool) -> +List<In.Hid>:
  Ptr.at(x, y, w, h) <> Ptr.press(Ptr.button(b), down)

# The reports for one window event in a w x h window (none for Close, which
# the host handles, nor for Text, Scroll, Leave, Look and Focus).
def Ptr.hids(ev: Event, +w: U32, +h: U32) -> +List<In.Hid>:
  match ev:
    case Key{code, down}:
      [In.HidKey{Km.Keymap.linux(code), down}]
    case Press{id, tool, x, y, time, b, down}:
      Ptr.pressed(Ptr.pix(x), Ptr.pix(y), w, h, b, down)
    case Move{id, tool, x, y, time}:
      [Ptr.at(Ptr.pix(x), Ptr.pix(y), w, h)]
    case Lost{id}:
      [In.HidButton{0, False{}}, In.HidButton{1, False{}}, In.HidButton{2, False{}}]
    case _:
      []
