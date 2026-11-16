import Base
import ../src/lib/u64.bend as U
import ../src/lib/bytes.bend as B
import ../src/x86/acpi.bend as A
import ./t.bend as T

# Tests for src/x86/acpi.bend: lengths, checksums, and the bytes of the AML.

def len(bs: +List<U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

def at(bs: +List<U32>, off: Nat, n: Nat) -> String:
  List.show(~&2, ~U32, ~U32.show, B.Bytes.slice(bs, off, n))

def main() -> IO(Unit):
  do IO<Unit>:
    T.eq_u32("rsdp length", len(A.Acpi.rsdp(917552)), 36)
    T.eq_u32("rsdp sum 20", A.Acpi.sum(List.take(&2, U32, A.Acpi.rsdp(917552), 20n)), 0)
    T.eq_u32("rsdp sum 36", A.Acpi.sum(A.Acpi.rsdp(917552)), 0)
    T.eq_u32("fadt length", len(A.Acpi.fadt(1000000)), 276)
    T.eq_u32("fadt sum", A.Acpi.sum(A.Acpi.fadt(1000000)), 0)
    T.eq_str("fadt flags", at(A.Acpi.fadt(1000000), 108n, 8n), "[50, 12, 0, 0, 49, 4, 16, 0]")
    T.eq_str("fadt reset", at(A.Acpi.fadt(1000000), 116n, 13n), "[1, 8, 0, 1, 2, 6, 0, 0, 0, 0, 0, 0, 1]")
    T.eq_str("fadt sleep", at(A.Acpi.fadt(1000000), 244n, 13n), "[1, 8, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0, 1]")
    T.eq_str("fadt x_dsdt", at(A.Acpi.fadt(1000000), 140n, 8n), "[64, 66, 15, 0, 0, 0, 0, 0]")
    T.eq_u32("madt length 2 cpus", len(A.Acpi.madt(2)), 188)
    T.eq_u32("madt sum", A.Acpi.sum(A.Acpi.madt(4)), 0)
    T.eq_str("pkg 1 byte", List.show(~&2, ~U32, ~U32.show, A.Aml.pkg(62)), "[63]")
    T.eq_str("pkg 2 bytes", List.show(~&2, ~U32, ~U32.show, A.Aml.pkg(63)), "[65, 4]")
    T.eq_str("pkg 3 bytes", List.show(~&2, ~U32, ~U32.show, A.Aml.pkg(4094)), "[129, 0, 1]")
    T.eq_str("s5", List.show(~&2, ~U32, ~U32.show, A.Aml.s5()), "[8, 95, 83, 53, 95, 18, 5, 2, 10, 5, 0]")
    T.eq_str("seg", A.Aml.seg(26), "V01A")
    T.eq_str("virtio 1", List.show(~&2, ~U32, ~U32.show, A.Aml.virtio(1)), "[91, 130, 59, 86, 48, 48, 49, 8, 95, 72, 73, 68, 13, 76, 78, 82, 79, 48, 48, 48, 53, 0, 8, 95, 85, 73, 68, 10, 1, 8, 95, 67, 82, 83, 17, 26, 10, 23, 134, 9, 0, 1, 0, 2, 0, 208, 0, 2, 0, 0, 137, 6, 0, 1, 1, 6, 0, 0, 0, 121, 0]")
    T.eq_u32("dsdt sum", A.Acpi.sum(A.Acpi.dsdt(10)), 0)
    +ts : +List<U32> = A.Acpi.tables(917504, 2, 3)
    T.eq_str("tables rsdp xsdt", at(ts, 24n, 8n), "[48, 0, 14, 0, 0, 0, 0, 0]")
    T.eq_str("xsdt entries", at(ts, 84n, 16n), "[112, 0, 14, 0, 0, 0, 0, 0, 144, 1, 14, 0, 0, 0, 0, 0]")
    T.eq_str("fadt sig", at(ts, 112n, 4n), "[70, 65, 67, 80]")
    T.eq_str("madt sig", at(ts, 400n, 4n), "[65, 80, 73, 67]")
    T.eq_str("dsdt sig", at(ts, 592n, 4n), "[68, 83, 68, 84]")
    T.eq_str("fadt dsdt", at(ts, 152n, 4n), "[80, 2, 14, 0]")
