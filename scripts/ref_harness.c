/* scripts/ref_harness.c — M0 reference harness for fnmatch-ng.
 *
 * Thin wrapper around the reference fnmatch(). Reads one JSON object per
 * line from stdin and prints one result line per input line:
 *
 *   {"pattern":"*.c","string":"main.c","flags":[]}
 *     ->  MATCH
 *   {"pattern":"a*b","string":"a/b","flags":["FNM_PATHNAME"]}
 *     ->  NOMATCH
 *   <malformed line>             ->  ERROR: line N: <reason>
 *
 * Supported "flags" names (case-sensitive): FNM_PATHNAME, FNM_NOESCAPE,
 * FNM_PERIOD, FNM_CASEFOLD. A flag the platform libc does not define is
 * reported as ERROR rather than silently dropped, so a corpus never runs
 * with unintended semantics. Any other object key (e.g. "result", which
 * corpus files carry per plan §9.4) is ignored: the harness always reports
 * what it computed, never the corpus expectation. Blank lines are skipped.
 *
 * JSON subset parsed (dependency-free, intentionally documented):
 *   - objects with string keys; unknown keys are skipped,
 *   - string values with full JSON escaping: \" \\ \/ \b \f \n \r \t and
 *     \uXXXX including surrogate pairs (decoded to UTF-8),
 *   - "flags" as an array of plain flag names.
 * Corpora are machine-generated (planned scripts/differential.*), so this
 * subset is sufficient; malformed input is reported as ERROR per line.
 *
 * Reference binding (see compat/README.md):
 *   - platform <fnmatch.h> present  -> calls the system libc fnmatch();
 *   - <fnmatch.h> absent            -> expects compat/musl_fnmatch.c to be
 *     linked. This is the case on w64devkit/MinGW for Windows, which ships
 *     no fnmatch at all. No system fnmatch on this box is why M0's
 *     reference is musl — one of the plan's two sanctioned references.
 *
 * Output modes:
 *   default            one plain line per case: MATCH | NOMATCH | ERROR: ...
 *   --json             one JSON object per case instead:
 *                      {"result":"MATCH"} | {"result":"NOMATCH"} |
 *                      {"result":"ERROR","detail":"..."}
 *                      This is the wire protocol expected by
 *                      scripts/differential.py (run it with
 *                      --harness "scripts/ref_harness --json").
 *
 * Build, POSIX (from the repo root):
 *   cc -O2 -std=c11 -o scripts/ref_harness scripts/ref_harness.c
 * Build, Windows/w64devkit (no system fnmatch):
 *   gcc -O2 -std=c11 -o scripts/ref_harness.exe scripts/ref_harness.c compat/musl_fnmatch.c
 * Run:
 *   ./scripts/ref_harness < corpus.jsonl > results.txt
 *   ./scripts/ref_harness --json < corpus.jsonl > results.jsonl
 */

#define _GNU_SOURCE  /* glibc: FNM_PERIOD/FNM_CASEFOLD + POSIX decls */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

#if defined(__has_include)
#  if __has_include(<fnmatch.h>)
#    include <fnmatch.h>
#  else
#    include "../compat/musl_fnmatch.h"
#    define FNMATCH_NG_REF_COMPAT_MUSL 1
#  endif
#else
#  include <fnmatch.h>
#endif

/* ---- tiny JSON-lines parser (C stdlib only) -------------------------- */

