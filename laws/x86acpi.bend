import Base
import ../src/x86/acpi.bend as A

# Spec for src/x86/acpi.bend: the tables' checksums and lengths, and the
# AML they carry.

# Proposed: (a new module; every law here is proposed)

def len(bs: List<&2, U32>) -> Nat:
  List.length(&2, U32, bs)

law x86acpi.rsdp_sum:
  {A.Acpi.sum(A.Acpi.rsdp(917552)) == 0 : U32}

law x86acpi.rsdp_sum20:
  {A.Acpi.sum(List.take(&2, U32, A.Acpi.rsdp(917552), 20n)) == 0 : U32}

law x86acpi.fadt_len:
  {len(A.Acpi.fadt(917840)) == 276n : Nat}

law x86acpi.fadt_sum:
  {A.Acpi.sum(A.Acpi.fadt(917840)) == 0 : U32}

law x86acpi.madt_sum:
  {A.Acpi.sum(A.Acpi.madt(2)) == 0 : U32}

law x86acpi.dsdt_sum:
  {A.Acpi.sum(A.Acpi.dsdt(3)) == 0 : U32}

law x86acpi.xsdt_sum:
  {A.Acpi.sum(A.Acpi.xsdt([917616, 917904])) == 0 : U32}

law x86acpi.pkg1:
  {A.Aml.pkg(62) == [63] : List<&2, U32>}

law x86acpi.pkg2:
  {A.Aml.pkg(63) == [65, 4] : List<&2, U32>}

law x86acpi.pkg3:
  {A.Aml.pkg(4094) == [129, 0, 1] : List<&2, U32>}

law x86acpi.s5:
  {A.Aml.s5() == [8, 95, 83, 53, 95, 18, 5, 2, 10, 5, 0] : List<&2, U32>}

law x86acpi.seg:
  {A.Aml.seg(26) == "V01A" : String}
