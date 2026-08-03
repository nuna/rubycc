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
   their reentrant *_r siblings. Not included: tcflow/tcgetsid/cfsetspeed and
   the termio.h/sgtty.h fallback paths (BSD/pre-POSIX ioctl-based terminal
   control that HAVE_TERMIOS_H skips on Linux), and the NLDLY/CRDLY/TABDLY/
   BSDLY/VTDLY/FFDLY output-delay bits (line-printer timing, not used to
   build raw mode). cfmakeraw was missing from that Step 124 pass: the corpus
   census that drove it only looks at which headers a #include reaches, not
   which functions the reached header's caller actually calls, so a function
   io-console calls without pulling in any new header slipped past it.
   Building io-console for real (Step 167) surfaced the gap -- mkmf's
   have_func probe for it passed regardless (it declares the function itself
   before linking), so -DHAVE_CFMAKERAW was set and the implicit-declaration
   error only showed up compiling the body -- and cfmakeraw was added then. */

#ifndef _RUBYCC_TERMIOS_H
#define _RUBYCC_TERMIOS_H

typedef unsigned char cc_t;
typedef unsigned int speed_t;
typedef unsigned int tcflag_t;

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

/* c_oflag bits. */
#define OPOST  0000001
#define ONLCR  0000004
#define OCRNL  0000010
#define ONOCR  0000020
#define ONLRET 0000040
#define OFILL  0000100
#define OFDEL  0000200

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

/* tcsetattr's __optional_actions. */
#define TCSANOW   0
#define TCSADRAIN 1
#define TCSAFLUSH 2

/* tcflush's __queue_selector. */
#define TCIFLUSH  0
#define TCOFLUSH  1
#define TCIOFLUSH 2

int tcgetattr(int __fd, struct termios *__termios_p);
int tcsetattr(int __fd, int __optional_actions, const struct termios *__termios_p);
int tcflush(int __fd, int __queue_selector);
int tcdrain(int __fd);
int tcsendbreak(int __fd, int __duration);
speed_t cfgetispeed(const struct termios *__termios_p);
speed_t cfgetospeed(const struct termios *__termios_p);
int cfsetispeed(struct termios *__termios_p, speed_t __speed);
int cfsetospeed(struct termios *__termios_p, speed_t __speed);

/* cfmakeraw is a BSD/GNU extension, not POSIX (POSIX only standardizes the
   getattr/setattr/cfset*speed calls above); glibc and the BSDs all provide it
   as the conventional shortcut that sets the termios flags/c_cc for raw mode
   in one call, which is exactly what io-console uses it for. */
void cfmakeraw(struct termios *__termios_p);

#endif /* _RUBYCC_TERMIOS_H */
