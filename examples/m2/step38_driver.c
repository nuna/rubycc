/* Step 38 (M2 L8): a program shaped like the ones the new gcc-compatible driver
   (Rubycc::Driver) builds in one shot. It is a plain translation unit that calls
   libc (printf) and returns a status, the way `rubycc -o prog step38_driver.c`
   compiles and links in a single command. The driver itself is exercised end to
   end by test_driver.rb (multi-unit one-shot, -shared/-lz, -D/-U, -E); this
   sample is the milestone artifact that test_examples.rb keeps building against
   gcc. Uses only features available through this step; output is deterministic. */
int printf(const char *format, ...);

/* A small computation whose result feeds both the printed line and the exit
   status, so the differential check compares stdout and the status together. */
static int checksum(const int *values, int count)
{
  int total = 0;
  int i;
  for (i = 0; i < count; i = i + 1) {
    total = total + values[i] * (i + 1);
  }
  return total;
}

int main(void)
{
  int data[5];
  data[0] = 3;
  data[1] = 1;
  data[2] = 4;
  data[3] = 1;
  data[4] = 5;

  int sum = checksum(data, 5);
  printf("checksum=%d\n", sum);
  return sum % 256;
}
