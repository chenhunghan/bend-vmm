import Base
import ../laws/psci.bend as L
import ../src/arm64/psci.bend as P

def L.psci.boot():
  {==}

def L.psci.decode_version():
  {==}

def L.psci.decode_ignores_high_word():
  {==}

def L.psci.decode_cpu_on():
  {==}

def L.psci.decode_off():
  {==}

def L.psci.decode_reset():
  {==}

def L.psci.decode_features():
  {==}

def L.psci.decode_unknown():
  {==}

def L.psci.version():
  {==}

def L.psci.smccc_version():
  {==}

def L.psci.cpu_on_ok():
  {==}

def L.psci.cpu_on_already_on():
  {==}

def L.psci.cpu_on_out_of_range():
  {==}

def L.psci.cpu_off():
  {==}

def L.psci.affinity_on():
  {==}

def L.psci.affinity_off():
  {==}

def L.psci.system_off():
  {==}

def L.psci.system_reset():
  {==}

def L.psci.features_cpu_on():
  {==}

def L.psci.features_unknown():
  {==}

def L.psci.unsupported():
  {==}

def L.psci.migrate_info_type():
  {==}

def L.psci.system_off_x0():
  {==}

# Length lemmas. Each states {simple == computed} so that `%` rewrites the
# computed form back to the simple one.

law Len.set:
  for on: +List<Bool>
  for i: Nat
  for v: Bool
  {List.length(&2, Bool, on) == List.length(&2, Bool, P.Psci.set(on, i, v)) : Nat}

def Len.set(on, i, v):
  match on i:
    case Nil{} _:
      {==}
    case Con{b, t} 0n:
      {==}
    case Con{b, t} 1n+p:
      %Len.set(t, p, v) : {1n+List.length(&2, Bool, t) == 1n+_ : Nat}
      {==}

law Len.mark:
  for on: +List<Bool>
  for mi: Maybe<&2, Nat>
  for v: Bool
  {List.length(&2, Bool, on) == List.length(&2, Bool, P.Psci.mark(on, mi, v)) : Nat}

def Len.mark(on, mi, v):
  match mi:
    case None{}:
      {==}
    case Some{i}:
      Len.set(on, i, v)

def L.psci.handle_keeps_cpu_count(self, on, call):
  match call:
    case P.SmcccVersion{}:
      {==}
    case P.PsciVersion{}:
      {==}
    case P.CpuOff{}:
      %Len.set(on, U32.to_nat(self), False{}) : {_ == List.length(&2, Bool, on) : Nat}
      {==}
    case P.CpuOnCall{t, e, c}:
      %Len.mark(on, P.Psci.index(t), True{}) : {_ == List.length(&2, Bool, on) : Nat}
      {==}
    case P.AffinityInfo{t, l}:
      {==}
    case P.MigrateInfoType{}:
      {==}
    case P.SystemOff{}:
      {==}
    case P.SystemReset{}:
      {==}
    case P.Features{f}:
      {==}
    case P.Unsupported{f}:
      {==}
