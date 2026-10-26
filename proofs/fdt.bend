import Base
import ../laws/fdt.bend as L

def L.fdt.cells():
  {==}

def L.fdt.cells_empty():
  {==}

def L.fdt.strs():
  {==}

def L.fdt.strings_dedup():
  {==}

def L.fdt.empty_root():
  {==}

def L.fdt.sample():
  {==}

def L.fdt.boot_cpuid():
  {==}

# fdt.word_aligned stays open: fdt.sample fixes a 186-byte blob (186 mod 4 = 2),
# so the law is false; see fdt.sample_not_word_aligned.

def L.fdt.sample_not_word_aligned():
  {==}