static int hex_val(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Parse 4 hex digits at *pp into *cp. Returns 0 on success. */
static int read_hex4(const char **pp, unsigned long *cp)
{
    unsigned long v = 0;
    int i;
    for (i = 0; i < 4; i++) {
        int h = hex_val((unsigned char)(*pp)[i]);
        if (h < 0) return -1;
        v = (v << 4) | (unsigned)h;
    }
    *pp += 4;
    *cp = v;
    return 0;
}

static int utf8_len(unsigned long cp)
{
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

/* Encode cp as UTF-8 into dst (must hold utf8_len(cp) bytes). */
static void utf8_emit(unsigned long cp, char *dst)
{
    if (cp < 0x80) {
        dst[0] = (char)cp;
    } else if (cp < 0x800) {
        dst[0] = (char)(0xC0 | (cp >> 6));
        dst[1] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        dst[0] = (char)(0xE0 | (cp >> 12));
        dst[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        dst[2] = (char)(0x80 | (cp & 0x3F));
    } else {
        dst[0] = (char)(0xF0 | (cp >> 18));
        dst[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        dst[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        dst[3] = (char)(0x80 | (cp & 0x3F));
    }
}

/* Decode one JSON string. *pp must point at the opening quote. Decoded
 * bytes are written to out (a decoded string is never longer than its raw
 * source, so out sized like the remaining input always suffices); out may
 * be NULL to validate-and-skip without writing. If cap is nonzero, at most
 * cap-1 bytes plus the NUL are written and longer strings are rejected.
 * On success *pp advances past the closing quote and the decoded length is
 * returned; -1 means malformed input. */
static long json_string(const char **pp, char *out, size_t cap)
{
    static const char escs[] = "\"\\/bfnrt";
    static const char repl[] = "\"\\/\b\f\n\r\t";
    const char *p = *pp;
    long o = 0;

    if (*p != '"') return -1;
    p++;
    for (;;) {
        int c = (unsigned char)*p;
        if (c == '"') {
            p++;
            break;
        }
        if (c == '\0') return -1;            /* unterminated */
        if (c == '\\') {
            const char *m;
            if (!p[1]) return -1;            /* trailing backslash */
            m = strchr(escs, (unsigned char)p[1]);
            if (m) {
                if (out) {
                    if (cap && o >= (long)cap - 1) return -1;
                    out[o] = repl[m - escs];
                }
                o++;
                p += 2;
                continue;
            }
            if (p[1] == 'u') {
                const char *q = p + 2;
                unsigned long cp;
                int nb;
                if (read_hex4(&q, &cp)) return -1;
                if (cp >= 0xD800 && cp <= 0xDBFF) {      /* high surrogate */
                    const char *r;
                    unsigned long lo;
                    if (q[0] != '\\' || q[1] != 'u') return -1;
                    r = q + 2;
                    if (read_hex4(&r, &lo)) return -1;
                    if (lo < 0xDC00 || lo > 0xDFFF) return -1;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    q = r;
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return -1;               /* lone low surrogate */
                }
                nb = utf8_len(cp);
                if (out) {
                    if (cap && o + nb >= (long)cap) return -1;
                    utf8_emit(cp, out + o);
                }
                o += nb;
                p = q;
                continue;
            }
            return -1;                       /* unknown escape */
        }
        if (c < 0x20) return -1;             /* raw control character */
        if (out) {
            if (cap && o >= (long)cap - 1) return -1;
            out[o] = (char)c;
        }
        o++;
        p++;
    }
    if (out) out[o] = '\0';
    *pp = p;
    return o;
}

static void skip_ws(const char **pp)
{
    while (**pp == ' ' || **pp == '\t' || **pp == '\r' || **pp == '\n')
        (*pp)++;
}

/* Does p point at "\"want\"" (want plain, no escapes)? Returns the number
 * of characters to advance past it, or 0 for no match. */
static long json_raw_advance(const char *p, const char *want)
{
    size_t wn = strlen(want);
    if (p[0] != '"') return 0;
    if (memcmp(p + 1, want, wn) != 0) return 0;
    if (p[wn + 1] != '"') return 0;
    return (long)wn + 2;
}

static int fail(char *err, size_t errsz, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errsz, fmt, ap);
    va_end(ap);
    return -1;
}

/* Skip a value we do not care about: a string or an array of strings.
 * Returns 0 on success; *pp left after the value. */
static int skip_value(const char **pp)
{
    const char *p = *pp;
    if (*p == '"')
        return json_string(&p, NULL, 0) < 0 ? -1 : (*pp = p, 0);
    if (*p == '[') {
        p++;
        for (;;) {
            skip_ws(&p);
            if (*p == ']') {
                p++;
                *pp = p;
                return 0;
            }
            if (*p == '\0' || *p == '}') return -1;
            if (*p == ',') {
                p++;
                continue;
            }
            if (json_string(&p, NULL, 0) < 0) return -1;
        }
    }
    return -1;
}

/* Parse the "flags" array at *pp (which must point at '['). Recognized
 * names are listed below; a name this build cannot honor is an error, so
 * corpora fail loudly instead of silently running with fewer flags. */
static int parse_flags(const char **pp, int *f, char *err, size_t errsz)
{
    const char *p = *pp;
    long adv;

    if (*p != '[') return fail(err, errsz, "flags: expected '['");
    p++;
    for (;;) {
        skip_ws(&p);
        if (*p == ']') {
            p++;
            *pp = p;
            return 0;
        }
        if (*p == '\0' || *p == '}') return fail(err, errsz, "flags: unterminated array");
        if (*p == ',') {
            p++;
            continue;
        }
        if ((adv = json_raw_advance(p, "FNM_PATHNAME")) > 0) {
            *f |= FNM_PATHNAME;
            p += adv;
            continue;
        }
        if ((adv = json_raw_advance(p, "FNM_NOESCAPE")) > 0) {
            *f |= FNM_NOESCAPE;
            p += adv;
            continue;
        }
#ifdef FNM_PERIOD
        if ((adv = json_raw_advance(p, "FNM_PERIOD")) > 0) {
            *f |= FNM_PERIOD;
            p += adv;
            continue;
        }
#endif
#ifdef FNM_CASEFOLD
        if ((adv = json_raw_advance(p, "FNM_CASEFOLD")) > 0) {
            *f |= FNM_CASEFOLD;
            p += adv;
            continue;
        }
#endif
        return fail(err, errsz, "unknown or unsupported flag");
    }
}

/* Parse one JSON object (already NUL-terminated, no trailing newline)
 * into decoded pat/str and an fnmatch() flags bitmask. Both pat and str
 * buffers must hold strlen(line)+1 bytes. Returns 0 or -1 with err set. */
static int parse_case(const char *s, char *pat, char *str, int *flags,
                      char *err, size_t errsz)
{
    const char *p = s;
    int have_pat = 0, have_str = 0;
    int f = 0;

    skip_ws(&p);
    if (*p != '{') return fail(err, errsz, "expected '{'");
    p++;
    skip_ws(&p);
    if (*p == '}') return fail(err, errsz, "empty object");
    for (;;) {
        char key[64];
        long kl;

        skip_ws(&p);
        if (*p != '"') return fail(err, errsz, "expected object key");
        kl = json_string(&p, key, sizeof key);
        if (kl < 0) return fail(err, errsz, "malformed object key");
        skip_ws(&p);
        if (*p != ':') return fail(err, errsz, "expected ':' after key");
        p++;
        skip_ws(&p);

        if (strcmp(key, "pattern") == 0) {
            if (json_string(&p, pat, 0) < 0)
                return fail(err, errsz, "malformed pattern value");
            have_pat = 1;
        } else if (strcmp(key, "string") == 0) {
            if (json_string(&p, str, 0) < 0)
                return fail(err, errsz, "malformed string value");
            have_str = 1;
        } else if (strcmp(key, "flags") == 0) {
            if (parse_flags(&p, &f, err, errsz)) return -1;
        } else {
            if (skip_value(&p))
                return fail(err, errsz, "malformed value for key '%s'", key);
        }

        skip_ws(&p);
        if (*p == '}') {
            p++;
            break;
        }
        if (*p != ',') return fail(err, errsz, "expected ',' or '}'");
        p++;
    }
    skip_ws(&p);
    if (*p != '\0') return fail(err, errsz, "trailing data after '}'");
    if (!have_pat || !have_str)
        return fail(err, errsz, "case missing 'pattern' or 'string'");
    *flags = f;
    return 0;
}

/* ---- reference invocation ------------------------------------------- */

static const char *run_case(const char *pat, const char *str, int flags,
                            char *err, size_t errsz)
{
    int r = fnmatch(pat, str, flags);
    if (r == 0) return "MATCH";
    if (r == FNM_NOMATCH) return "NOMATCH";
    fail(err, errsz, "fnmatch returned %d", r);
    return NULL;
}

/* ---- line reader (portable getline replacement) ---------------------- */

/* Read one line (without its trailing '\n') into *buf, growing *buf and
 * *cap as needed. NUL-terminates; returns the length, or -1 on EOF with
 * no data read. */
static long read_line(FILE *fp, char **buf, size_t *cap)
{
    size_t n = 0;
    for (;;) {
        int c = fgetc(fp);
        if (c == '\n' || c == EOF) {
            if (c == EOF && n == 0) return -1;
            if (n >= *cap) {
                size_t ncap = *cap ? *cap * 2 : 256;
                char *nb = realloc(*buf, ncap);
                if (!nb) return -1;
                *buf = nb;
                *cap = ncap;
            }
            (*buf)[n] = '\0';
            return (long)n;
        }
        if (n >= *cap) {
            size_t ncap = *cap ? *cap * 2 : 256;
            char *nb = realloc(*buf, ncap);
            if (!nb) return -1;
            *buf = nb;
            *cap = ncap;
        }
        (*buf)[n++] = (char)c;
    }
}

/* ---- main ------------------------------------------------------------ */

/* Print err (a NUL-terminated C string) JSON-escaped to stdout. */
static void json_puts_escaped(const char *s)
{
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"':  fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20) printf("\\u%04x", c);
            else putchar((char)c);
        }
    }
}

int main(int argc, char **argv)
{
    int json_out = argc == 2 && strcmp(argv[1], "--json") == 0;
    char *line = NULL;
    size_t cap = 0;
    long lineno = 0;

    if (argc > 1 && !json_out) {
        fprintf(stderr, "usage: %s [--json] < corpus.jsonl\n", argv[0]);
        return 2;
    }
    while (read_line(stdin, &line, &cap) >= 0) {
        size_t len;
        char *pat, *str;
        int flags = 0, blank = 1;
        char err[256];
        size_t i;

        lineno++;
        len = strlen(line);
        while (len > 0 && line[len - 1] == '\r')  /* tolerate CRLF */
            line[--len] = '\0';
        for (i = 0; i < len; i++) {
            if (!isspace((unsigned char)line[i])) {
                blank = 0;
                break;
            }
        }
        if (blank) continue;

        /* decoded strings are never longer than the raw line */
        pat = malloc(len + 1);
        str = malloc(len + 1);
        if (!pat || !str) {
            fprintf(stderr, "out of memory\n");
            return 2;
        }
        if (parse_case(line, pat, str, &flags, err, sizeof err)) {
            if (json_out) {
                printf("{\"result\":\"ERROR\",\"detail\":\"line %ld: ", lineno);
                json_puts_escaped(err);
                printf("\"}\n");
            } else {
                printf("ERROR: line %ld: %s\n", lineno, err);
            }
        } else {
            const char *res = run_case(pat, str, flags, err, sizeof err);
            if (res) {
                if (json_out)
                    printf("{\"result\":\"%s\"}\n", res);
                else
                    printf("%s\n", res);
            } else {
                if (json_out) {
                    printf("{\"result\":\"ERROR\",\"detail\":\"line %ld: ", lineno);
                    json_puts_escaped(err);
                    printf("\"}\n");
                } else {
                    printf("ERROR: line %ld: %s\n", lineno, err);
                }
            }
        }
        free(pat);
        free(str);
    }
    free(line);
    return 0;
}
