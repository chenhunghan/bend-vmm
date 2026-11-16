// The vsock test program (tests/guest/vsock.S) in C, for guests other than
// arm64 (scripts/guest-assets-x86.sh builds it static):
//   vsock c   connect to the host (CID 2) port 1234, send "PING\n", print
//             the reply
//   vsock s   listen on port 5000, accept one connection, answer
//             "PONG " followed by what it read
#include <linux/vm_sockets.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char** argv) {
  char buf[64];
  int  s = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (argc < 2 || s < 0) {
    return 1;
  }
  struct sockaddr_vm a;
  memset(&a, 0, sizeof a);
  a.svm_family = AF_VSOCK;
  if (argv[1][0] == 's') {
    a.svm_cid  = VMADDR_CID_ANY;
    a.svm_port = 5000;
    if (bind(s, (struct sockaddr*)&a, sizeof a) != 0 || listen(s, 1) != 0) {
      return 1;
    }
    int     c = accept(s, NULL, NULL);
    ssize_t n = c < 0 ? -1 : read(c, buf, sizeof buf);
    if (n <= 0) {
      return 1;
    }
    write(c, "PONG ", 5);
    write(c, buf, (size_t)n);
    close(c);
    return 0;
  }
  a.svm_cid  = 2;
  a.svm_port = 1234;
  if (connect(s, (struct sockaddr*)&a, sizeof a) != 0) {
    return 1;
  }
  write(s, "PING\n", 5);
  ssize_t n = read(s, buf, sizeof buf);
  if (n <= 0) {
    return 1;
  }
  write(1, buf, (size_t)n);
  return 0;
}
