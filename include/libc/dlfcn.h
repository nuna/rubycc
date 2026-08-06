/* rubycc bundled <dlfcn.h>: the dynamic-loading calls and the RTLD_* mode flags
   (POSIX plus glibc extensions). Provenance: clean room against glibc's public
   dynamic-linking ABI (bits/dlfcn.h), not derived from musl -- and not a kernel
   UAPI, since dlopen is not a system-call interface. The RTLD_* values are that
   ABI reproduced as measured integer constants (an ABI fact, not copied text --
   see docs/HEADER-LICENSING.md); dlopen, dlsym, dlclose and dlerror are POSIX
   declarations whose bodies resolve from the host libc at link time (the same
   way errno.h's __errno_location does). Common layer: every RTLD_* value is
   identical on x86-64 and aarch64. */

#ifndef _RUBYCC_DLFCN_H
#define _RUBYCC_DLFCN_H

/* Binding modes (POSIX): one of these is required in the dlopen mode. */
#define RTLD_LAZY   0x00001
#define RTLD_NOW    0x00002

/* Symbol visibility of the loaded object (POSIX). RTLD_LOCAL is the zero
   default -- the absence of RTLD_GLOBAL. */
#define RTLD_GLOBAL 0x00100
#define RTLD_LOCAL  0

/* glibc extensions to the dlopen mode. */
#define RTLD_NOLOAD   0x00004
#define RTLD_DEEPBIND 0x00008
#define RTLD_NODELETE 0x01000

/* Pseudo-handles for dlsym (glibc extensions): the next object after this one
   in the search order, and the global default scope. */
#define RTLD_NEXT    ((void *) -1l)
#define RTLD_DEFAULT ((void *) 0)

void *dlopen(const char *__file, int __mode);
void *dlsym(void *__handle, const char *__name);
int   dlclose(void *__handle);
char *dlerror(void);

/* Requests accepted by the glibc dlinfo extension.  They are enum constants
   in the system header (rather than preprocessor macros), so extensions that
   probe them with mkmf's have_const can see the same interface here. */
enum {
    RTLD_DI_LMID = 1,
    RTLD_DI_LINKMAP = 2,
    RTLD_DI_CONFIGADDR = 3,
    RTLD_DI_SERINFO = 4,
    RTLD_DI_SERINFOSIZE = 5,
    RTLD_DI_ORIGIN = 6,
    RTLD_DI_PROFILENAME = 7,
    RTLD_DI_PROFILEOUT = 8,
    RTLD_DI_TLS_MODID = 9,
    RTLD_DI_TLS_DATA = 10,
    RTLD_DI_PHDR = 11,
    RTLD_DI_MAX = 11
};

int dlinfo(void *__handle, int __request, void *__arg);

#endif /* _RUBYCC_DLFCN_H */
