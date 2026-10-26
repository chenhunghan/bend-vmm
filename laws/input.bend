import Base
import ../src/lib/bytes.bend as B
import ../src/virtio/input.bend as In

# Frozen spec for src/virtio/input.bend (virtio 1.2 section 5.8; Linux
# drivers/virtio/virtio_input.c reads the config this way).

def zs(n: Nat) -> +List<U32>:
  B.Bytes.zeros(n)

def syn() -> +List<U32>:
  [0, 0, 0, 0, 0, 0, 0, 0]

law input.config_size:
  {List.length(&2, U32, In.Input.config(True{}, 17, 1)) == 136n : Nat}

law input.name_keyboard:
  {In.Input.config(False{}, 1, 0) == List.append(&2, U32, [1, 0, 17, 0, 0, 0, 0, 0], List.append(&2, U32, B.Bytes.of_string("bend-vmm keyboard"), zs(111n))) : +List<U32>}

law input.devids_tablet:
  {In.Input.config(True{}, 3, 0) == List.append(&2, U32, [3, 0, 8, 0, 0, 0, 0, 0, 6, 0, 0, 0, 2, 0, 1, 0], zs(120n)) : +List<U32>}

law input.keyboard_keys:
  {In.Input.config(False{}, 17, 1) == List.append(&2, U32, [17, 1, 31, 0, 0, 0, 0, 0, 254], List.append(&2, U32, List.replicate(U32, 30n, 255), zs(97n))) : +List<U32>}

law input.keyboard_no_abs:
  {In.Input.config(False{}, 17, 3) == List.append(&2, U32, [17, 3], zs(134n)) : +List<U32>}

law input.tablet_buttons:
  {In.Input.config(True{}, 17, 1) == List.append(&2, U32, [17, 1, 35, 0, 0, 0, 0, 0], List.append(&2, U32, zs(34n), 7 <> zs(93n))) : +List<U32>}

law input.tablet_axes:
  {In.Input.config(True{}, 17, 3) == List.append(&2, U32, [17, 3, 1, 0, 0, 0, 0, 0, 3], zs(127n)) : +List<U32>}

law input.tablet_abs_y:
  {In.Input.config(True{}, 18, 1) == List.append(&2, U32, [18, 1, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 127, 0, 0], zs(120n)) : +List<U32>}

law input.tablet_no_abs_z:
  {In.Input.config(True{}, 18, 2) == List.append(&2, U32, [18, 2], zs(134n)) : +List<U32>}

law input.unknown_select:
  {In.Input.config(True{}, 0, 0) == zs(136n) : +List<U32>}

law input.select_then_subsel:
  {In.Input.select(In.Input.select(In.InputState.new(), 0, 17), 1, 259) == In.InputState{17, 3, []} : In.InputState}

law input.key_down:
  {In.Input.events(False{}, In.HidKey{30, True{}}) == [[1, 0, 30, 0, 1, 0, 0, 0], syn()] : +List<+List<U32>>}

law input.key_up:
  {In.Input.events(False{}, In.HidKey{28, False{}}) == [[1, 0, 28, 0, 0, 0, 0, 0], syn()] : +List<+List<U32>>}

law input.no_key:
  {In.Input.events(False{}, In.HidKey{0, True{}}) == [] : +List<+List<U32>>}

law input.keyboard_ignores_pointer:
  {In.Input.events(False{}, In.HidMove{1, 2}) == [] : +List<+List<U32>>}

law input.tablet_ignores_keys:
  {In.Input.events(True{}, In.HidKey{30, True{}}) == [] : +List<+List<U32>>}

law input.move:
  {In.Input.events(True{}, In.HidMove{300, 32767}) == [[3, 0, 0, 0, 44, 1, 0, 0], [3, 0, 1, 0, 255, 127, 0, 0], syn()] : +List<+List<U32>>}

law input.right_button:
  {In.Input.events(True{}, In.HidButton{1, True{}}) == [[1, 0, 17, 1, 1, 0, 0, 0], syn()] : +List<+List<U32>>}

law input.push_appends:
  {In.Input.push(False{}, In.InputState{17, 1, [[9]]}, In.HidKey{1, False{}}) == In.InputState{17, 1, [[9], [1, 0, 1, 0, 0, 0, 0, 0], syn()]} : In.InputState}

law input.push_caps:
  {In.InputState.pending(In.Input.push(False{}, In.InputState{0, 0, List.replicate(+List<U32>, 511n, [5])}, In.HidKey{1, True{}})) == 512n : Nat}
