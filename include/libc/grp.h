/* rubycc bundled <grp.h>: the group database access interface (POSIX.1 9.2.1).
   Provenance: clean room against the POSIX public interface -- struct group's
   member names, types and order are POSIX's own public contract, not glibc
   implementation detail. Every member is used directly by callers, so it
   cannot be an opaque byte blob; its size and every member's offset were
   measured against the glibc oracle on both x86-64 and aarch64 (see
   test/test_header_abi.rb's GRP case) and the two agreed exactly (an
   all-pointer/gid_t struct has no arch-dependent field widths on either LP64
   target), so this header lives in the common layer. gid_t reuses the shared
   _RUBYCC_GID_T guard sys/types.h and unistd.h also carry. getgrnam/getgrgid/
   getgrent/setgrent/endgrent/getgrnam_r/getgrgid_r are POSIX declarations
   whose bodies resolve from the host libc at link time (the _r variants
   answer through NSS, a host runtime fact, not something rubycc computes).
   Not included: fgetgrent/putgrent (glibc/BSD extensions no corpus sample
   census hit needs), left out to keep the surface to what etc's use of
   getgrnam/getgrgid actually requires (Step 123, M5 H2). */

#ifndef _RUBYCC_GRP_H
#define _RUBYCC_GRP_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_GID_T
#define _RUBYCC_GID_T
typedef unsigned int gid_t;
#endif

/* A record in the group database. Member names, types and order are the
   POSIX.1 public contract; every offset below was measured against the glibc
   oracle on both x86-64 and aarch64 and the two agreed byte for byte. */
struct group {
  char *gr_name;   /* Group name. */
  char *gr_passwd; /* Password. */
  gid_t gr_gid;    /* Group ID. */
  char **gr_mem;   /* Member list (NULL-terminated). */
};

struct group *getgrnam(const char *__name);
struct group *getgrgid(gid_t __gid);
struct group *getgrent(void);
void setgrent(void);
void endgrent(void);
int getgrnam_r(const char *__restrict __name, struct group *__restrict __resultbuf,
               char *__restrict __buffer, size_t __buflen, struct group **__restrict __result);
int getgrgid_r(gid_t __gid, struct group *__restrict __resultbuf,
               char *__restrict __buffer, size_t __buflen, struct group **__restrict __result);

#endif /* _RUBYCC_GRP_H */
