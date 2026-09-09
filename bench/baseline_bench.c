/* bench/baseline_bench.c — M0 baseline timing for the reference fnmatch.
 *
 * Loads a JSON-lines corpus (identical format to scripts/ref_harness.c),
 * runs every parseable case through the reference fnmatch() and reports
 * per-case cost: median/mean/p95/min/max ns per match, plus how many
 * corpus lines were skipped as blank/parse errors. Only the fnmatch()
 * call itself is timed; corpus parsing happens up front, outside the
 * timed region.
 *
 * Corpus parsing and flag mapping must stay bit-identical with the
 * reference harness, so this file embeds scripts/ref_harness.c (its stdin
 * main() is renamed away) and reuses its parser and reference binding.
 *
 * Build, POSIX (from the repo root):
 *   cc -O2 -std=c11 -o bench/baseline_bench bench/baseline_bench.c
 * Build, Windows/w64devkit (no system fnmatch):
 *   gcc -O2 -std=c11 -o bench/baseline_bench.exe bench/baseline_bench.c compat/musl_fnmatch.c
 * Run:
 *   ./bench/baseline_bench corpus.jsonl
 */

#define _GNU_SOURCE  /* must precede the embedded harness includes */
#define main ref_harness_stdin_main
#include "../scripts/ref_harness.c"
#undef main

#include <time.h>

#if defined(_WIN32)
#include <windows.h>
static double now_ns(void)
{
    LARGE_INTEGER freq, cnt;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&cnt);
    return 1000000000.0 * (double)cnt.QuadPart / (double)freq.QuadPart;
}
#else
static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
}
#endif

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a;
    double y = *(const double *)b;
    return (x > y) - (x < y);
}

typedef struct {
    char *pat;
    char *str;
    int flags;
} Case;

int main(int argc, char **argv)
{
    Case *cases = NULL;
    size_t ncases = 0, ncap = 0;
    long parsed = 0, perr = 0;
    char *line = NULL;
    size_t cap = 0;
    long ln;
    FILE *fp;

    if (argc != 2) {
        fprintf(stderr, "usage: %s corpus.jsonl\n", argv[0]);
        return 2;
    }
    fp = fopen(argv[1], "r");
    if (!fp) {
        perror(argv[1]);
        return 2;
    }

    /* 1. parse the whole corpus into memory (not timed) */
    while ((ln = read_line(fp, &line, &cap)) >= 0) {
        size_t len, i;
        char *pat, *str;
        int flags = 0, blank = 1;
        char err[256];

        parsed++;
        len = (size_t)ln;
        while (len > 0 && line[len - 1] == '\r')
            line[--len] = '\0';
        for (i = 0; i < len; i++) {
            if (!isspace((unsigned char)line[i])) {
                blank = 0;
                break;
            }
        }
        if (blank) continue;

        pat = malloc(len + 1);
        str = malloc(len + 1);
        if (!pat || !str || parse_case(line, pat, str, &flags, err, sizeof err)) {
            perr++;
            free(pat);
            free(str);
            continue;
        }
        if (ncases == ncap) {
            Case *nc;
            ncap = ncap ? ncap * 2 : 64;
            nc = realloc(cases, ncap * sizeof *nc);
            if (!nc) {
                fprintf(stderr, "out of memory\n");
                return 2;
            }
            cases = nc;
        }
        cases[ncases].pat = pat;
        cases[ncases].str = str;
        cases[ncases].flags = flags;
        ncases++;
    }
    fclose(fp);
    if (ncases == 0) {
        fprintf(stderr, "%s: no parseable cases (%ld lines, %ld skipped)\n",
                argv[1], parsed, perr);
        return 2;
    }

    /* 2. timed measurement: one warm-up pass over the corpus, then a
     * per-case adaptive loop (batches of 64 calls until ~0.2 ms accrued).
     * The volatile sink keeps call results live so the compiler cannot
     * elide calls; its cost is a small constant bias shared by all cases.
     * ponytail: budget is a flat 0.2 ms/case — if a corpus ever mixes
     * nanosecond and millisecond cases badly, switch to a fixed iteration
     * histogram instead of adaptive per-case sampling. */
    {
        volatile int sink = 0;
        size_t i;
        double *per_case;
        double sum = 0.0, lo = 0.0, hi = 0.0;
        const double budget = 200e3;   /* target measurement ns per case */
        const long batch = 64;

        for (i = 0; i < ncases; i++)
            sink ^= fnmatch(cases[i].pat, cases[i].str, cases[i].flags);

        per_case = malloc(ncases * sizeof *per_case);
        if (!per_case) {
            fprintf(stderr, "out of memory\n");
            return 2;
        }
        for (i = 0; i < ncases; i++) {
            double acc = 0.0;
            long iters = 0;
            do {
                double t0 = now_ns();
                long k;
                for (k = 0; k < batch; k++)
                    sink ^= fnmatch(cases[i].pat, cases[i].str, cases[i].flags);
                acc += now_ns() - t0;
                iters += batch;
            } while (acc < budget && iters < (1L << 20));
            per_case[i] = acc / (double)iters;
            sum += per_case[i];
            if (i == 0) {
                lo = hi = per_case[i];
            } else {
                if (per_case[i] < lo) lo = per_case[i];
                if (per_case[i] > hi) hi = per_case[i];
            }
        }
        (void)sink;  /* mark the sink read; keeps -Wunused-but-set quiet */

        /* 3. report */
        qsort(per_case, ncases, sizeof *per_case, cmp_d);
        printf("corpus:    %s\n", argv[1]);
        printf("cases:     %zu parsed, %ld lines skipped (blank/parse error)\n",
               ncases, perr);
#ifdef FNMATCH_NG_REF_COMPAT_MUSL
        printf("reference: vendored musl fnmatch 1.2.5 (compat/musl_fnmatch.c; "
               "platform has no system fnmatch)\n");
#else
        printf("reference: system libc fnmatch\n");
#endif
        printf("median:    %.0f ns/match\n", per_case[ncases / 2]);
        printf("mean:      %.0f ns/match\n", sum / (double)ncases);
        printf("p95:       %.0f ns/match\n",
               per_case[(size_t)((ncases - 1) * 0.95)]);
        printf("min:       %.0f ns/match\n", lo);
        printf("max:       %.0f ns/match\n", hi);
        free(per_case);
    }
    return 0;
}
