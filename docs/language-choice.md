# Language choice: Zig

**Decision: Zig** (actual toolchain 0.14.1; build.zig targets 0.14.1 API — doc's earlier "0.16.x" corrected).

Ranking per plan §3 rule (compatibility → compact impl → benchmarking → C ABI → fuzzability): **Zig > Rust > C3.**

1. **C ABI + 0-alloc are free:** `export fn … callconv(.C)` → tiny .so/.dll, no runtime; 0-alloc matcher is the default mode.
2. **Benchmarking without confounds:** one `build.zig` builds the lib ReleaseFast + bench harness against libc `fnmatch` under the same LLVM codegen; cross-compile built in.
3. **Compatibility:** C-shaped byte-walk transliterates 1:1 from the C reference; existing tiny Zig glob ports prove the size story.

Rust loses on ceremony (`cdylib` + `panic=abort` + export-symbol hygiene) for a ≤500 LOC C replacement; it only wins fuzzability (lowest-ranked criterion). C3 is pre-1.0 with no fuzz story.

**Key risk:** Zig is pre-1.0 (breaking std changes; integrated fuzzer brand-new in 0.16). Mitigation: pin toolchain in CI/docs; differential-fuzz through the C ABI against libc `fnmatch` regardless of Zig's fuzzer maturity.
