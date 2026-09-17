/* rubycc bundled <sys/ioctl.h>: the ioctl(2) declaration and the terminal,
   file and socket request numbers (POSIX does not standardize ioctl at all;
   this is a Linux/glibc ABI surface). Provenance: clean room against the
   glibc/Linux ABI (glibc's bits/ioctl-types.h plus the kernel UAPI's
   asm-generic/ioctls.h and linux/sockios.h request numbers), not derived from
   musl. Step 124 (M5 H2) pared it to io-console's TIOCGWINSZ/TIOCSWINSZ
   against a `struct winsize`; struct winsize is a struct callers read/write
   members of directly, so it cannot be an opaque byte blob, and its size (8)
   and every member's offset were measured on both arches.

   bundled-headers-coverage-audit-2 (GAPS BB) added the rest of the request
   numbers glibc's <sys/ioctl.h> shows: the modem-control requests and line
   bits serialport uses (TIOCMGET/TIOCMSET/TIOCMBIS/TIOCMBIC, TIOCM_*), the
   remaining terminal requests, the FIO* file requests, the N_* line
   disciplines, and the SIOC* socket/interface requests (network_interface's
   extconf probes for SIOCGIFHWADDR and friends with have_macro, so a missing
   one silently builds a gem with fewer features than gcc's build rather than
   failing). Every value was printed by the glibc oracle on x86-64 (gcc) and
   aarch64 (aarch64-linux-gnu-gcc under qemu) on 2026-09-14: all 165 agree
   (both targets use the kernel's generic ioctl numbering), so the constants
   live in this common layer (test/test_header_abi.rb's IOCTL case re-checks
   them on both arches). Each value is written as the measured number, not as
   the _IO/_IOR encoding that produces it.
   Coverage against glibc's <sys/ioctl.h> under _GNU_SOURCE (audited
   2026-09-14, tools/audit_bundled_headers.rb). Intentionally left out:
   omitted: struct termio NCC -- the pre-POSIX System V terminal structure
   (TCGETA's argument); no corpus user. omitted: IOC_IN IOC_OUT IOC_INOUT
   IOCSIZE_MASK IOCSIZE_SHIFT -- request-number encoding helpers; the requests
   themselves are given as numbers. omitted: TCGETS2 TCSETS2 TCSETSF2
   TCSETSW2 TIOCGISO7816 TIOCSISO7816 -- they encode the size of kernel
   structs (struct termios2, struct serial_iso7816) glibc itself leaves
   incomplete, so glibc's own spelling of them does not compile either.
   omitted: <sys/ttydefaults.h> -- the TTYDEF_* default terminal settings
   glibc pulls in; no corpus user.

   audit-reserved-public-macros-1 (GAPS BX) made the audit count reserved
   spellings a program is meant to write, which brought the kernel's request
   *constructors* into the diff alongside the IOC_* helpers already left out
   above.
   omitted: _IO _IOC _IOR _IOW _IOWR _IOR_BAD _IOW_BAD _IOWR_BAD _IOC_* --
   the <asm-generic/ioctl.h> encoding macros that build a request number out
   of a direction, a type letter, a command number and an argument size. This
   header gives every request it provides as the measured number the encoding
   produces (see the note above), so the macros have no consumer here; a gem
   that had to name a request this header does not list would need them, but
   the corpus has none, and providing them would add the encoding's own bit
   layout (the _IOC_*BITS/*SHIFT widths, which are per-arch in the kernel even
   though x86-64 and aarch64 share the asm-generic values) as a second surface
   to re-measure at every kernel release. */

#ifndef _RUBYCC_SYS_IOCTL_H
#define _RUBYCC_SYS_IOCTL_H

/* glibc's own <features.h> (and the <sys/cdefs.h> it pulls in) is visible after
   a bare include of glibc's same-name header, and the glibc headers that
   include this one lean on that for __BEGIN_DECLS / __THROW (measured
   2026-09-18, glibc-public-headers-mixed-1). */
#include <features.h>

