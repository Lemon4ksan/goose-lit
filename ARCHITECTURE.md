# Architecture

goose-lit is a test runtime, FileCheck matcher, binary stream fuzzer, and G-CRAP risk analyzer for Goose. It acts as an external tool for Goose repositories (such as `goose-wing`, `goose-przm`, `dawn`, and third-party packages) without adding library dependencies to production targets.

The contract between a target codebase and goose-lit consists of command-line calls and borrowed byte slices (`const u8[:]`).

## Execution and isolation

goose-lit uses language features of Goose to verify targets:
- In-process test isolation: The runner executes tests using `thread_spawn_contained`. If a test worker aborts from an out-of-bounds access, an integer overflow, or an assertion failure, the runner catches the abort and reports the failure without terminating the runner process.
- Virtual page-boundary simulation: Binary stream tests place buffers at the end of a 64 KB memory page (`65536 - len`) and supply sliced prefixes to detect buffer overreads.

## Four-layer verification pipeline

Verification runs through four sequential stages:

```
+-----------------------------------------------------------------------------+
| Layer 1: Static risk gate & BCE radar (G-CRAP)                              |
|   • Lexical and AST analysis (CC, Cog)                                      |
|   • goose --bce-lines compiler output (elided vs unproven bounds checks)    |
|   • Branch coverage profiles (.gcrap-cov, LCOV) and regression checks       |
|   • Archetype flags: PANIC_HAZARD, FALSE_ALARM, COMPLEX_UNTESTED            |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 2: Virtual page edge & binary wire fuzzer (lit::wire)                 |
|   • verify_split_stream(buf, incomplete_code, ok_code, decoder)             |
|   • Prefixes 1..N-1 tested for incomplete status codes                      |
|   • Bit flips, boundary bytes, and byte swaps via xorshift64                |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 3: FileCheck & LIT test runner (lit::check & lit::runner)             |
|   • // RUN: directive parsing and substitutions (%s, %S, %t, %FileCheck)    |
|   • CHECK:, CHECK-NEXT:, CHECK-NOT:, CHECK-LABEL:, CHECK-SAME:, CHECK-EMPTY |
|   • Breadth-first test discovery across directories                         |
+-----------------------------------------------------------------------------+
                                      |
                                      v
+-----------------------------------------------------------------------------+
| Layer 4: Sandboxed assertions (lit::testkit)                                |
|   • thread_spawn_contained test workers                                     |
|   • expect_contained_abort verification of bounds traps and panics          |
|   • Ring buffer and memory balance assertions                               |
+-----------------------------------------------------------------------------+
```

## Module layout

```
goose-lit/
├── bin.goose                # CLI entry point (lit runner, filecheck, crap)
├── lit.goose                # Root library interface
├── lit.build                # Goose package sidecar build configuration
├── check/
│   └── filecheck.goose      # FileCheck directive parser and matcher
├── runner/
│   └── lit_runner.goose     # // RUN: directive parser and test discoverer
├── wire/
│   ├── edge.goose           # Page-edge layout, hex decoder, split stream verifier
│   └── mutate.goose         # xorshift64 payload mutator
├── crap/
│   ├── ast/                 # AST models and complexity visitors
│   ├── compiler/            # goose --bce-lines & --specs output parsers
│   ├── coverage/            # Branch coverage profiles (.gcrap-cov, LCOV)
│   ├── lexer/               # Token scanner for Goose source files
│   ├── metrics/             # G-CRAP, CC, Cognitive Complexity metrics
│   ├── report/              # Formatters for text, markdown, json, and sarif
│   ├── cli.goose            # CLI argument parser for crap mode
│   └── crap.goose           # Subsystem export facade
├── testkit/
│   ├── assert.goose         # Unit assertions (assert_eq, assert_true, etc.)
│   ├── diff.goose           # Unified line-diff engine for failures
│   ├── mock.goose           # Function call recorders and mocks
│   ├── runner.goose         # In-process test suite and case runners
│   └── testkit.goose        # thread_spawn_contained helpers
├── core/
│   ├── bytes.goose          # Slice operations and byte utilities
│   ├── config.goose         # Configuration loading and baseline path resolution
│   ├── proc.goose           # Process execution, cached temp output capture
│   └── time.goose           # Monotonic timers
├── shim/
│   └── proc.c               # C11 subprocess runner and atomic counters
├── tests/
│   ├── filecheck_test.goose # Unit tests for FileCheck directives
│   ├── wire_test.goose      # Split-stream and mutator tests
│   └── pipeline_test.goose  # Pipeline test with // RUN: goose %s | %FileCheck %s
├── tools/
│   ├── test_runner.py       # Cross-platform 4-step test runner
│   └── licensing.py         # SPDX license header validator and applicator
└── scripts/
    ├── test_all.py          # Cross-platform test runner entry point
    └── test_all.sh          # POSIX shell wrapper for test runner
```

## Subsystems

### FileCheck engine (`check/filecheck.goose`)
Implements six matching directives:
- `CHECK:`: matches a substring on or after the current line.
- `CHECK-NEXT:`: matches a substring on the next line.
- `CHECK-NOT:`: confirms a substring does not appear before the next match.
- `CHECK-LABEL:`: divides input into scoped match regions.
- `CHECK-SAME:`: matches a substring on the line of the previous match.
- `CHECK-EMPTY:`: confirms the next line is empty.

### Wire testing (`wire/`)
- `verify_split_stream`: calls a decoder on each slice prefix from length 1 up to length $N - 1$. The test fails if a prefix causes an abort or returns an unexpected status code.
- `fuzz_payload_stream`: applies bit flips, extreme byte values (0x00, 0xFF, 0x7F, 0x80), 16-bit and 32-bit boundary integers, and byte swaps.

### G-CRAP risk radar (`crap/`)
Evaluates risk using cyclomatic complexity, branch coverage, and compiler reports:
$$\text{CRAP}(m) = \text{CC}(m)^2 \cdot (1 - \text{Cov}(m))^3 + \text{CC}(m)$$
$$G\text{-CRAP}(m) = \text{CRAP}(m) + \alpha \cdot \text{UnprovenBCE}(m) + \beta \cdot \text{UncheckedArith}(m)$$

Functions containing unproven bounds checks (`bce:keep`) in uncovered code are classified as `PANIC_HAZARD` to catch boundary bugs during static analysis.
