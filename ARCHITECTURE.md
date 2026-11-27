# Architecture

goose-lit is a test runtime, FileCheck matcher, branch coverage collector, stage profiler, coverage-guided fuzzer, binary stream verifier, and G-CRAP / SLOC analyzer for Goose. It operates as an external tool for Goose repositories (such as `goose-wing` and third-party packages) without adding library dependencies to production targets.

The contract between a target codebase and goose-lit consists of command-line calls and borrowed byte slices (`const u8[:]`).

## Execution and isolation

goose-lit uses language features of Goose to verify targets:
- In-process test isolation: the runner executes tests using `thread_spawn_contained`. If a test worker aborts from an out-of-bounds access, an integer overflow, or an assertion failure, the runner catches the abort and reports the failure without terminating the runner process.
- Virtual page-boundary simulation: binary stream tests place buffers at the end of a 64 KB memory page (`65536 - len`) and supply sliced prefixes to detect buffer overreads.
- Embedded runtime shims: `alloc_hook.h`, `prof_hook.h`, `cov_rt.h`, and `fuzz_driver.c` are compiled into the CLI via `embed_file` and materialized into `.lit/cache/shim/` when a standalone release binary runs outside a source checkout.

## Four-layer verification pipeline

Verification runs through four sequential stages:

```text
+-----------------------------------------------------------------------------+
| Layer 1: Static risk gate, BCE radar & cycles-vs-SLOC (G-CRAP / sloc)       |
|   • Lexical and AST analysis (CC, Cog, packing density, compiler smells)    |
|   • goose --bce-lines compiler output (elided vs unproven bounds checks)    |
|   • Real branch coverage profiles (.gcrap-cov, LCOV) and ratchet checks     |
|   • Archetype flags: PANIC_HAZARD, FALSE_ALARM, FUZZ_TARGET                 |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 2: Virtual page edge & binary wire fuzzer (lit::wire & fuzz)          |
|   • verify_split_stream(buf, incomplete_code, ok_code, decoder)             |
|   • Prefixes 1..N-1 tested for incomplete status codes                      |
|   • Bit flips, boundary bytes, and byte swaps via xorshift64                |
|   • SanCov / libFuzzer coverage-guided fuzzing with RSS and O(n) gates      |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 3: FileCheck & LIT test runner (lit::check & lit::runner)             |
|   • // RUN: directive parsing and substitutions (%s, %S, %t, %FileCheck)    |
|   • CHECK:, CHECK-NEXT:, CHECK-NOT:, CHECK-LABEL:, CHECK-SAME:,             |
|     CHECK-EMPTY:, CHECK-DAG:, CHECK-COUNT-<N>:                              |
|   • Parallel test execution and typechecking (`check`, `verify`)            |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 4: Sandboxed assertions, allocs & profiler (lit::testkit & profile)   |
|   • thread_spawn_contained test workers                                     |
|   • expect_contained_abort verification of bounds traps and panics          |
|   • Zero-alloc checks, data-stack watermarks, and RDTSC stage profiling     |
+-----------------------------------------------------------------------------+
```

## Module layout

