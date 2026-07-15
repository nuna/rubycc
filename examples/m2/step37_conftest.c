/* Step 37 (M2 L7): the shape of an mkmf conftest try_run probe, the reason the
   executable writer (Rubycc::Link::ExecutableLinker) exists. mkmf compiles such
   a program, links it into a real executable through a synthesized crt whose
   _start calls __libc_start_main so the C runtime is initialized, runs it, and
   reads the exit status to decide whether a feature is present. Here the probe
   exercises libc (strlen, printf) and reports success through both stdout and
   the process exit code — the two channels a try_run inspects. Uses only
   features available through this step; output is deterministic. (Here the
   sample is built and run with gcc for the differential check; test_executable.rb
   is what drives it through rubycc's own executable writer end to end.) */
unsigned long strlen(const char *s);
int printf(const char *format, ...);

/* A trivial "does this environment behave as expected" check of the kind a
   conftest performs: compute with a libc function and confirm the result. */
static int probe(void)
{
  const char *token = "conftest";
  return strlen(token) == 8 ? 0 : 1;
}

int main(void)
{
  int status = probe();
  printf("probe %s\n", status == 0 ? "ok" : "failed");
  return status;
}