/* struct winsize: 8 bytes, 2-byte aligned (measured, both arches). */
struct winsize {
  unsigned short ws_row;    /* offset 0: rows, in characters */
  unsigned short ws_col;    /* offset 2: columns, in characters */
  unsigned short ws_xpixel; /* offset 4: horizontal size, pixels */
  unsigned short ws_ypixel; /* offset 6: vertical size, pixels */
};

/* Terminal window size ioctl requests (measured, both arches agree). */
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414

/* Terminal and termios ioctl requests. */
#define TCGETS             0x5401
#define TCSETS             0x5402
#define TCSETSW            0x5403
#define TCSETSF            0x5404
#define TCGETA             0x5405
#define TCSETA             0x5406
#define TCSETAW            0x5407
#define TCSETAF            0x5408
#define TCSBRK             0x5409
#define TCXONC             0x540a
#define TCFLSH             0x540b
#define TIOCEXCL           0x540c
#define TIOCNXCL           0x540d
#define TIOCSCTTY          0x540e
#define TIOCGPGRP          0x540f
#define TIOCSPGRP          0x5410
#define TIOCOUTQ           0x5411
#define TIOCSTI            0x5412
#define TIOCMGET           0x5415
#define TIOCMBIS           0x5416
#define TIOCMBIC           0x5417
#define TIOCMSET           0x5418
#define TIOCGSOFTCAR       0x5419
#define TIOCSSOFTCAR       0x541a
#define TIOCINQ            0x541b
#define TIOCLINUX          0x541c
#define TIOCCONS           0x541d
#define TIOCGSERIAL        0x541e
#define TIOCSSERIAL        0x541f
#define TIOCPKT            0x5420
#define TIOCNOTTY          0x5422
#define TIOCSETD           0x5423
#define TIOCGETD           0x5424
#define TCSBRKP            0x5425
#define TIOCSBRK           0x5427
#define TIOCCBRK           0x5428
#define TIOCGSID           0x5429
#define TIOCGRS485         0x542e
#define TIOCSRS485         0x542f
#define TIOCGPTN           0x80045430u
#define TIOCSPTLCK         0x40045431
#define TIOCGDEV           0x80045432u
#define TCGETX             0x5432
#define TCSETX             0x5433
#define TCSETXF            0x5434
#define TCSETXW            0x5435
#define TIOCSIG            0x40045436
#define TIOCVHANGUP        0x5437
#define TIOCGPKT           0x80045438u
#define TIOCGPTLCK         0x80045439u
#define TIOCGEXCL          0x80045440u
#define TIOCGPTPEER        0x5441
#define TIOCSERCONFIG      0x5453
#define TIOCSERGWILD       0x5454
#define TIOCSERSWILD       0x5455
#define TIOCGLCKTRMIOS     0x5456
#define TIOCSLCKTRMIOS     0x5457
#define TIOCSERGSTRUCT     0x5458
#define TIOCSERGETLSR      0x5459
#define TIOCSERGETMULTI    0x545a
#define TIOCSERSETMULTI    0x545b
#define TIOCMIWAIT         0x545c
#define TIOCGICOUNT        0x545d

/* Modem-control line bits: the TIOCMGET/TIOCMSET/TIOCMBIS/TIOCMBIC
   argument. TIOCM_CD and TIOCM_RI are second names for TIOCM_CAR and
   TIOCM_RNG (same measured values). */
#define TIOCM_LE           0x001
#define TIOCM_DTR          0x002
#define TIOCM_RTS          0x004
#define TIOCM_ST           0x008
#define TIOCM_SR           0x010
#define TIOCM_CTS          0x020
#define TIOCM_CAR          0x040
#define TIOCM_RNG          0x080
#define TIOCM_DSR          0x100
#define TIOCM_CD           TIOCM_CAR
#define TIOCM_RI           TIOCM_RNG

