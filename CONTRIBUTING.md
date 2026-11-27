# Contributing to goose-lit

This document covers engineering invariants, repository layout, and testing workflows for `goose-lit`.

## Engineering invariants

`goose-lit` is an external test harness, FileCheck matcher, coverage runner, profiler, fuzzer, and static complexity analyzer written in [Goose](https://github.com/aardappel/goose). Contributions must follow these rules:

1. Keep production targets decoupled: `goose-lit` is invoked as a CLI or imported only from test files, never linked into production libraries.
2. Keep the byte-slice ABI boundary (`const u8[:]`) between test harnesses and verified targets.
3. Avoid dynamic allocations (`[>..]`) on wire inspection, prefix slicing, mutation, and FileCheck matching hot paths; use stack-allocated bounded arrays (`u8[..N]`) and borrowed slices.
4. Keep C11 shims in `shim/` portable across Windows, Linux, and macOS, compiling cleanly under `-std=c11 -Wall -Wextra -Werror` on GCC and Clang.
5. Keep embedded runtime shims (`shim/alloc_hook.h`, `shim/prof_hook.h`, `shim/cov_rt.h`, `shim/fuzz_driver.c`) self-contained so standalone release binaries work without a source checkout.

## Prerequisites

- Goose compiler `v2026.4+` on `PATH`.
- GCC (MinGW-w64 on Windows, native GCC on Linux) or Clang.
- Python 3.11+ for `tools/test_runner.py` and `tools/licensing.py`.
- `just` (optional) for recipes in [`Justfile`](Justfile).

## Repository layout

```text
goose-lit/
├── bin.goose         # CLI entry point
├── cli.goose         # CLI subsystem facade (runner, check, cov, crap, profile, fuzz, sloc)
├── cli.build         # CLI sidecar C shim build configuration
├── lit.goose         # Lightweight library exports (testkit + wire only)
├── lit.build         # Library sidecar C shim build configuration
├── check/            # FileCheck directive parser and matcher
├── cov/              # Source-to-source branch coverage collector and LCOV exporter
├── crap/             # G-CRAP lexer, AST analyzer, compiler bridge, metrics, reports, ratchet
├── docs/             # Integration guide
├── examples/         # Minimal sample Goose project tested with LIT
├── fuzz/             # SanitizerCoverage and libFuzzer campaign runner
├── profile/          # Stage profiler and testing.B benchstat CLI
├── runner/           # LIT directive runner, parallel check CLI, verify CLI
├── scripts/          # Cross-platform test runner wrappers
├── shim/             # C11 runtime shims and compile-time interposition headers
├── sloc/             # Cycles-vs-SLOC scanner, correlator, baseline ratchet, reports
├── sys/              # Byte utilities, .litconfig parser, process runner, monotonic timers
├── testkit/          # In-process assertions, mocks, alloc counter, bench/profile APIs
├── tests/            # Unit and end-to-end LIT regression suites
├── tools/            # Python test runner and SPDX header checker
└── wire/             # Page-edge split-stream verifier, mutator, hex/SIMD inspector
```

## Development and testing workflow

### 1. Typechecking

Verify `lit.goose`, `bin.goose`, and all test suites without compiling binaries:

```bash
python tools/test_runner.py --check-only
```

Or using `just`:

```bash
just check
```

### 2. Building and running the full test suite

Build `bin/goose-lit` and run all LIT suites and the G-CRAP smoke check:

```bash
just build
python tools/test_runner.py
```

Run a subset of tests matching a pattern:

```bash
python tools/test_runner.py --pattern "*sloc*"
```

### 3. Formatting, linting, and license headers

Format all `.goose` files, lint Python tools, and check Apache-2.0 SPDX headers before committing:

```bash
goose format .
goose format --check .
ruff check tools/ scripts/
python tools/licensing.py --check
```

If new files are missing SPDX headers, run `python tools/licensing.py --fix`.

## Pull request checklist

- [ ] `python tools/test_runner.py` passes locally.
- [ ] `goose format --check .` reports zero unformatted files.
- [ ] `python tools/licensing.py --check` reports zero violations.
- [ ] `ruff check tools/ scripts/` passes cleanly.
- [ ] Modified C shims compile cleanly with `-std=c11 -Wall -Wextra -Werror`.
- [ ] Commit messages follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `perf:`, `style:`, `test:`, `chore:`).
