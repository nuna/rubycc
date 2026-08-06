/* Clean-room ABI subset: rubycc bundled <regex.h> exposes the POSIX
   regular-expression ABI used by C
   extensions such as oj. The public regex_t layout is part of glibc's ABI;
   the implementation behind regcomp/regexec remains the host libc. */

#ifndef _RUBYCC_REGEX_H
#define _RUBYCC_REGEX_H

#include <stddef.h>

typedef unsigned long reg_syntax_t;

struct re_dfa_t;
struct re_pattern_buffer {
    struct re_dfa_t *buffer;
    unsigned long allocated;
    unsigned long used;
    reg_syntax_t syntax;
    char *fastmap;
    unsigned char *translate;
    size_t re_nsub;
    unsigned can_be_null : 1;
    unsigned regs_allocated : 2;
    unsigned fastmap_accurate : 1;
    unsigned no_sub : 1;
    unsigned not_bol : 1;
    unsigned not_eol : 1;
    unsigned newline_anchor : 1;
};
typedef struct re_pattern_buffer regex_t;

typedef int regoff_t;
typedef struct {
    regoff_t rm_so;
    regoff_t rm_eo;
} regmatch_t;

#define REG_EXTENDED 1
#define REG_ICASE (1 << 1)
#define REG_NEWLINE (1 << 2)
#define REG_NOSUB (1 << 3)
#define REG_NOTBOL 1
#define REG_NOTEOL (1 << 1)
#define REG_STARTEND (1 << 2)

int regcomp(regex_t *__preg, const char *__pattern, int __cflags);
int regexec(const regex_t *__preg, const char *__string, size_t __nmatch,
            regmatch_t *__pmatch, int __eflags);
size_t regerror(int __errcode, const regex_t *__preg, char *__errbuf,
                size_t __errbuf_size);
void regfree(regex_t *__preg);

#endif /* _RUBYCC_REGEX_H */
