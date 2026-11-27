# Agent rules and repository architecture

Standalone rulebook for agents working in `goose-lit`. Keep this file under 13.5
KB so harnesses never truncate it.

## Architecture and public API boundary

Goose has no `private` visibility keyword, so `goose-lit` enforces visibility
through package facades and namespaces:

- Public library facade: [`lit.goose`](lit.goose) + [`lit.build`](lit.build)
  export only `namespace lit;` (`testkit/*`, `wire/*`, and minimal
  [`sys/time.goose`](sys/time.goose)). `lit.goose` must never import
  `sys.bytes`, `namespace crap;`, or CLI subsystems. That keeps consumer test
  builds fast and isolated from CLI internals.
- Internal facade plumbing: helper functions, structs, and C FFI bindings inside
  `lit.goose` modules live in `namespace lit_internal;` (file-level
  `namespace lit_internal;` or inline `fn lit_internal::...`,
  `struct lit_internal::...`, `extern fn lit_internal::...`). This matches the
  `<pkg>_internal::` convention in `goose-wing` and avoids collisions when tests
  import both packages.
- Internal CLI facade and entry point: [`cli.goose`](cli.goose) +
  [`cli.build`](cli.build) and [`bin.goose`](bin.goose) carry no library API
  stability guarantees.

Module map:

- `testkit/`: in-process runner (`T`, `Runner`, `Verbosity`, `run`, `run_table`,
  `run_case`, `finish`), assertions (`assert_*`, `require_*`), and mocks
  (`MockClock`, `MockMonoClock`, `FuzzRng`, `CallRecord`). Also provides
  contained-thread sandboxing (`wait_contained_result`,
  `expect_contained_abort`, `assert_balanced`), alloc counters (`alloc_*`,
  `verify_zero_allocs`), profiler and `testing.B` benchmarks (`prof_*`,
  `new_bench_suite`, `bench`), and `lit_internal` diff helpers (`diff.goose`).
- `wire/`: split-stream verifier (`verify_split_stream`), hex/quoted payload
  parser (`parse_packet_payload`), `VIRTUAL_PAGE_SIZE`, `xorshift64` mutator
  (`mutate_payload_once`, `fuzz_payload_stream`), and hex/SIMD inspector
  (`format_hexdump`, `format_simd_lanes`).
- `check/`: zero-allocation FileCheck parser and matcher (`CHECK:`, `-NEXT:`,
  `-NOT:`, `-LABEL:`, `-SAME:`, `-EMPTY:`, `-DAG:`, `-COUNT-<N>:`, `{{regex}}`,
  `[[VAR:regex]]`, `[[#VAR + N]]`).
- `runner/`: LIT discovery and `// RUN:` substitution engine
  (`lit_runner.goose`, embeds runtime shims through `embed_file`), package-aware
  parallel `goose check` (`check_cli.goose`), and unified `verify`
  (`verify_cli.goose`).
- `crap/`: lexer, AST complexity analyzer, `goose --bce-lines` / `--specs`
  bridge, source-to-source branch instrumentor, `.gcrap-cov` / LCOV loaders,
  G-CRAP scorer, formatters (`table`, `md`, `json`, `gcc`, `sarif`), and ratchet
  gate.
- `cov/`, `profile/`, `fuzz/`, `sloc/`: CLI engines for branch coverage, stage
  profiling / benchstat diffs, SanCov/libFuzzer fuzzing, and cycles-vs-SLOC
  Pareto radar.
- `sys/`: internal `namespace crap;` byte/line/path/glob helpers
  (`bytes.goose`), `.litconfig` loader (`config.goose`), subprocess/FS wrappers
  (`proc.goose`), and `namespace lit;` clock primitives (`time.goose`).
- `shim/`: portable C11 runtimes (`proc.c`, `profiler.c`, `alloc_count.c`,
  `alloc_hook.h`, `prof_hook.h`, `cov_rt.h`, `fuzz_driver.c`).

## Canonical internal primitives (`sys/*`)

Do not re-implement line loops, glob filters, path normalizers, integer parsers,
or temp capture files in CLI modules. Reuse these `crap::` helpers from
[`sys/bytes.goose`](sys/bytes.goose), [`sys/proc.goose`](sys/proc.goose), and
[`sys/config.goose`](sys/config.goose):

