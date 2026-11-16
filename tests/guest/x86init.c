// /init of the x86_64 boot check (scripts/ci/x86-boot.sh): reports what the
// guest sees of the machine, then powers off through ACPI (\_S5).
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static void cat(const char* path) {
  FILE* f = fopen(path, "r");
  char  line[256];
  if (!f) {
    printf("x86-init: %s: missing\n", path);
    return;
  }
  while (fgets(line, sizeof line, f)) {
    printf("x86-init: %s: %s", path, line);
  }
  fclose(f);
}

int main(void) {
  mkdir("/proc", 0755);
  mkdir("/sys", 0755);
  mount("proc", "/proc", "proc", 0, NULL);
  mount("sysfs", "/sys", "sysfs", 0, NULL);
  printf("x86-init: up, %ld cpus, time %ld\n", sysconf(_SC_NPROCESSORS_ONLN), (long)time(NULL));
  DIR* d = opendir("/sys/bus/virtio/devices");
  int  n = 0;
  if (d) {
    struct dirent* e;
    while ((e = readdir(d))) {
      if (e->d_name[0] == '.') {
        continue;
      }
      char p[512];
      snprintf(p, sizeof p, "/sys/bus/virtio/devices/%s/device", e->d_name);
      cat(p);
      n++;
    }
    closedir(d);
  }
  printf("x86-init: %d virtio devices\n", n);
  cat("/proc/interrupts");
  cat("/sys/class/rtc/rtc0/name");
  cat("/sys/class/rtc/rtc0/date");
  printf("x86-init: done\n");
  fflush(stdout);
  tcdrain(1); // the serial line's output goes out before the power does
  sleep(1);
  sync();
  reboot(RB_POWER_OFF);
  return 0;
}
