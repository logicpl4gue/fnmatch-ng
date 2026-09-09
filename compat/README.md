# compat/ — vendored reference implementation

The platform this repo's M0 work started on (Windows + w64devkit gcc,
MinGW-w64 target) ships **no `fnmatch` at all**: no `<fnmatch.h>`, no libc
symbol. POSIX `fnmatch` is one of the plan's two sanctioned behavioral
references (plan §4 Stage B: glibc, musl), so the harness falls back to a
vendored musl implementation when the platform libc lacks one.

- `musl_fnmatch.c` — verbatim musl **1.2.5** `src/regex/fnmatch.c`
  ("Sea of Stars" algorithm, Rich Felker).
- `musl_fnmatch.h` — verbatim musl 1.2.5 `include/fnmatch.h`, include
  guard renamed `_FNMATCH_H` -> `MUSL_FNMATCH_H` so it can never collide
  with a system header in the same translation unit.

## Local modifications to musl_fnmatch.c (all documented in-file)

1. `#include <fnmatch.h>` -> `#include "musl_fnmatch.h"` (self-contained).
2. `#include "locale_impl.h"` (musl-internal) replaced with a
   `#define MB_CUR_MAX 1` shim. The file uses nothing else from that
   header, and the M0 locale scope is the C/POSIX locale (plan §5), where
   musl's own `MB_CUR_MAX` is 1, so behavior is unchanged within scope.
3. Provenance header added. No algorithm or token changed.

## License

musl is MIT licensed. Copyright © 2005-2020 Rich Felker and others.
Full text: <https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT>

## Selection logic (scripts/ref_harness.c)

```
<fnmatch.h> present  -> call the system libc fnmatch()   (POSIX builds)
<fnmatch.h> absent   -> compile+link compat/musl_fnmatch.c
```

On POSIX, do **not** link `compat/musl_fnmatch.c` unless you deliberately
want musl's behavior: its `fnmatch` symbol would override the libc one at
link time (possible later for musl-vs-glibc differential runs).

Upgrade path: run the same harness sources on a Linux box to get true
glibc reference results — no code change is needed, only the documented
POSIX build command.
