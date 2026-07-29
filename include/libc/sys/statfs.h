/* rubycc bundled <sys/statfs.h>: the Linux statfs(2) filesystem-statistics
   interface. Provenance: clean room against the Linux kernel UAPI
   (the statfs(2) argument layout) and the glibc call surface, not derived
   from musl or glibc source. struct statfs's size, member widths, signedness
   and offsets are that ABI reproduced from measurement (an ABI fact, not
   copied text -- see docs/HEADER-LICENSING.md sec. 4), the same treatment as
   sys/stat.h and dirent.h.

   Common layer, and this one is worth spelling out because the naive guess
   is the other way. The kernel has two statfs layouts -- a legacy one whose
   counters are 32-bit and a 64-bit one -- and glibc's member types are
   written in terms of word-sized typedefs, so it would be reasonable to
   expect the two targets to disagree the way sys/stat.h's struct stat does.
   Measured with the glibc oracle, they do not: both x86-64 and aarch64
   report

     sizeof 120, _Alignof 8, and every member 8 bytes wide at
     f_type 0, f_bsize 8, f_blocks 16, f_bfree 24, f_bavail 32,
     f_files 40, f_ffree 48, f_fsid 56, f_namelen 64, f_frsize 72,
     f_flags 80, f_spare 88 (4 x 8 = 32 bytes, running to 120)

   i.e. both LP64 targets land on the all-64-bit layout with no padding
   anywhere, so one arch-neutral definition serves. The signedness was
   measured member by member as well, and is not uniform: f_type, f_bsize,
   f_namelen, f_frsize, f_flags and f_spare are signed, while the six
   counters f_blocks / f_bfree / f_bavail / f_files / f_ffree are unsigned.
   That asymmetry is why signedness was probed rather than assumed -- libev
   compares f_type against magic numbers as large as 0x9123683e, which only
   behaves as intended because the field is a signed 64-bit word rather than
   a 32-bit one.

   f_fsid's type: glibc gets __fsid_t from its bits/types.h layer and spells
   the fsid_t alias in <sys/types.h> under __USE_MISC; measured, <sys/statfs.h>
   alone gives only the __fsid_t spelling. rubycc has no split types layer to
   reach for and its bundled <sys/types.h> does not carry the type, so both
   names are defined here under one guard. The type itself measured 8 bytes
   with 4-byte alignment -- two 4-byte ints, not one 8-byte word, which is
   why f_fsid cannot simply be written as a long.

   Not included: struct statfs64 / statfs64 / fstatfs64 (measured, statfs64
   is byte-for-byte the same 120-byte layout on both LP64 targets, so the
   plain names already are the 64-bit interface here), and the ST_* mount
   flag names, which measurement confirms <sys/statfs.h> does not define at
   all -- they belong to <sys/statvfs.h>, which rubycc does not bundle. nio4r,
   the gem that put this header on the list, reaches statfs and f_type only,
   from libev's ev_stat backend deciding whether a filesystem is local enough
   for inotify to be trusted. */

#ifndef _RUBYCC_SYS_STATFS_H
#define _RUBYCC_SYS_STATFS_H

/* The filesystem identifier statfs reports. Measured: 8 bytes, 4-byte
   aligned, i.e. a pair of 4-byte ints rather than one 8-byte word. */
#ifndef _RUBYCC_FSID_T
#define _RUBYCC_FSID_T
typedef struct {
  int __val[2];
} __fsid_t;
typedef __fsid_t fsid_t;
#endif

/* Measured: 120 bytes, 8-byte aligned, every member one 8-byte word and no
   padding. Signedness is per member -- see the header note. */
struct statfs {
  long          f_type;    /* offset  0: filesystem magic number */
  long          f_bsize;   /* offset  8: optimal transfer block size */
  unsigned long f_blocks;  /* offset 16: total blocks, in f_frsize units */
  unsigned long f_bfree;   /* offset 24: free blocks */
  unsigned long f_bavail;  /* offset 32: free blocks available to non-root */
  unsigned long f_files;   /* offset 40: total file nodes */
  unsigned long f_ffree;   /* offset 48: free file nodes */
  __fsid_t      f_fsid;    /* offset 56: filesystem id */
  long          f_namelen; /* offset 64: maximum filename length */
  long          f_frsize;  /* offset 72: fragment size */
  long          f_flags;   /* offset 80: mount flags */
  long          f_spare[4];/* offset 88: reserved, runs to 120 */
};

int statfs(const char *__path, struct statfs *__buf);
int fstatfs(int __fd, struct statfs *__buf);

#endif /* _RUBYCC_SYS_STATFS_H */
