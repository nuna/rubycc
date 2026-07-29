/* rubycc bundled <sys/inotify.h>: the Linux inotify(7) filesystem-change
   notification interface. Provenance: clean room against the Linux kernel
   UAPI (linux/inotify.h) and the glibc call surface, not derived from musl or
   glibc source. The event-mask bits, the two init flags and struct
   inotify_event's layout are that ABI reproduced as measured integer
   constants and measured field offsets (an ABI fact, not copied text -- see
   docs/HEADER-LICENSING.md sec. 4), the same treatment as poll.h and
   sys/epoll.h.

   Common layer, and that was measured rather than assumed. struct
   inotify_event ends in a flexible array member, which is exactly the shape
   where a wrong tail assumption would be invisible in a member-by-member
   read, so its size and every offset were printed from the glibc oracle on
   both targets and came back identical:

     sizeof 16, _Alignof 4, wd @ 0, mask @ 4, cookie @ 8, len @ 12,
     name @ 16 (the flexible member contributes nothing to sizeof, so the
     16-byte size is the header alone -- which is what makes libev's
     `ofs += sizeof (struct inotify_event) + ev->len` walk correct)

   The member widths and signedness were measured too: wd is a signed 4-byte
   int (it is a watch descriptor, and -1 is the error return of
   inotify_add_watch), while mask, cookie and len are unsigned 4-byte. Since
   nothing here differs between the targets, the header is arch neutral,
   unlike sys/epoll.h whose struct packing does differ.

   IN_CLOEXEC and IN_NONBLOCK share bits with the open(2) flags, and some O_*
   names do differ between the targets (that is why fcntl.h is an arch-layer
   header), so those two were measured on both as well: 0x80000 and 0x800 on
   each.

   inotify_init/inotify_init1/inotify_add_watch/inotify_rm_watch are
   Linux/glibc declarations whose bodies resolve from the host libc at link
   time.

   Not included: the IN_ALL_EVENTS convenience mask is provided, but glibc's
   internal aliases beyond it are not, and NAME_MAX (which callers sizing a
   read buffer want next to this header) is left to <limits.h>, which already
   provides it. nio4r, the gem that put this header on the list, reaches
   inotify_init1 / inotify_add_watch / inotify_rm_watch and the mask bits
   through libev's ev_stat backend. */

#ifndef _RUBYCC_SYS_INOTIFY_H
#define _RUBYCC_SYS_INOTIFY_H

#include <stdint.h>

/* Flags for inotify_init1; they share O_CLOEXEC's and O_NONBLOCK's bits
   (measured, both arches). */
#define IN_CLOEXEC  0x80000
#define IN_NONBLOCK 0x800

/* The events a watch can ask for (measured, both arches). */
#define IN_ACCESS        0x00000001 /* file was read */
#define IN_MODIFY        0x00000002 /* file was written */
#define IN_ATTRIB        0x00000004 /* metadata changed */
#define IN_CLOSE_WRITE   0x00000008 /* writable descriptor closed */
#define IN_CLOSE_NOWRITE 0x00000010 /* read-only descriptor closed */
#define IN_OPEN          0x00000020 /* file was opened */
#define IN_MOVED_FROM    0x00000040 /* renamed out of the watched directory */
#define IN_MOVED_TO      0x00000080 /* renamed into the watched directory */
#define IN_CREATE        0x00000100 /* entry created in the directory */
#define IN_DELETE        0x00000200 /* entry deleted from the directory */
#define IN_DELETE_SELF   0x00000400 /* the watched file itself was deleted */
#define IN_MOVE_SELF     0x00000800 /* the watched file itself was renamed */

/* The two pairs above that callers usually want together. */
#define IN_CLOSE (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
#define IN_MOVE  (IN_MOVED_FROM | IN_MOVED_TO)

/* Everything a watch may be asked for, i.e. the twelve bits above
   (measured: 0xfff on both arches). */
#define IN_ALL_EVENTS 0x00000fff

/* Events the kernel reports without being asked (measured, both arches). */
#define IN_UNMOUNT     0x00002000 /* the backing filesystem was unmounted */
#define IN_Q_OVERFLOW  0x00004000 /* the event queue overflowed */
#define IN_IGNORED     0x00008000 /* the watch was removed */

/* Bits that modify how inotify_add_watch installs the watch (measured, both
   arches). IN_ISDIR is not one of these: it is set by the kernel on a
   reported event whose subject is a directory. */
#define IN_ONLYDIR     0x01000000 /* fail unless the path is a directory */
#define IN_DONT_FOLLOW 0x02000000 /* do not dereference a symbolic link */
#define IN_EXCL_UNLINK 0x04000000 /* stop reporting unlinked children */
#define IN_MASK_CREATE 0x10000000 /* fail if a watch already exists */
#define IN_MASK_ADD    0x20000000 /* add to, not replace, the existing mask */
#define IN_ISDIR       0x40000000 /* reported: the subject is a directory */
#define IN_ONESHOT     0x80000000 /* remove the watch after one event */

/* One queued event, as read(2) hands it over. Measured: 16 bytes, 4-byte
   aligned, with the four fixed members packed end to end and the name
   starting immediately after them. `name` is a flexible array member: when
   `len` is non-zero the kernel writes `len` bytes there (a NUL-terminated
   name plus enough NUL padding to keep the next event 4-byte aligned), so
   consecutive events in a read buffer are `sizeof(struct inotify_event) +
   len` bytes apart. */
struct inotify_event {
  int      wd;     /* offset  0: the watch this event belongs to */
  uint32_t mask;   /* offset  4: the IN_ bits that fired */
  uint32_t cookie; /* offset  8: pairs a MOVED_FROM with its MOVED_TO */
  uint32_t len;    /* offset 12: bytes of `name`, including padding */
  char     name[]; /* offset 16: present only when len is non-zero */
};

int inotify_init(void);
int inotify_init1(int __flags);
int inotify_add_watch(int __fd, const char *__pathname, uint32_t __mask);
int inotify_rm_watch(int __fd, int __wd);

#endif /* _RUBYCC_SYS_INOTIFY_H */
