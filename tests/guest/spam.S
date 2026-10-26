// Exit-rate benchmark: 200000 one-byte stores to the PL011 data register
// (each traps to the VMM), then PSCI SYSTEM_OFF. scripts/bench.sh times it.
  .text
  .global _start
_start:
  ldr   x1, =0x09000000
  ldr   x2, =200000
  mov   w3, #'.'
1:
  str   w3, [x1]
  subs  x2, x2, #1
  b.ne  1b
  ldr   x0, =0x84000008
  hvc   #0
2:
  wfi
  b     2b