- Character predicates and bounded copies: `is_ascii_space`, `is_ascii_digit`,
  `is_ident_start`, `is_ident_cont`, `ascii_lower`, `set_bounded`.
- Slice search and trimming: `slice_starts_with`, `slice_ends_with`,
  `slice_index_of_byte`, `slice_last_index_of_byte`, `slice_index_of`,
  `slice_contains`, `trim_ascii`.
- Delimiter and newline-blob loops:
  - `take_next_delim(rem, delim) -> tok, rest` and
    `take_next_line(rem) -> line, rest` for read-only parameter slices
    (`while rem.len > 0 { let line, rest = crap::take_next_line(rem); rem = rest; ... }`).
  - `next_line_at(blob, cursor) -> line` for loops over a local `u8[>..]` when
    sibling local `u8[>..]` buffers call `.clear()` in the same loop
    (`while pos != buf.len { let line = crap::next_line_at(buf[..], pos); ... }`).
  - `blob_get_line(blob, idx, out)`, `blob_contains_line(blob, needle)`.
- Glob and path handling: `glob_match`,
  `path_matches_filter(filter_glob, path)`, `normalize_path`,
  `normalize_slashes`, `to_relative_path`, `paths_match`, `short_display_path`,
  `is_excluded_path`.
- Parsing and formatting: `parse_u64_slice`, `parse_i64_slice`,
  `parse_f64_slice`, `append_u64`, `append_i64`, `append_f64_1`, `append_f64_2`,
  `append_json_escaped`, `append_padded_right`, `append_padded_left`.
- Process execution and workspace helpers: `exec_capture`,
  `exec_capture_timeout`, `exec_argv_capture`, `exec_argv_nul_capture`,
  `exec_in_dir_with_env_capture`, `default_auto_jobs`, `resolve_abs_path`,
  `ensure_lit_cache_dir`, `collect_goose_files_filtered`, `load_lit_config`.
- Timing (`namespace lit;` in [`sys/time.goose`](sys/time.goose)): `Duration`,
  `as_micros`, `MonotonicInstant`, `monotonic_now`, `Stopwatch`, `stopwatch`,
  `elapsed`.

## Goose language rules and compiler idioms

- Data-stack memory model: Goose has no heap allocator, GC, or destructors.
  Fixed types (`T[k]`, `T[..k]`, fixed structs, `T[:]`) copy on `=` and in
  `for x in xs`. Growable arrays (`T[>..]`) live on compile-time data stacks.
  Containers with multiple growable fields must use `root struct` and pass by
  reference (`Cfg&`).
- References and zero-copy loops: use `.=` to bind a reference in place
  (`let f_item .= failures[i];`). Use `for &x in xs` when a loop reads struct
  fields to avoid `val_for` copies.
- Slice provenance (§5.1, §9.2, §9.5):
  - Never mutate a `(const u8[:])&` slice header parameter. Return `(tok, rest)`
    by value instead.
  - Never re-bind a slice rooted in caller storage to static string data. Return
    `s[s.len..]` for an empty subslice with matching root.
  - Never keep a mutable `var` slice into a local `u8[>..]` live across a
    sibling `.clear()` call. Use an `i64` cursor (`next_line_at`) instead.
  - Keep an `i64` index cursor on BFS queues (`dir_queue`, `queue`) that append
    during traversal instead of a pre-captured slice.
- Types and built-ins:
  - No integer suffixes (`1u64`), `usize`, or `isize`. Slice `.len` and indices
    use `i64`. Signed overflow aborts in `--debug`. Unsigned overflow wraps.
  - `std` provides `min(a, b)` and `max(a, b)`.
  - `assert(cond)` takes exactly one argument.
  - `print(a, b)` concatenates without spaces. Pass explicit `" "` separators.
  - Narrowing requires `as` (checked) or `as!` (unchecked). Avoid redundant `as`
    casts that trigger compiler warnings.
- Declarations and generics:
  - Write C extern bindings after the return type:
    `extern fn native_exec_to_file(cmd: const u8[:], out_path: const u8[:]) -> i32 = "crap_exec_to_file";`.
  - Function values are compile-time only. Accept callbacks as generic type
    parameters (`fn run_case<F: fn(T&)>(...)`) and call `F(...)` directly.
  - Inline namespace qualification works for helpers inside a module
    (`fn lit_internal::foo(...)`, `struct lit_internal::Bar { ... }`).
