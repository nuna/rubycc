/* rubycc bundled <sys/utsname.h>: system identification (POSIX.1 4.4).
   Provenance: clean room against the Linux kernel ABI (struct new_utsname,
   returned by the uname(2) syscall) and the POSIX public interface. Member
   names, order and per-field length (65) are the ABI's own public contract --
   the raw syscall fills exactly six 65-byte fields (sysname, nodename,
   release, version, machine, domainname; the sixth is the NIS domain name the
   kernel added alongside the original five POSIX fields) -- so reproducing
   them is not a glibc derivation. Every member is used directly by callers, so
   it cannot be an opaque byte blob; the struct's size (390) and every member's
   offset were measured against the glibc oracle on both x86-64 and aarch64
   (see test/test_header_abi.rb's UTSNAME case) and the two agreed exactly (a
   plain char-array struct has no arch-dependent field widths), so this header
   lives in the common layer. glibc gates the sixth field's name behind
   __USE_GNU (plain `domainname' vs. `__domainname'); rubycc's bundled header
   exposes the flat `domainname' spelling unconditionally, the same choice
   sys/stat.h's unconditional st_atim makes. uname is a POSIX declaration whose
   body resolves from the host libc at link time (Step 123, M5 H2). */

#ifndef _RUBYCC_SYS_UTSNAME_H
#define _RUBYCC_SYS_UTSNAME_H

#define _UTSNAME_LENGTH 65

struct utsname {
  char sysname[_UTSNAME_LENGTH];    /* Operating system name. */
  char nodename[_UTSNAME_LENGTH];   /* Name on the network. */
  char release[_UTSNAME_LENGTH];    /* Release level. */
  char version[_UTSNAME_LENGTH];    /* Version level. */
  char machine[_UTSNAME_LENGTH];    /* Hardware type. */
  char domainname[_UTSNAME_LENGTH]; /* NIS/YP domain name. */
};

int uname(struct utsname *__name);

#endif /* _RUBYCC_SYS_UTSNAME_H */
