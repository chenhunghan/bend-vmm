// Bare-metal smoke payload: prints a line on the PL011 at 0x0900_0000 one
// byte per MMIO store, then powers off with PSCI SYSTEM_OFF (HVC #0).
// Loaded at the start of RAM and entered at EL1 with the MMU off.
  .text
  .global _start
_start:
  ldr   x1, =0x09000000
  adr   x2, msg
1:
  ldrb  w3, [x2], #1
  cbz   w3, 2f
  str   w3, [x1]
  b     1b
2:
  ldr   x0, =0x84000008
  hvc   #0
3:
  wfi
  b     3b
msg:
  .asciz "hello from the guest\n"
  .balign 8
