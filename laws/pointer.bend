import Base
import ../src/virtio/input.bend as In
import ../src/dev/keymap.bend as Km
import ../src/dev/pointer.bend as P

# Spec for src/dev/pointer.bend: the display window's events as keyboard
# and tablet reports, in a 640 x 480 window. Pointer positions are taken
# from whole pixels (Ptr.pix turns the window's F32 into one; the checker
# does not evaluate F32).

law pointer.press_main:
  {P.Ptr.pressed(0, 0, 640, 480, 0, True{}) == [In.HidMove{0, 0}, In.HidButton{0, True{}}] : +List<In.Hid>}

law pointer.release_right:
  {P.Ptr.pressed(639, 479, 640, 480, 2, False{}) == [In.HidMove{32767, 32767}, In.HidButton{1, False{}}] : +List<In.Hid>}

law pointer.press_middle:
  {P.Ptr.pressed(0, 0, 640, 480, 1, True{}) == [In.HidMove{0, 0}, In.HidButton{2, True{}}] : +List<In.Hid>}

# a button the tablet does not have only moves the pointer
law pointer.press_back:
  {P.Ptr.pressed(0, 0, 640, 480, 3, True{}) == [In.HidMove{0, 0}] : +List<In.Hid>}

law pointer.at_middle:
  {P.Ptr.at(319, 239, 640, 480) == In.HidMove{16357, 16349} : In.Hid}

# past the window's edge (a button held): clamped to it
law pointer.at_past_edge:
  {P.Ptr.at(9000, 480, 640, 480) == In.HidMove{32767, 32767} : In.Hid}

# a pointer taken away while pressed lets every button go
law pointer.lost:
  {P.Ptr.hids(Lost{0}, 640, 480) == [In.HidButton{0, False{}}, In.HidButton{1, False{}}, In.HidButton{2, False{}}] : +List<In.Hid>}

law pointer.key:
  {P.Ptr.hids(Key{4, True{}}, 640, 480) == [In.HidKey{Km.Keymap.linux(4), True{}}] : +List<In.Hid>}

law pointer.focus:
  {P.Ptr.hids(Focus{False{}}, 640, 480) == [] : +List<In.Hid>}

law pointer.close:
  {P.Ptr.hids(Close{}, 640, 480) == [] : +List<In.Hid>}

law pointer.scale_ends:
  {[P.Ptr.scale(0, 640), P.Ptr.scale(639, 640)] == [0, 32767] : +List<U32>}

law pointer.scale_one_pixel:
  {P.Ptr.scale(0, 1) == 0 : U32}

# a coordinate past 131071 does not wrap
law pointer.scale_wide:
  {P.Ptr.scale(199999, 200000) == 32767 : U32}

law pointer.clamp_empty:
  {P.Ptr.clamp(5, 0) == 0 : U32}
