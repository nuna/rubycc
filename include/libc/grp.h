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
   Coverage against glibc's <grp.h> under _GNU_SOURCE (audited 2026-09-18,
   glibc 2.39, x86-64 and aarch64, with tools/audit_bundled_headers.rb; table
   in docs/development/BUNDLED-HEADERS-COVERAGE.md). Nine names were missing;
   five were added and four are deliberate. Added: the supplementary-group
   trio getgrouplist / initgroups / setgroups, which is how a C extension that
   changes identity gets the group list right (unistd.h already carries the
   reading half, getgroups, and left the writing half to this header);
   getgrent_r, the reentrant form of the getgrent enumeration above; and
   NSS_BUFLEN_GROUP, the buffer size glibc suggests for the _r lookups,
   measured 1024 on both arches. Every added prototype was checked by
   declaring it immediately before `#include <grp.h>` under gcc and
   aarch64-linux-gnu-gcc on 2026-09-18 -- clean on both arches.
   omitted: FILE fgetgrent fgetgrent_r putgrent -- the calls that read and
   write a group-format *stream* rather than the system database; supporting
   them would mean pulling <stdio.h> in here for FILE (which is why FILE shows
   up as a missing name of its own), and the corpus reaches this header for
   getgrnam/getgrgid only.
   omitted: <stddef.h> -- only size_t is needed, and it is declared here
   directly. */

#ifndef _RUBYCC_GRP_H
#define _RUBYCC_GRP_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

#ifndef _RUBYCC_SIZE_T
#define _RUBYCC_SIZE_T
typedef unsigned long size_t;
#endif
#ifndef _RUBYCC_GID_T
#define _RUBYCC_GID_T
typedef unsigned int gid_t;
#endif

/* Buffer size glibc suggests for the getgrnam_r/getgrgid_r/getgrent_r
   lookups below (measured 1024, both arches). */
#define NSS_BUFLEN_GROUP 1024

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
int getgrent_r(struct group *__restrict __resultbuf, char *__restrict __buffer,
               size_t __buflen, struct group **__restrict __result);

/* The supplementary-group list of a process. getgrouplist reports the groups
   a user belongs to, initgroups installs them, setgroups sets them outright
   (privileged). */
int getgrouplist(const char *__user, gid_t __group, gid_t *__groups, int *__ngroups);
int initgroups(const char *__user, gid_t __group);
int setgroups(size_t __n, const gid_t *__groups);

#endif /* _RUBYCC_GRP_H */
