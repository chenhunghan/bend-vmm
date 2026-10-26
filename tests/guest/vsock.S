// vsock test program for the guest (aarch64 Linux, raw syscalls):
//   vsock c   connect to the host (CID 2) port 1234, send "PING\n", print
//             the reply
//   vsock s   listen on port 5000, accept one connection, answer
//             "PONG " followed by what it read
  .text
  .global _start
_start:
  ldr   x0, [sp, #16]          // argv[1]
  cbz   x0, fail
  ldrb  w1, [x0]
  mov   x0, #40                // AF_VSOCK
  mov   x1, #1                 // SOCK_STREAM
  mov   x2, #0
  mov   x8, #198               // socket
  svc   #0
  tbnz  x0, #63, fail
  mov   x19, x0
  ldr   x0, [sp, #16]
  ldrb  w1, [x0]
  cmp   w1, #'s'
  b.eq  server
client:
  mov   x0, x19
  adr   x1, addr_client
  mov   x2, #16
  mov   x8, #203               // connect
  svc   #0
  tbnz  x0, #63, fail
  mov   x0, x19
  adr   x1, ping
  mov   x2, #5
  mov   x8, #64                // write
  svc   #0
  mov   x0, x19
  adr   x1, buf
  mov   x2, #64
  mov   x8, #63                // read
  svc   #0
  cmp   x0, #0
  b.le  fail
  mov   x2, x0
  mov   x0, #1
  adr   x1, buf
  mov   x8, #64
  svc   #0
  b     ok
server:
  mov   x0, x19
  adr   x1, addr_server
  mov   x2, #16
  mov   x8, #200               // bind
  svc   #0
  tbnz  x0, #63, fail
  mov   x0, x19
  mov   x1, #1
  mov   x8, #201               // listen
  svc   #0
  tbnz  x0, #63, fail
  mov   x0, x19
  mov   x1, #0
  mov   x2, #0
  mov   x8, #202               // accept
  svc   #0
  tbnz  x0, #63, fail
  mov   x20, x0
  mov   x0, x20
  adr   x1, buf
  mov   x2, #64
  mov   x8, #63                // read
  svc   #0
  cmp   x0, #0
  b.le  fail
  mov   x21, x0
  mov   x0, x20
  adr   x1, pong
  mov   x2, #5
  mov   x8, #64
  svc   #0
  mov   x0, x20
  adr   x1, buf
  mov   x2, x21
  mov   x8, #64
  svc   #0
  mov   x0, x20
  mov   x8, #57                // close
  svc   #0
ok:
  mov   x0, #0
  mov   x8, #93                // exit
  svc   #0
fail:
  mov   x0, #2
  adr   x1, err
  mov   x2, #10
  mov   x8, #64
  svc   #0
  mov   x0, #1
  mov   x8, #93
  svc   #0

  .data
  .balign 8
addr_client:                   // struct sockaddr_vm
  .hword 40, 0
  .word  1234
  .word  2                     // VMADDR_CID_HOST
  .word  0
addr_server:
  .hword 40, 0
  .word  5000
  .word  0xffffffff            // VMADDR_CID_ANY
  .word  0
ping:
  .ascii "PING\n"
pong:
  .ascii "PONG "
err:
  .ascii "VSOCK-ERR\n"
  .balign 8
buf:
  .space 64
