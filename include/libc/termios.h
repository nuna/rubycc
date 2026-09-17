/* rubycc bundled <termios.h>: general terminal interface (POSIX.1).
   Provenance: clean room against the POSIX public interface and the glibc/
   Linux ABI (bits/termios.h, the generic layout every mainline Linux arch
   except a handful of legacy ports -- alpha/mips/powerpc/sparc -- shares;
   x86-64 and aarch64 both use it). struct termios's member names, order and
   the `c_cc` array holding NCCS control characters are that ABI's own public
   contract, not glibc implementation detail (the same treatment sys/
   resource.h gives struct rlimit/struct rusage). Every member (including
   c_cc's individual slots, indexed by the V* constants) is read/written
   directly by callers, so the struct cannot be an opaque byte blob; its size
   (60), NCCS (32) and every member's offset were measured against the glibc
   oracle on both x86-64 and aarch64 (see test/test_header_abi.rb's TERMIOS
   case) and the two agreed exactly (tcflag_t/speed_t are `unsigned int` and
   cc_t is `unsigned char` on either LP64 target, so no member has an
   arch-dependent width), so this header lives in the common layer. speed_t/
   tcflag_t/cc_t and every c_iflag/c_oflag/c_cflag/c_lflag bit and V* index
   are the standard Linux/glibc values (measured, both arches agree).
   Narrowed to the surface io-console's corpus sample actually reaches
   (Step 124, M5 H2): the termios-path (HAVE_TERMIOS_H) getattr/setattr pair
   built from tcgetattr/tcsetattr/TCSANOW, tcflush plus its TC*FLUSH queue
   selectors, and the c_iflag/c_oflag/c_cflag/c_lflag bits and VMIN/VTIME/
   VINTR/.../XCASE indices it flips to build raw mode. cfgetispeed/
   cfsetispeed/cfgetospeed/cfsetospeed/tcdrain/tcsendbreak are declared as
   the POSIX-mandated companions of tcgetattr/tcsetattr even though no corpus
   sample calls them, the same completeness precedent pwd.h/grp.h set for
   their reentrant *_r siblings. Step 124 left out tcflow/tcgetsid/
   cfsetspeed, the output-delay bits and the baud rates above B38400;
   bundled-headers-coverage-audit-2 added all of them (GAPS BA: ruby-termios
   calls tcflow; serialport uses B57600..B4000000, CRTSCTS, CMSPAR, CBAUD and
   the ECHOCTL/ECHOKE/ECHOPRT bits) together with the TCOOFF/TCOON/TCIOFF/
   TCION tcflow actions and pid_t for tcgetsid. Every added value was printed
   by the glibc oracle on x86-64 and aarch64 on 2026-09-14 and the two agree,
   so this stays in the common layer (TERMIOS case). The termio.h/sgtty.h
   fallback paths (BSD/pre-POSIX ioctl-based terminal control that
   HAVE_TERMIOS_H skips on Linux) are not reproduced.
   Coverage against glibc's <termios.h> under _GNU_SOURCE (audited
   2026-09-14, tools/audit_bundled_headers.rb). Intentionally left out:
   omitted: CCEQ -- a function-like comparison macro for c_cc slots; no
   corpus user. omitted: TIOCSER_TEMT -- the serial-driver status bit glibc
   also shows here; it belongs to TIOCSERGETLSR and the bundled
   <sys/ioctl.h> provides it. omitted: <sys/ttydefaults.h> -- the TTYDEF_*
   default terminal settings glibc pulls in; no corpus user.
   cfmakeraw was missing from that Step 124 pass: the corpus
   census that drove it only looks at which headers a #include reaches, not
   which functions the reached header's caller actually calls, so a function
   io-console calls without pulling in any new header slipped past it.
   Building io-console for real (Step 167) surfaced the gap -- mkmf's
   have_func probe for it passed regardless (it declares the function itself
   before linking), so -DHAVE_CFMAKERAW was set and the implicit-declaration
   error only showed up compiling the body -- and cfmakeraw was added then.
   Re-audited on 2026-09-16 under audit-reserved-public-macros-1 (GAPS BX),
   which widened the diff to the reserved spellings a program writes: this
   header gained none, because glibc's <termios.h> owns no such name.
   _POSIX_VDISABLE, the c_cc[] value ruby-termios stores to disable a special
   character, is POSIX's <unistd.h> macro and lives in the bundled <unistd.h>;
   a caller that uses it with this header includes <unistd.h> too, as
   ruby-termios does. */

#ifndef _RUBYCC_TERMIOS_H
#define _RUBYCC_TERMIOS_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

typedef unsigned char cc_t;
typedef unsigned int speed_t;
typedef unsigned int tcflag_t;
#ifndef _RUBYCC_PID_T
#define _RUBYCC_PID_T
typedef int pid_t;
#endif

/* Size of c_cc (measured, both arches). */
#define NCCS 32

/* struct termios: 60 bytes, 4-byte aligned (measured, both arches). */
struct termios {
  tcflag_t c_iflag;   /* offset 0:  input mode flags */
  tcflag_t c_oflag;   /* offset 4:  output mode flags */
  tcflag_t c_cflag;   /* offset 8:  control mode flags */
  tcflag_t c_lflag;   /* offset 12: local mode flags */
  cc_t c_line;         /* offset 16: line discipline */
  cc_t c_cc[NCCS];     /* offset 17: control characters */
  speed_t c_ispeed;    /* offset 52: input speed */
  speed_t c_ospeed;    /* offset 56: output speed */
};

/* c_cc subscripts (measured, both arches agree). */
#define VINTR    0
#define VQUIT    1
#define VERASE   2
#define VKILL    3
#define VEOF     4
#define VTIME    5
#define VMIN     6
#define VSWTC    7
#define VSTART   8
#define VSTOP    9
#define VSUSP    10
#define VEOL     11
#define VREPRINT 12
#define VDISCARD 13
#define VWERASE  14
#define VLNEXT   15
#define VEOL2    16

