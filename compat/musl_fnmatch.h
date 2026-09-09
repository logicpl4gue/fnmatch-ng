/* compat/musl_fnmatch.h - vendored musl reference header.
 * Verbatim copy of musl 1.2.5 include/fnmatch.h with the include guard
 * renamed (musl uses _FNMATCH_H) so it can coexist with a system
 * <fnmatch.h> in one translation unit if ever both are included.
 * MIT license; see compat/README.md. */
#ifndef	MUSL_FNMATCH_H
#define	MUSL_FNMATCH_H

#ifdef __cplusplus
extern "C" {
#endif

#define	FNM_PATHNAME 0x1
#define	FNM_NOESCAPE 0x2
#define	FNM_PERIOD   0x4
#define	FNM_LEADING_DIR	0x8           
#define	FNM_CASEFOLD	0x10
#define	FNM_FILE_NAME	FNM_PATHNAME

#define	FNM_NOMATCH 1
#define FNM_NOSYS   (-1)

int fnmatch(const char *, const char *, int);

#ifdef __cplusplus
}
#endif

#endif /* MUSL_FNMATCH_H */