```text
goose-lit/
├── bin.goose                # CLI entry point (runner, check, cov, verify, filecheck, crap, profile, sloc, fuzz, inspect)
├── lit.goose                # Root library interface
├── lit.build                # Goose package sidecar build configuration
├── check/
│   └── filecheck.goose      # FileCheck directive parser and matcher
├── cov/
│   └── cli.goose            # Source-to-source branch coverage collector and LCOV exporter
├── runner/
│   ├── lit_runner.goose     # // RUN: directive parser, embedded shim resolution, substitutions
│   ├── check_cli.goose      # Parallel `goose check` CLI runner
│   └── verify_cli.goose     # Unified format, typecheck, G-CRAP gate, and LIT verifier
├── profile/
│   └── cli.goose            # Stage profiler & testing.B benchstat CLI runner
├── sloc/
│   ├── model.goose          # Cycles-vs-SLOC metrics, smells, baseline & gate structs
│   ├── scanner.goose        # Single-pass SLOC/stmt/comment/smell/dead_fn/BCE scanner
│   ├── correlate.goose      # .lit/sloc-map parser & RDTSC bench/stage correlator
│   ├── baseline.goose       # Baseline v1 persistence & Pareto/ratchet gate engine
│   ├── report.goose         # Table, Markdown, JSON & TSV formatters
│   └── cli.goose            # CLI argument parser & orchestrator for `goose-lit sloc`
├── fuzz/
│   └── cli.goose            # SanCov / libFuzzer build & campaign CLI runner
├── wire/
│   ├── edge.goose           # Page-edge layout, hex decoder, split stream verifier
│   ├── inspect.goose        # Hexdump and 128-bit SIMD lane formatter
│   └── mutate.goose         # xorshift64 payload mutator
├── crap/
│   ├── ast/                 # AST models and complexity visitors
│   ├── compiler/            # goose --bce-lines & --specs output parsers
│   ├── coverage/            # Branch instrumentation & profile loaders (.gcrap-cov, LCOV)
│   ├── lexer/               # Token scanner for Goose source files
│   ├── metrics/             # G-CRAP, CC, Cognitive Complexity metrics
│   ├── report/              # Formatters (table, md, json, gcc, sarif) & baseline ratchet
│   ├── cli.goose            # CLI argument parser for crap and gate modes
│   └── crap.goose           # Subsystem export facade
├── testkit/
│   ├── alloc.goose          # Runtime allocation counter & zero-alloc assertions
│   ├── assert.goose         # Unit assertions (assert_eq, assert_true, etc.)
│   ├── bench.goose          # Microbenchmark latency budget & parity checks
│   ├── context.goose        # Test context T and failure recording
│   ├── diff.goose           # Unified line-diff engine for failures
│   ├── mock.goose           # Deterministic clocks, call spies, and FuzzRng
│   ├── profile.goose        # Stage profiler spans & testing.B bench suite API
│   ├── runner.goose         # In-process test suite and case runners
│   └── testkit.goose        # thread_spawn_contained helpers
├── sys/
│   ├── bytes.goose          # Slice operations, glob matching, and byte utilities
│   ├── config.goose         # Configuration loading and baseline path resolution
│   ├── proc.goose           # Process execution, timeouts, cached temp output capture
│   └── time.goose           # Monotonic timers
├── shim/
│   ├── alloc_count.c        # Runtime pool allocation & stack watermark counter
│   ├── alloc_hook.h         # Compile-time interposition header (%alloc_hook)
│   ├── cov_rt.h             # Self-contained branch coverage counter runtime (%cov_rt)
│   ├── fuzz_driver.c        # SanCov 64 KB edge-bitmap & libFuzzer C driver
│   ├── proc.c               # C11 subprocess runner and atomic counters
│   ├── prof_hook.h          # Profiler & memory interposition header (%prof_hook)
│   └── profiler.c           # Cycle-accurate stage profiler & bench engine
├── tests/                   # End-to-end and unit regression suites
├── tools/
│   ├── test_runner.py       # Cross-platform 4-step test runner
│   └── licensing.py         # SPDX license header validator and applicator
└── scripts/
    ├── test_all.py          # Cross-platform test runner entry point
    └── test_all.sh          # POSIX shell wrapper for test runner
```

## Subsystems

### FileCheck engine (`check/filecheck.goose`)
Implements eight matching directives:
- `CHECK:`: matches a substring or pattern on or after the current line.
- `CHECK-NEXT:`: matches on the line immediately after the previous match.
- `CHECK-NOT:`: confirms a pattern does not appear before the next match.
- `CHECK-LABEL:`: divides input into scoped match regions.
- `CHECK-SAME:`: matches on the same line as the previous match.
- `CHECK-EMPTY:`: confirms the next line is empty.
- `CHECK-DAG:`: matches patterns in any order within the current block.
- `CHECK-COUNT-<N>:`: matches a pattern `<N>` times on consecutive lines.

### Wire testing (`wire/`)
- `verify_split_stream`: calls a decoder on each slice prefix from length 1 up to length $N - 1$. The test fails if a prefix causes an abort or returns an unexpected status code.
- `fuzz_payload_stream`: applies bit flips, extreme byte values (0x00, 0xFF, 0x7F, 0x80), 16-bit and 32-bit boundary integers, and byte swaps.

### G-CRAP risk radar (`crap/`)
Evaluates risk using cyclomatic complexity, real branch coverage (`.gcrap-cov` or LCOV), and compiler reports:
$$\text{CRAP}(m) = \text{CC}(m)^2 \cdot (1 - \text{Cov}(m))^3 + \text{CC}(m)$$
$$G\text{-CRAP}(m) = \text{CRAP}(m) + \alpha \cdot \text{UnprovenBCE}(m) + \beta \cdot \text{UncheckedArith}(m)$$

Functions containing unproven bounds checks (`bce:keep`) in uncovered code are classified as `PANIC_HAZARD` to catch boundary bugs during static analysis.