/* c_iflag bits. */
#define IGNBRK  0000001
#define BRKINT  0000002
#define IGNPAR  0000004
#define PARMRK  0000010
#define INPCK   0000020
#define ISTRIP  0000040
#define INLCR   0000100
#define IGNCR   0000200
#define ICRNL   0000400
#define IXON    0002000
#define IXANY   0004000
#define IXOFF   0010000
#define IMAXBEL 0020000
#define IUTF8   0040000
#define IUCLC   0001000

/* c_oflag bits. */
#define OPOST  0000001
#define ONLCR  0000004
#define OCRNL  0000010
#define ONOCR  0000020
#define ONLRET 0000040
#define OFILL  0000100
#define OFDEL  0000200
#define OLCUC  0000002

/* c_oflag output-delay fields and their settings (line-printer timing). */
#define NLDLY  0000400
#define NL0    0000000
#define NL1    0000400
#define CRDLY  0003000
#define CR0    0000000
#define CR1    0001000
#define CR2    0002000
#define CR3    0003000
#define TABDLY 0014000
#define TAB0   0000000
#define TAB1   0004000
#define TAB2   0010000
#define TAB3   0014000
#define XTABS  0014000
#define BSDLY  0020000
#define BS0    0000000
#define BS1    0020000
#define VTDLY  0040000
#define VT0    0000000
#define VT1    0040000
#define FFDLY  0100000
#define FF0    0000000
#define FF1    0100000

/* c_cflag bits. */
#define CSIZE  0000060
#define CS5    0000000
#define CS6    0000020
#define CS7    0000040
#define CS8    0000060
#define CSTOPB 0000100
#define CREAD  0000200
#define PARENB 0000400
#define PARODD 0001000
#define HUPCL  0002000
#define CLOCAL 0004000
/* Linux c_cflag extensions: the baud-rate field masks, and hardware flow
   control / mark-space parity. */
#define CBAUD   0010017
#define CBAUDEX 0010000
#define CIBAUD  002003600000
#define CMSPAR  010000000000
#define CRTSCTS 020000000000u
#define ADDRB   004000000000

/* c_lflag bits. */
#define ISIG   0000001
#define ICANON 0000002
#define ECHO   0000010
#define ECHOE  0000020
#define ECHOK  0000040
#define ECHONL 0000100
#define NOFLSH 0000200
#define TOSTOP 0000400
#define IEXTEN 0100000
/* Linux extension (glibc gates this behind __USE_MISC; rubycc exposes it
   unconditionally, the same flat-surface choice sys/resource.h made for
   RUSAGE_THREAD). */
#define XCASE  0000004
#define ECHOCTL 0001000
#define ECHOPRT 0002000
#define ECHOKE  0004000
#define FLUSHO  0010000
#define PENDIN  0040000
#define EXTPROC 0200000

/* Baud rate selectors, for cfsetispeed/cfsetospeed (the traditional POSIX
   set; the GNU-extension rates above B38400, e.g. B57600/B115200, are not
   included -- no corpus sample needs them). */
#define B0     0000000
#define B50    0000001
#define B75    0000002
#define B110   0000003
#define B134   0000004
#define B150   0000005
#define B200   0000006
#define B300   0000007
#define B600   0000010
#define B1200  0000011
#define B1800  0000012
#define B2400  0000013
#define B4800  0000014
#define B9600  0000015
#define B19200 0000016
#define B38400 0000017
#define EXTA   B19200
#define EXTB   B38400
/* The Linux extended rates (CBAUDEX set). */
#define B57600   0010001
#define B115200  0010002
#define B230400  0010003
#define B460800  0010004
#define B500000  0010005
#define B576000  0010006
#define B921600  0010007
#define B1000000 0010010
#define B1152000 0010011
#define B1500000 0010012
#define B2000000 0010013
#define B2500000 0010014
#define B3000000 0010015
#define B3500000 0010016
#define B4000000 0010017

/* tcsetattr's __optional_actions. */
#define TCSANOW   0
#define TCSADRAIN 1
#define TCSAFLUSH 2

/* tcflush's __queue_selector. */
#define TCIFLUSH  0
#define TCOFLUSH  1
#define TCIOFLUSH 2

/* tcflow's __action: suspend/restart output, send STOP/START. */
#define TCOOFF 0
#define TCOON  1
#define TCIOFF 2
#define TCION  3

int tcgetattr(int __fd, struct termios *__termios_p);
int tcflow(int __fd, int __action);
pid_t tcgetsid(int __fd);
int tcsetattr(int __fd, int __optional_actions, const struct termios *__termios_p);
int tcflush(int __fd, int __queue_selector);
int tcdrain(int __fd);
int tcsendbreak(int __fd, int __duration);
speed_t cfgetispeed(const struct termios *__termios_p);
speed_t cfgetospeed(const struct termios *__termios_p);
int cfsetispeed(struct termios *__termios_p, speed_t __speed);
int cfsetospeed(struct termios *__termios_p, speed_t __speed);
/* Sets both speeds at once (BSD; glibc shows it under __USE_MISC). */
int cfsetspeed(struct termios *__termios_p, speed_t __speed);

/* cfmakeraw is a BSD/GNU extension, not POSIX (POSIX only standardizes the
   getattr/setattr/cfset*speed calls above); glibc and the BSDs all provide it
   as the conventional shortcut that sets the termios flags/c_cc for raw mode
   in one call, which is exactly what io-console uses it for. */
void cfmakeraw(struct termios *__termios_p);

#endif /* _RUBYCC_TERMIOS_H */
