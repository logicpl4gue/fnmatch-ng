/* bench/adversarial_musl.c — per-case musl fnmatch() timing driver for the
 * adversarial complexity study (plan section 21).
 *
 * Reads ONE JSON-lines corpus case from stdin (same schema the zig side of
 * bench/adversarial.zig emits, and parseable by the embedded reference
 * harness parser), times the reference fnmatch() on it, and prints one
 * JSON object:
 *
 *   {"result":"MATCH"|"NOMATCH","ns":<ns per call>}
 *
 * The timing loop probes a single call first; if that call alone takes
 * > 0.5 ms the loop uses batch=1 (never amortizes a slow call behind a big
 * batch), otherwise batch=256 calls per timed chunk. It stops once ~2 ms
 * have accrued. bench/adversarial_run.py runs this executable once PER
 * CASE with a hard 5 s wall-clock cap, so a truly pathological case is
 * killed from outside and recorded as TIMEOUT instead of hanging the run.
 *
 * Build, Windows/w64devkit (no system fnmatch):
 *   gcc -O2 -std=c11 -Wall -Wextra -o bench/adversarial_musl.exe \
 *       bench/adversarial_musl.c compat/musl_fnmatch.c
 */

#define _GNU_SOURCE
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

int main(int argc, char **argv)
{
    char *line = NULL, *pat, *str;
    size_t cap = 0;
    long ln;
    int flags = 0;
    char err[256];
    volatile int sink = 0;
    double one, acc = 0.0;
    long batch, iters = 0, k;
    int r;
    const char *res;

    if (argc != 1) {
        fprintf(stderr, "usage: %s < one JSON-lines corpus case on stdin\n", argv[0]);
        return 2;
    }
    ln = read_line(stdin, &line, &cap);
    if (ln < 0) {
        fprintf(stderr, "no input\n");
        return 2;
    }
    while (ln > 0 && line[ln - 1] == '\r')
        line[--ln] = '\0';
    if (ln == 0) {
        free(line);
        return 2;
    }
    pat = malloc((size_t)ln + 1);
    str = malloc((size_t)ln + 1);
    if (!pat || !str) {
        fprintf(stderr, "out of memory\n");
        return 2;
    }
    if (parse_case(line, pat, str, &flags, err, sizeof err)) {
        fprintf(stderr, "parse error: %s\n", err);
        return 2;
    }

    /* reference result for this case (cross-checked by the runner) */
    r = fnmatch(pat, str, flags);
    res = r == 0 ? "MATCH" : (r == FNM_NOMATCH ? "NOMATCH" : "ERROR");

    /* probe one call so a slow case never hides behind a big batch */
    {
        double t0 = now_ns();
        sink ^= fnmatch(pat, str, flags);
        one = now_ns() - t0;
    }
    batch = one > 5e5 ? 1 : 256;
    while (acc < 2e6 && iters < (1L << 26)) {
        double t0 = now_ns();
        for (k = 0; k < batch; k++)
            sink ^= fnmatch(pat, str, flags);
        acc += now_ns() - t0;
        iters += batch;
    }
    (void)sink; /* result sink referenced after the loop (keeps calls live) */

    printf("{\"result\":\"%s\",\"ns\":%.0f}\n",
           res, iters > 0 ? acc / (double)iters : 0.0);
    free(pat);
    free(str);
    free(line);
    return 0;
}
