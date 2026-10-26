import Base
import ../virtio/input.bend as In

# Bend's window key codes (Event Key{code, down}) to Linux input key codes
# (linux/input-event-codes.h), for the virtio-input keyboard. On macOS a key
# is the lowercase character it types (Shift still applies, so '!' is the
# key of '1'), the function keys are Apple's private-use characters
# (U+F700 on: the arrows 63232..63235, F1 63236), and a modifier is
# 65536 + its Mac key code (Shift 56, Control 59, Option 58, Command 55, their
# right-hand twins 60, 62, 61, 54, Caps Lock 57).

type KeyPair is Data:
  KeyPair{code: U32, key: U32}

def Keymap.table() -> +List<KeyPair>:
  [
    KeyPair{27, 1}, KeyPair{49, 2}, KeyPair{50, 3}, KeyPair{51, 4}, KeyPair{52, 5},
    KeyPair{53, 6}, KeyPair{54, 7}, KeyPair{55, 8}, KeyPair{56, 9}, KeyPair{57, 10},
    KeyPair{48, 11}, KeyPair{45, 12}, KeyPair{61, 13}, KeyPair{127, 14}, KeyPair{9, 15},
    KeyPair{113, 16}, KeyPair{119, 17}, KeyPair{101, 18}, KeyPair{114, 19}, KeyPair{116, 20},
    KeyPair{121, 21}, KeyPair{117, 22}, KeyPair{105, 23}, KeyPair{111, 24}, KeyPair{112, 25},
    KeyPair{91, 26}, KeyPair{93, 27}, KeyPair{13, 28}, KeyPair{97, 30}, KeyPair{115, 31},
    KeyPair{100, 32}, KeyPair{102, 33}, KeyPair{103, 34}, KeyPair{104, 35}, KeyPair{106, 36},
    KeyPair{107, 37}, KeyPair{108, 38}, KeyPair{59, 39}, KeyPair{39, 40}, KeyPair{96, 41},
    KeyPair{92, 43}, KeyPair{122, 44}, KeyPair{120, 45}, KeyPair{99, 46}, KeyPair{118, 47},
    KeyPair{98, 48}, KeyPair{110, 49}, KeyPair{109, 50}, KeyPair{44, 51}, KeyPair{46, 52},
    KeyPair{47, 53}, KeyPair{32, 57},
    # shifted punctuation: the key under it
    KeyPair{33, 2}, KeyPair{64, 3}, KeyPair{35, 4}, KeyPair{36, 5}, KeyPair{37, 6},
    KeyPair{94, 7}, KeyPair{38, 8}, KeyPair{42, 9}, KeyPair{40, 10}, KeyPair{41, 11},
    KeyPair{95, 12}, KeyPair{43, 13}, KeyPair{123, 26}, KeyPair{125, 27}, KeyPair{58, 39},
    KeyPair{34, 40}, KeyPair{126, 41}, KeyPair{124, 43}, KeyPair{60, 51}, KeyPair{62, 52},
    KeyPair{63, 53},
    # arrows, navigation, F1..F12
    KeyPair{63232, 103}, KeyPair{63233, 108}, KeyPair{63234, 105}, KeyPair{63235, 106},
    KeyPair{63273, 102}, KeyPair{63275, 107}, KeyPair{63276, 104}, KeyPair{63277, 109},
    KeyPair{63271, 110}, KeyPair{63272, 111},
    KeyPair{63236, 59}, KeyPair{63237, 60}, KeyPair{63238, 61}, KeyPair{63239, 62},
    KeyPair{63240, 63}, KeyPair{63241, 64}, KeyPair{63242, 65}, KeyPair{63243, 66},
    KeyPair{63244, 67}, KeyPair{63245, 68}, KeyPair{63246, 87}, KeyPair{63247, 88},
    # modifiers: 65536 + Mac key code
    KeyPair{65592, 42}, KeyPair{65596, 54}, KeyPair{65595, 29}, KeyPair{65598, 97},
    KeyPair{65594, 56}, KeyPair{65597, 100}, KeyPair{65591, 125}, KeyPair{65590, 126},
    KeyPair{65593, 58}
  ]

def Keymap.find(ps: +List<KeyPair>, +code: U32) -> U32:
  match ps:
    case Nil{}:
      0
    case Con{KeyPair{c, +k}, rest}:
      Bool.pick(U32, U32.is_eq(c, code), k, Keymap.find(rest, code))

# The Linux key code of a window key code; 0 for keys it does not know.
def Keymap.linux(code: U32) -> U32:
  Keymap.find(Keymap.table(), code)

# Characters typed with Shift: the capitals and the shifted punctuation.
def Keymap.has(xs: +List<U32>, +c: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      U32.is_eq(x, c) || Keymap.has(rest, c)

def Keymap.shifted(+c: U32) -> Bool:
  (U32.is_lt(64, c) && U32.is_lt(c, 91)) || Keymap.has([33, 64, 35, 36, 37, 94, 38, 42, 40, 41, 95, 43, 123, 125, 58, 34, 126, 124, 60, 62, 63], c)

def Keymap.tap(shift: Bool, +key: U32) -> +List<In.Hid>:
  match shift:
    case True{}:
      [In.HidKey{42, True{}}, In.HidKey{key, True{}}, In.HidKey{key, False{}}, In.HidKey{42, False{}}]
    case False{}:
      [In.HidKey{key, True{}}, In.HidKey{key, False{}}]

# The key reports that type one character (none for one it cannot type).
def Keymap.press(+c: U32) -> +List<In.Hid>:
  +key = Keymap.linux(Bool.pick(U32, U32.is_lt(64, c) && U32.is_lt(c, 91), (c + 32 : U32), c))
  Bool.pick(+List<In.Hid>, U32.is_eq(key, 0), [], Keymap.tap(Keymap.shifted(c), key))

# The key reports that type a text (character codes), with backslash
# escapes: \n is Return, a backslash before anything else types that.
def Keymap.typing(bs: +List<U32>, esc: Bool) -> +List<In.Hid>:
  match bs esc:
    case Nil{} _:
      []
    case Con{+c, rest} True{}:
      List.append(&2, In.Hid, Keymap.press(Bool.pick(U32, U32.is_eq(c, 110), 13, c)), Keymap.typing(rest, False{}))
    case Con{+c, rest} False{}:
      List.append(&2, In.Hid, Bool.pick(+List<In.Hid>, U32.is_eq(c, 92), [], Keymap.press(c)), Keymap.typing(rest, U32.is_eq(c, 92)))
