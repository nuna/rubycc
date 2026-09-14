/* bundled-headers-coverage-audit-2: the names the coverage audit added to the
   bundled <stdlib.h>, <sched.h>, <termios.h>, <sys/ioctl.h> and <sys/types.h>,
   used the way the gems that were missing them use them (vmstat,
   enumerable-statistics, posix-spawn, ruby-termios, serialport,
   network_interface). Every printed value is fixed by the ABI, so gcc and
   rubycc must print the same text; nothing here depends on the machine's
   load or on a terminal being attached.
   alloca through <stdlib.h> (GAPS BG) is exercised by test/test_header_abi.rb's
   STDLIB_GNU case instead of here: the aarch64 example runner compiles against
   the cross sysroot's own glibc headers, whose <alloca.h> maps alloca onto the
   builtin only when __GNUC__ is defined, and rubycc does not define it
   (DESIGN R7), so a sample calling alloca would not link there. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/types.h>

/* qsort_r's third comparator argument is the caller's context (GNU order). */
static int by_distance(const void *a, const void *b, void *ctx) {
  int center = *(const int *)ctx;
  int da = abs(*(const int *)a - center);
  int db = abs(*(const int *)b - center);
  return da - db != 0 ? da - db : *(const int *)a - *(const int *)b;
}

int main(void) {
  /* <stdlib.h>: qsort_r and getloadavg. */
  int values[] = { 9, 2, 7, 4, 5, 1 };
  int center = 5;
  qsort_r(values, sizeof values / sizeof values[0], sizeof values[0], by_distance, &center);
  printf("qsort_r:");
  for (size_t i = 0; i < sizeof values / sizeof values[0]; i++) printf(" %d", values[i]);
  printf("\n");

  char scratch[8];
  for (int i = 0; i < 7; i++) scratch[i] = (char)('a' + i);
  scratch[7] = '\0';

  double load[3];
  int got = getloadavg(load, 3);
  printf("getloadavg: %s\n", got == 3 ? "3 samples" : "unavailable");

  /* <sched.h>: struct sched_param and the POSIX policy numbers. */
  struct sched_param param = { 0 };
  param.sched_priority = sched_get_priority_min(SCHED_OTHER);
  printf("sched: sizeof(struct sched_param)=%zu FIFO=%d RR=%d OTHER-min=%d\n",
         sizeof param, SCHED_FIFO, SCHED_RR, param.sched_priority);

  /* <termios.h>: tcflow's actions and the Linux extended baud rates. */
  struct termios t = { 0 };
  cfsetspeed(&t, B115200);
  t.c_cflag |= CRTSCTS;
  printf("termios: TCOOFF=%d TCOON=%d TCIOFF=%d TCION=%d B115200=%#o speed=%#o crtscts=%d\n",
         TCOOFF, TCOON, TCIOFF, TCION, (unsigned)B115200, (unsigned)cfgetospeed(&t),
         (t.c_cflag & CRTSCTS) != 0);

  /* <sys/ioctl.h>: the modem-control requests and line bits. */
  printf("ioctl: TIOCMGET=%#x TIOCMSET=%#x DTR|RTS=%#x SIOCGIFHWADDR=%#x\n",
         TIOCMGET, TIOCMSET, TIOCM_DTR | TIOCM_RTS, SIOCGIFHWADDR);

  /* <sys/types.h>: glibc's internal spellings that glibc's own headers use
     (__caddr_t is <net/if.h>'s struct ifreq member type). */
  __caddr_t data = scratch;
  __pid_t self = 0;
  printf("sys/types: sizeof(__caddr_t)=%zu sizeof(__pid_t)=%zu sizeof(int32_t)=%zu first=%c\n",
         sizeof data, sizeof self, sizeof(int32_t), data[0]);
  return 0;
}
