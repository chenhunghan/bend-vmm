// A minimal Linux /init for the boot test (aarch64, no libc): prints the
// marker scripts/check-mac.sh waits for, then powers the VM off with
// reboot(LINUX_REBOOT_CMD_POWER_OFF), which Linux turns into PSCI SYSTEM_OFF.
  .text
  .global _start
_start:
  mov   x0, #1              // stdout (/dev/console)
  adr   x1, msg
  mov   x2, #(end - msg)
  mov   x8, #64             // write
  svc   #0
  ldr   x0, =0xfee1dead     // LINUX_REBOOT_MAGIC1
  ldr   x1, =672274793      // LINUX_REBOOT_MAGIC2
  ldr   x2, =0x4321fedc     // LINUX_REBOOT_CMD_POWER_OFF
  mov   x8, #142            // reboot
  svc   #0
1:
  b     1b
msg:
  .ascii "\nBEND-VMM-BOOT-OK\n"
end:
