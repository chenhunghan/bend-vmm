import Base
import ../src/dev/keymap.bend as K
import ../src/virtio/input.bend as In

# Frozen spec for src/dev/keymap.bend (codes from linux/input-event-codes.h).

law keymap.a:
  {K.Keymap.linux(97) == 30 : U32}

law keymap.z:
  {K.Keymap.linux(122) == 44 : U32}

law keymap.one:
  {K.Keymap.linux(49) == 2 : U32}

law keymap.bang_is_one:
  {K.Keymap.linux(33) == 2 : U32}

law keymap.enter:
  {K.Keymap.linux(13) == 28 : U32}

law keymap.backspace:
  {K.Keymap.linux(127) == 14 : U32}

law keymap.space:
  {K.Keymap.linux(32) == 57 : U32}

law keymap.up:
  {K.Keymap.linux(63232) == 103 : U32}

law keymap.f12:
  {K.Keymap.linux(63247) == 88 : U32}

law keymap.left_shift:
  {K.Keymap.linux(65592) == 42 : U32}

law keymap.left_control:
  {K.Keymap.linux(65595) == 29 : U32}

law keymap.unknown:
  {K.Keymap.linux(9731) == 0 : U32}

law keymap.type_lower:
  {K.Keymap.typing([108, 115], False{}) == [In.HidKey{38, True{}}, In.HidKey{38, False{}}, In.HidKey{31, True{}}, In.HidKey{31, False{}}] : +List<In.Hid>}

law keymap.type_capital:
  {K.Keymap.typing([65], False{}) == [In.HidKey{42, True{}}, In.HidKey{30, True{}}, In.HidKey{30, False{}}, In.HidKey{42, False{}}] : +List<In.Hid>}

law keymap.type_bang:
  {K.Keymap.typing([33], False{}) == [In.HidKey{42, True{}}, In.HidKey{2, True{}}, In.HidKey{2, False{}}, In.HidKey{42, False{}}] : +List<In.Hid>}

law keymap.type_return:
  {K.Keymap.typing([92, 110], False{}) == [In.HidKey{28, True{}}, In.HidKey{28, False{}}] : +List<In.Hid>}

law keymap.type_backslash:
  {K.Keymap.typing([92, 92], False{}) == [In.HidKey{43, True{}}, In.HidKey{43, False{}}] : +List<In.Hid>}

law keymap.type_untypable:
  {K.Keymap.typing([7], False{}) == [] : +List<In.Hid>}
