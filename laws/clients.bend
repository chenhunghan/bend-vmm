import Base
import ../src/vmm/clients.bend as C

# Spec for src/vmm/clients.bend: a vsock client's CONNECT line.

law clients.connect:
  {C.Clients.connect_port([67, 79, 78, 78, 69, 67, 84, 32, 53, 48, 48, 48]) == Some{5000} : Maybe<&2, U32>}

law clients.connect_cr:
  {C.Clients.connect_port([67, 79, 78, 78, 69, 67, 84, 32, 50, 50, 13]) == Some{22} : Maybe<&2, U32>}

law clients.no_port:
  {C.Clients.connect_port([67, 79, 78, 78, 69, 67, 84, 32, 120]) == None{} : Maybe<&2, U32>}

law clients.other_verb:
  {C.Clients.connect_port([72, 69, 76, 76, 79, 32, 49]) == None{} : Maybe<&2, U32>}

law clients.deadline:
  {C.Clients.deadline_ms() == 5000 : U32}