- JIT vs compiled tests: TinyCC JIT (`goose %s`) does not support `thread_fn` or
  `thread_spawn_contained`. Compile tests that spawn threads first
  (`// RUN: goose build -O0 %s -o %t && %t | %FileCheck %s`).

## Engineering and C shim invariants

- Zero dynamic allocation on hot paths: wire inspection, prefix slicing,
  mutation, and FileCheck matching use bounded inline buffers (`u8[..N]`) and
  borrowed slices (`const u8[:]`).
- Hoist `u8[>..]` buffers out of loops and call `.clear()` to reuse them. Use
  stack-bounded `u8[..N]` for provably bounded scratch paths (`.lit/cache/...`,
  numeric formatting) to keep data-stack counts and thread caps healthy.
- Zero dead code and zero silent drops: remove unused functions, write-only
  config fields, and dead globals. Check `.cap` before each push or append into
  a bounded buffer.
- BCE hygiene: prefer `for i in n`, `for i in a..b`, and slice-shrinking loops
  (`while rem.len > 0`) over manual index loops (`while i < xs.len`). Avoid
  table indexing for hex nibbles when simple arithmetic removes bounds checks.
- Compile C11 shims (`shim/*.c`, `shim/*.h`) cleanly with
  `gcc -std=c11 -Wall -Wextra -Werror` on Windows and POSIX. Keep weak symbols
  (`GCRAP_WEAK` / `GCRAP_COV_WEAK`) and Unix LF (`\n`) endings.
  [`runner/lit_runner.goose`](runner/lit_runner.goose) embeds `alloc_hook.h`,
  `prof_hook.h`, `cov_rt.h`, and `fuzz_driver.c` through `embed_file` so
  standalone release binaries work without a sibling `shim/` directory.
- Keep the Apache-2.0 SPDX header (`just license-check`) on every `.goose`,
  `.c`, `.h`, `.py`, and `.sh` file. Use Unix LF (`\n`) endings on all
  non-`.cmd`/`.bat` files.

## Verification gates (zero unverified assertions)

Run relevant checks and confirm exit code `0` before you finish:

```powershell
just fmt-check
just license-check
ruff check tools/ scripts/
gcc -std=c11 -Wall -Wextra -Werror -c shim/proc.c -o .lit/cache/p.o
gcc -std=c11 -Wall -Wextra -Werror -c shim/profiler.c -o .lit/cache/pr.o
gcc -std=c11 -Wall -Wextra -Werror -c shim/fuzz_driver.c -o .lit/cache/f.o
goose check --stats --stacks lit.goose
goose check --stats --stacks bin.goose
just build
just check
just test
.\bin\goose-lit.exe check .
.\bin\goose-lit.exe tests/ -j auto
.\bin\goose-lit.exe sloc . --no-baseline --smells
```

After changes to [`wire/mutate.goose`](wire/mutate.goose), run
[`tests/cov_test.goose`](tests/cov_test.goose) (it checks exact branch counts).
After changes to `lit.goose` modules, confirm zero `crap::` leaks and zero
broken symbols for downstream consumers (`goose-wing`).

## Commits, releases, and communication style

- Releases run through `release-please` on `main`. Follow Conventional Commits
  (`feat:`, `fix:`, `refactor:`, `perf:`, `style:`, `test:`, `chore:`). Mark
  breaking changes with `!` or `BREAKING CHANGE:`. Never edit `version.txt` or
  `CHANGELOG.md` by hand.
- Keep git history linear (no merge commits).
- Wrap Markdown prose at 80 columns and validate public docs with
  `goosemarklint fmt --check` and `goosemarklint check`.
- Start replies directly with technical facts or actions. Avoid AI buzzwords
  (`crucial`, `robust`, `comprehensive`, `seamlessly`, `vital`, `testament`,
  `delve`, `meticulously`, `pivotal`, `leverage`), em dashes, and bold-colon
  list items (`- **Item**: ...`). Use sentence-case headings, straight quotes,
  and clickable `file:///` links.