/* TIOCPKT packet-mode status bits. */
#define TIOCPKT_DATA       0x00
#define TIOCPKT_FLUSHREAD  0x01
#define TIOCPKT_FLUSHWRITE 0x02
#define TIOCPKT_STOP       0x04
#define TIOCPKT_START      0x08
#define TIOCPKT_NOSTOP     0x10
#define TIOCPKT_DOSTOP     0x20
#define TIOCPKT_IOCTL      0x40

/* TIOCSERGETLSR's "transmitter empty" result bit. */
#define TIOCSER_TEMT       0x01

/* File ioctl requests. FIONREAD is TIOCINQ's number. */
#define FIONREAD           0x541b
#define FIONBIO            0x5421
#define FIONCLEX           0x5450
#define FIOCLEX            0x5451
#define FIOASYNC           0x5452
#define FIOQSIZE           0x5460

/* Line disciplines: the TIOCSETD argument. */
#define N_TTY              0
#define N_SLIP             1
#define N_MOUSE            2
#define N_PPP              3
#define N_STRIP            4
#define N_AX25             5
#define N_X25              6
#define N_6PACK            7
#define N_MASC             8
#define N_R3964            9
#define N_PROFIBUS_FDL     10
#define N_IRDA             11
#define N_SMSBLOCK         12
#define N_HDLC             13
#define N_SYNC_PPP         14
#define N_HCI              15

/* Socket and network-interface ioctl requests. SIOGIFINDEX is a second
   name for SIOCGIFINDEX (same measured value). */
#define SIOCADDRT          0x890b
#define SIOCDELRT          0x890c
#define SIOCRTMSG          0x890d
#define SIOCGIFNAME        0x8910
#define SIOCSIFLINK        0x8911
#define SIOCGIFCONF        0x8912
#define SIOCGIFFLAGS       0x8913
#define SIOCSIFFLAGS       0x8914
#define SIOCGIFADDR        0x8915
#define SIOCSIFADDR        0x8916
#define SIOCGIFDSTADDR     0x8917
#define SIOCSIFDSTADDR     0x8918
#define SIOCGIFBRDADDR     0x8919
#define SIOCSIFBRDADDR     0x891a
#define SIOCGIFNETMASK     0x891b
#define SIOCSIFNETMASK     0x891c
#define SIOCGIFMETRIC      0x891d
#define SIOCSIFMETRIC      0x891e
#define SIOCGIFMEM         0x891f
#define SIOCSIFMEM         0x8920
#define SIOCGIFMTU         0x8921
#define SIOCSIFMTU         0x8922
#define SIOCSIFNAME        0x8923
#define SIOCSIFHWADDR      0x8924
#define SIOCGIFENCAP       0x8925
#define SIOCSIFENCAP       0x8926
#define SIOCGIFHWADDR      0x8927
#define SIOCGIFSLAVE       0x8929
#define SIOCSIFSLAVE       0x8930
#define SIOCADDMULTI       0x8931
#define SIOCDELMULTI       0x8932
#define SIOCGIFINDEX       0x8933
#define SIOGIFINDEX        SIOCGIFINDEX
#define SIOCSIFPFLAGS      0x8934
#define SIOCGIFPFLAGS      0x8935
#define SIOCDIFADDR        0x8936
#define SIOCSIFHWBROADCAST 0x8937
#define SIOCGIFCOUNT       0x8938
#define SIOCGIFBR          0x8940
#define SIOCSIFBR          0x8941
#define SIOCGIFTXQLEN      0x8942
#define SIOCSIFTXQLEN      0x8943
#define SIOCDARP           0x8953
#define SIOCGARP           0x8954
#define SIOCSARP           0x8955
#define SIOCDRARP          0x8960
#define SIOCGRARP          0x8961
#define SIOCSRARP          0x8962
#define SIOCGIFMAP         0x8970
#define SIOCSIFMAP         0x8971
#define SIOCADDDLCI        0x8980
#define SIOCDELDLCI        0x8981
#define SIOCPROTOPRIVATE   0x89e0
#define SIOCDEVPRIVATE     0x89f0

int ioctl(int __fd, unsigned long __request, ...);

#endif /* _RUBYCC_SYS_IOCTL_H */
