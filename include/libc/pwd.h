/* rubycc bundled <pwd.h>: the user database access interface (POSIX.1 9.2.2).
   Provenance: clean room against the POSIX public interface -- struct passwd's
   member names, types and order are POSIX's own public contract, not glibc
   implementation detail, so reproducing them is not a glibc derivation. Every
   member is used directly by callers, so it cannot be an opaque byte blob;
   instead its size and every member's offset were measured against the glibc
   oracle on both x86-64 and aarch64 (see test/test_header_abi.rb's PWD case)
   and the two agreed exactly (an all-pointer/uid_t/gid_t struct has no
   arch-dependent field widths on either LP64 target), so this header lives in
   the common layer. uid_t/gid_t reuse the shared _RUBYCC_* guards sys/types.h
   and unistd.h also carry. getpwnam/getpwuid/getpwent/setpwent/endpwent/
   getpwnam_r/getpwuid_r are POSIX declarations whose bodies resolve from the
   host libc at link time (getpwnam_r/getpwuid_r answer through NSS, so their
   result is a host runtime fact, not something rubycc computes).
   Not included: fgetpwent/putpwent/getpw (glibc/BSD extensions no corpus
   sample census hit needs), left out to keep the surface to what etc's use of
   getpwnam/getpwuid actually requires (Step 123, M5 H2). */

#ifndef _RUBYCC_PWD_H
#define _RUBYCC_PWD_H

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_UID_T
#define _RUBYCC_UID_T
typedef unsigned int uid_t;
#endif
#ifndef _RUBYCC_GID_T
#define _RUBYCC_GID_T
typedef unsigned int gid_t;
#endif

/* A record in the user database. Member names, types and order are the
   POSIX.1 public contract; every offset below was measured against the glibc
   oracle on both x86-64 and aarch64 and the two agreed byte for byte. */
struct passwd {
  char *pw_name;   /* Username. */
  char *pw_passwd; /* Hashed passphrase (if no shadow database). */
  uid_t pw_uid;    /* User ID. */
  gid_t pw_gid;    /* Group ID. */
  char *pw_gecos;  /* Real name. */
  char *pw_dir;    /* Home directory. */
  char *pw_shell;  /* Shell program. */
};

struct passwd *getpwnam(const char *__name);
struct passwd *getpwuid(uid_t __uid);
struct passwd *getpwent(void);
void setpwent(void);
void endpwent(void);
int getpwnam_r(const char *__restrict __name, struct passwd *__restrict __resultbuf,
               char *__restrict __buffer, size_t __buflen, struct passwd **__restrict __result);
int getpwuid_r(uid_t __uid, struct passwd *__restrict __resultbuf,
               char *__restrict __buffer, size_t __buflen, struct passwd **__restrict __result);

#endif /* _RUBYCC_PWD_H */
